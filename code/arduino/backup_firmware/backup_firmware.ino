#include <WiFi.h>
#include "ftp32.h"
#include "Esp.h"
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ESPping.h>
#include <SPI.h>
#include <Update.h>
#include <SD.h>
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_image_format.h"
#include <MD5Builder.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <assert.h>

#define BUTTON_PIN 15

// WIFI BLOCK
#define WIFI_LOGIN_OPTION 0 // 1: Login captive portal, 0: Login wifi router
#define EXPERIMENT_SITE 0 // 1: Experiment site, 0: Home site

#define CHIP_ID "0x0000FAF4"
#define VERSION "0.0.0"
#define BUILD_DATE "250825"

typedef struct current_firmware_t {
  String partition;
  String version;
  String buildDate;
} current_firmware_t;

typedef struct target_firmware_t {
  String fileName;
  String version;
  String size;
} target_firmware_t;

typedef struct download_info_t {
  String path;
} download_info_t;

typedef struct payload {
  String deviceId;
  String chipId;
  String requestType;
  current_firmware_t firmware;
  target_firmware_t targetFirmware;
  download_info_t downloadInfo;
  

  String status;
  String message;
} payload_t;


String DEVICE_ID = "ESP32";
String REQUEST_TYPE = ""; 
String CUR_FIRM_PARTITION = "";

String UPDATE_STATUS = "";
String FILE_NAME = "";
String SIZE = "";
String DOWNLOAD_PATH = "";

String BAD_MESSAGE = "";

int lastState = HIGH;
int currentState;

#if EXPERIMENT_SITE == 1
  const char* ssid = "CEEC_Tenda";
  const char* password = "1denmuoi1";
  const char* mqtt_server = "192.168.0.163";
  FTP32 ftp("192.168.0.163", 21);
  IPAddress ip (192, 168, 0, 163);
#else
  const char* ssid = "SRedmi Note 11";
  const char* password = "23521341";
  const char* mqtt_server = "192.168.73.10";
  FTP32 ftp32_format_ftp_server_ip("192.168.73.10", 21);
  IPAddress ftp_server_ip (192, 168, 73, 10);
  IPAddress esp32_ip(192, 168, 73, 8);
  IPAddress esp32_gateway_ip(192, 168, 73, 39);
  IPAddress esp32_subnet_mask(255, 255, 73, 8);

#endif

WiFiClient espClient;
PubSubClient client(espClient);

int mqtt_port = 1883;

volatile bool stopMqttLoop = false;

String response_message = "";
String target_firmware = "";

const int chipSelect = SS;
const size_t buffer_size = 2048;

unsigned long program_start_time = 0;

void print_running_partition_info() {
  Serial.println("Determining running partition...");

  // Get the currently running partition
  const esp_partition_t *running_partition = esp_ota_get_running_partition();

  if (running_partition == NULL) {
    Serial.println("Could not determine running partition. This might be a non-OTA build.");
    // Attempt to find the first app partition as a fallback
    const esp_partition_t *app_partition = esp_partition_find_first(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_ANY, NULL);
    if (app_partition != NULL) {
      Serial.printf("However, the first app partition found is '%s'.\n", app_partition->label);
    }
    return;
  }

  Serial.printf("Running firmware is in partition: '%s'\n", running_partition->label);
  CUR_FIRM_PARTITION = (String)(running_partition->label);

  Serial.printf("Type: %s\n", (running_partition->type == ESP_PARTITION_TYPE_APP) ? "APP" : "DATA");
  Serial.printf("SubType: %d\n", running_partition->subtype);
  Serial.printf("Offset: 0x%x\n", running_partition->address);
  Serial.printf("Size: %d bytes (%.2f MB)\n", running_partition->size, (float)running_partition->size / 1024 / 1024);
}

void login_wifi_router() {
  WiFi.eraseAP();
  WiFi.mode(WIFI_STA);

  Serial.println("Static configuration info");
  Serial.print("ESP32 IP Address: ");
  Serial.println(esp32_ip);

  Serial.print("Default gateway address: ");
  Serial.println(esp32_gateway_ip);

  Serial.print("Subnet mask: ");
  Serial.println(esp32_subnet_mask);

  if (!WiFi.config(
    esp32_ip, 
    esp32_gateway_ip, 
    esp32_subnet_mask
  )) {
    Serial.println("Fail to setup static configuration");
    return;
  }

  Serial.println("Connecting to WiFi...");
  Serial.print("SSID: ");
  Serial.println(ssid);
  Serial.print("Password: ");
  Serial.println(password);

  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }

  Serial.println("WiFi connected");

  Serial.print("ESP32 IP Address: ");
  Serial.println(WiFi.localIP());

  Serial.print("Default gateway address: ");
  Serial.println(WiFi.gatewayIP());

  Serial.print("Subnet mask: ");
  Serial.println(WiFi.subnetMask());

  Serial.print("MAC: ");
  Serial.println(WiFi.macAddress());

  DEVICE_ID = WiFi.macAddress();
}

void login_mqtt_server() {
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(mqtt_callback);
  if (!client.connect("ESP32_CLIENT", NULL, NULL)) {
    Serial.println("MQTT connection failed");
  } else {
    Serial.println("MQTT connected");
  }
}

void mqtt_callback(char* topic, byte* payload, unsigned int length) {
  Serial.print("Message arrived [");
  response_message = "";
  Serial.print(topic);

  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, payload, length);

  if (error) {
    Serial.print("deserializeJson() failed: ");
    Serial.println(error.c_str());
    return;
  }

  const char* status = doc["status"];
  Serial.printf("Response status: %s\n", status);

  if (strcmp(status, "UPDATE_AVAILABLE") == 0) {
    // Trích xuất thông tin firmware mới
    const char* fileName = doc["targetFirmware"]["fileName"];
    long fileSize = doc["targetFirmware"]["size"];
    const char* md5 = doc["targetFirmware"]["md5"];
    const char* server = doc["downloadInfo"]["server"];

    Serial.printf("Update available: %s\n", fileName);
    Serial.printf("Size: %ld, MD5: %s\n", fileSize, md5);
    Serial.printf("Download from: %s\n", server);

    // Gán vào biến toàn cục để xử lý tiếp
    target_firmware = String(fileName);
    // ...
    // Bắt đầu quá trình tải về và cập nhật
    stopMqttLoop = true;

  } else if (strcmp(status, "NO_UPDATE") == 0) {
    const char* message = doc["message"];
    Serial.println(message);
    stopMqttLoop = true;
  } else {
    Serial.println("Unknown or error status received.");
    stopMqttLoop = true;
  }
}

void sendUpdateRequest(PubSubClient& client) {
  JsonDocument doc; // Sử dụng JsonDocument thay vì StaticJsonDocument để tự động cấp phát

  // Lấy địa chỉ MAC làm deviceId
  String deviceId = WiFi.macAddress();
  deviceId.replace(":", ""); // Xóa dấu hai chấm

  doc["deviceId"] = deviceId;
  doc["chipId"] = "0x0000FAF4";
  doc["requestType"] = "UPDATE_REQUEST";

  JsonObject firmwareInfo = doc["currentFirmware"].to<JsonObject>();
  firmwareInfo["partition"] = "factory"; // Hoặc lấy từ esp_ota_get_running_partition()
  firmwareInfo["version"] = "1.0.0";     // Định nghĩa phiên bản
  firmwareInfo["buildDate"] = "250825"; // Định nghĩa ngày build

  String output;
  serializeJson(doc, output);

  String requestTopic = "nckhsv/" + deviceId + "/request";

  Serial.println("Publishing request to: " + requestTopic);
  Serial.println(output);

  if (client.publish(requestTopic.c_str(), output.c_str())) {
    Serial.println("Request published successfully.");
  } else {
    Serial.println("Failed to publish request.");
  }
}

void ping_ftp_server() {
  while (!Ping.ping(ftp_server_ip)) {
    Serial.println("Ping failed");
    delay(1000);
  }
  
  Serial.println("Ping successully");
}

void login_ftp_server(FTP32& ftp, uint16_t& ftp_connect_flag) {
  ftp_connect_flag = ftp.connectWithPassword("shanghuang-jetsonnano", "181105");

  if(ftp_connect_flag != 0) {
    Serial.println("Login unsuccessful");
    Serial.printf("Exited with code: %d %s\n", ftp.getLastCode(), ftp.getLastMsg());
    while(true) {}
  } else {
    Serial.println("Login FTP server successfully");
  }
}

void collect_info_ftp_server(FTP32 ftp) {
  String dest;
  String content;
  String sysinfo;
  uint16_t check = 0;

  Serial.println("System info: ");
  check = ftp.getSystemInfo(sysinfo);
  Serial.print("[Return code]: ");
  Serial.println(check);
  if (check == 0) {
    Serial.println(sysinfo);
  }
  Serial.println("");

  Serial.println("Current directory: ");
  check = ftp.pwd(dest);
  Serial.print("[Return code]: ");
  Serial.println(check);
  if (check == 0) {
    Serial.println(dest);
  }
  Serial.println("");

  Serial.println("List content: ");
  check = ftp.listContent("", FTP32::ListType::SIMPLE, content);
  Serial.print("[Return code]: ");
  Serial.println(check);
  if (check == 0) {
    Serial.println(content);
  }
  Serial.println("");
}

void init_sdcard(bool& sdcard_init_flag) {
  Serial.println("Initializing SD card...");

  if (!SD.begin(SS)) {
    Serial.println("initialization failed. Things to check:");
    Serial.println("\t * is a card inserted?");
    Serial.println("\t * is your wiring correct?");
    Serial.println("\t * did you change the chipSelect pin to match your shield or module?");
    while (1);
  } else {
    Serial.println("Wiring is correct and a card is present.");
    sdcard_init_flag = true;
  }
}

void collect_info_sdcard() {
  Serial.print("Card size:  ");
  Serial.println(SD.cardSize());
 
  Serial.print("Total bytes: ");
  Serial.println(SD.totalBytes());
 
  Serial.print("Used bytes: ");
  Serial.println(SD.usedBytes());
}

void download_file_ftp_server(FTP32& ftp, String remoteFileName, String localFileName) {
  String local_dir = "/" + localFileName;
  String remote_dir = "/" + remoteFileName;
  Serial.println("Preparing directory");
  Serial.println(local_dir);
  Serial.println(remote_dir);  

  Serial.println("Redirect to FTP_Site directory for firmware searching");
  uint16_t redirec_check = 0;
  redirec_check = ftp.changeDir("FTP_Site");
  Serial.print("[Return code]: ");
  Serial.println(redirec_check);
  if (redirec_check == 0) {
    Serial.println("Change succeed");
  }
  Serial.println("");

  Serial.printf("Downloading %s to SD card as %s...\n", remoteFileName.c_str(), localFileName.c_str());
  
  uint16_t check = 0;
  size_t file_size = 0;
  char buffer[buffer_size];
  size_t total_downloaded = 0;
  size_t bytes_read = 0;

  Serial.println("Set binary transfer mode: ");
  check = ftp.setTransferType(FTP32::TransferType::BINARY);
  Serial.print("[Return code]: ");
  Serial.println(check);
  if (check != 0) {
    Serial.println("Fail to set binary transfer mode.");
  }

  Serial.println("Get file size: ");
  check = ftp.fileSize(remoteFileName.c_str(), file_size);
  Serial.print("[Return code]: ");
  Serial.println(check);
  if (check != 0) {
    Serial.println("Fail to get file size.");
  }
  Serial.printf("File size: %d bytes\n", file_size);

  if (SD.totalBytes() - SD.usedBytes() < file_size) {
    Serial.println("Not enough space on SD card!");
    while (1) {}
  }
  
  File localFile = SD.open(local_dir, FILE_WRITE, true);
  if (!localFile) {
    Serial.println("Failed to open local file for writing!");
    SD.end();
    return;
  }
  localFile.setBufferSize(buffer_size);

  Serial.println("Init download: ");
  check = ftp.initDownload(remoteFileName.c_str());
  Serial.print("[Return code]: ");
  Serial.println(check);
  if (check != 0) {
    Serial.println("Fail to init download.");
    localFile.close();
    SD.remove(local_dir);
    SD.end();
    while (1) {}
  }

  Serial.println("Start download: ");
  do {
    // Download chunk from FTP
    bytes_read = ftp.downloadData(buffer, buffer_size);
    Serial.println(bytes_read);
    
    if (bytes_read > 0) {
      // Write chunk to SD card
      if (!localFile) {
        Serial.println("Error raise");
        SD.end();
        break;
      }

      size_t bytes_written = localFile.write((uint8_t*)buffer, bytes_read);
      Serial.println(bytes_written);
      
      if (bytes_written != bytes_read) {
        Serial.println("Error writing to SD card!");
        localFile.close();
        SD.remove(local_dir);
        SD.end();
        while (1) {}
      }
      
      total_downloaded += bytes_read;
      
      // Show progress
      if (file_size > 0) {
        int progress = (total_downloaded * 100) / file_size;
        Serial.printf("Progress: %d%% (%d/%d bytes)\n", progress, total_downloaded, file_size);
      }
    }
    
    delay(100); // Small delay to prevent watchdog reset
    
  } while (bytes_read > 0);

  localFile.close();

  if (total_downloaded == file_size) {
    Serial.printf("Successfully downloaded %s (%d bytes) to SD card\n", remoteFileName.c_str(), total_downloaded);
  } else {
    Serial.printf("Download incomplete! Downloaded: %d, Expected: %d\n", total_downloaded, file_size);
    SD.remove(localFileName); // Remove incomplete file
    SD.end();
    while (1) {}
  }
}

void progress_callback(size_t current_size, size_t total_size) {
  Serial.printf("Firmware update process at %d of %d bytes...\n", current_size, total_size);
}

void list_and_find_partitions(const esp_partition_t* &update_partition) {
  Serial.println("Listing all partitions found:");
  Serial.println("-------------------------------------------------------------------------------------");
  Serial.printf("| %-16s | %-4s | %-7s | %-10s | %-10s | %-8s |\n", "Label", "Type", "SubType", "Offset", "Size", "Encrypted");
  Serial.println("-------------------------------------------------------------------------------------");

  // Bắt đầu tìm kiếm với các tham số wildcard để lấy tất cả các phân vùng
  esp_partition_iterator_t it = esp_partition_find(ESP_PARTITION_TYPE_ANY, ESP_PARTITION_SUBTYPE_ANY, NULL);

  // Lặp qua tất cả các phân vùng tìm được
  while (it != NULL) {
    const esp_partition_t *part = esp_partition_get(it);
    
    // In thông tin của phân vùng hiện tại
    Serial.printf("| %-16s | %-4d | %-7d | 0x%-8x | 0x%-8x | %-8s |\n",
                  part->label,      // Tên (nhãn) của phân vùng
                  part->type,       // Loại (0=app, 1=data)
                  part->subtype,    // Loại phụ
                  part->address,    // Địa chỉ bắt đầu (offset)
                  part->size,       // Kích thước
                  part->encrypted ? "true" : "false"); // Có được mã hóa không

    // Kiểm tra nếu phân vùng là phân vùng OTA_0 cần cập nhật
    if (
      part->type == ESP_PARTITION_TYPE_APP &&
      part->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_0 &&
      strcmp(part->label, "ota_0") == 0
    ) {
      update_partition = part; // Lưu phân vùng OTA_0 để sử dụng sau
    }

    // Di chuyển đến phân vùng tiếp theo
    it = esp_partition_next(it);
  }

  Serial.println("Find partition ota_0: ");
  if (update_partition != NULL) {
    // In thông tin của phân vùng OTA_0
    Serial.printf("| %-16s | %-4d | %-7d | 0x%-8x | 0x%-8x | %-8s |\n",
                  update_partition->label,
                  update_partition->type,
                  update_partition->subtype,
                  update_partition->address,
                  update_partition->size,
                  update_partition->encrypted ? "true" : "false");
  } else {
    Serial.println("Partition ota_0 not found!");
  }

  // Giải phóng bộ nhớ của iterator sau khi hoàn tất
  // Lưu ý: esp_partition_next sẽ tự động giải phóng iterator cũ,
  // nhưng chúng ta cần giải phóng cái cuối cùng khi vòng lặp kết thúc.
  // Tuy nhiên, trong thực tế, khi `it` trở thành NULL, bộ nhớ đã được giải phóng.
  // Gọi lại esp_partition_iterator_release(it) khi it là NULL vẫn an toàn.
  esp_partition_iterator_release(it);
  
  Serial.println("-------------------------------------------------------------------------------------");
}

void update_firmware() {
  String updated_firmware = "/updated_" + target_firmware;
  String original_firmware = "/" + target_firmware;

  Serial.println("Search for firmware..");
  File firmware =  SD.open("/" + target_firmware);
  if (firmware) {
    Serial.println(F("found!"));

    Serial.println("Firmware size: ");
    Serial.print(firmware.size());

    Serial.println(F("Check partition table..."));
    const esp_partition_t* update_partition = NULL;
    list_and_find_partitions(update_partition);

    if (firmware.size() > update_partition->size) {
      Serial.println("Firmware binary is too large for the ota_0 partition!");
      firmware.close();
      while (1) {}
    }

    Update.onProgress(progress_callback);

    Update.setCryptMode(U_AES_DECRYPT_NONE);

    if (!Update.begin(firmware.size(), U_FLASH, -1, -1, update_partition->label)) {
      Serial.println("Failed to start update process!");
      Update.printError(Serial);
      firmware.close();
      return;
    }

    size_t written = Update.writeStream(firmware);

    if (written == firmware.size()) {
      Serial.println("Written : " + String(written) + " successfully");
    } else {
      Serial.println("Written only : " + String(written) + "/" + String(firmware.size()) + ". Retry?");
    }

    if (Update.end()){
      Serial.println(F("Update finished!"));
        if (Update.isFinished()) {
        Serial.println("Update successfully completed. Rebooting.");
      } else {
        Serial.println("Update not finished? Something went wrong!");
      }
    }else{
        Serial.println(F("Update error!"));
        Serial.println(Update.getError());
    }

    firmware.close();

    

    if (SD.rename("/" + target_firmware, "/updated_" + target_firmware)){
      Serial.println(F("Firmware rename succesfully!"));
    }else{
      Serial.println(F("Firmware rename error!"));
    }

    Serial.println(F("Disconnect SD card"));
    SD.end();
    
    delay(2000);

    unsigned long program_end_time = millis();
    unsigned long elapsed_time = program_end_time - program_start_time;
    Serial.print("Total program uptime before restart: ");
    Serial.print(elapsed_time / 1000);
    Serial.println(" seconds (");
    Serial.print(elapsed_time);
    Serial.println(" ms)");

    Serial.println(F("Rebooting..."));
    esp_err_t err = esp_ota_set_boot_partition(update_partition);
    if (err != ESP_OK) {
      Serial.printf("Failed to set boot partition to ota_0! Error: %s\n", esp_err_to_name(err));
    } else {
      Serial.println("Boot partition set to 'ota_0'. Restarting now to launch application...");
      delay(1000);
      ESP.restart();
    }
  }else{
    Serial.println(F("not found!"));
  }
}

void setup() {
  Serial.begin(115200);

  delay(2000); //

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  delay(2000); //

  // Verify the partition table
  Serial.println("---------------------------------------------");
  print_running_partition_info();
  Serial.println("---------------------------------------------");

  delay(2000); //

  Serial.println("---------------------------------------------");
  Serial.println("Login wifi router...");
  login_wifi_router();
  Serial.println("---------------------------------------------");

  delay(2000); //



  delay(2000); //

  Serial.println("---------------------------------------------");
  Serial.println("Connect mqtt broker...");
  login_mqtt_server();
  Serial.println("---------------------------------------------");

  Serial.println("---------------------------------------------");
  bool sdcard_init_flag = false;
  init_sdcard(sdcard_init_flag);
  Serial.println("---------------------------------------------");

  delay(2000); //

  Serial.println("---------------------------------------------");
  if (sdcard_init_flag == true) {
    collect_info_sdcard();
  }
  Serial.println("---------------------------------------------");
}

void loop() {
  program_start_time = millis();

  // read the state of the switch/button:
  currentState = digitalRead(BUTTON_PIN);

  boolean publish_flag = false;

  if(lastState == LOW && currentState == HIGH) {
    Serial.println("The state changed from LOW to HIGH");
    delay(100); //
    Serial.println("Publish message: ");
    delay(100); //

    sendUpdateRequest(client);

    // String message = "{}";
    // publish_flag = client.publish("request", "update request message from esp32");

    // if (publish_flag == false) {
    //   Serial.println("Fail to publish topic due to exceed TTL");
    //   delay(100); //
    //   login_mqtt_server();
    // } else {
    //   Serial.println("Success to publish message");
    // }

    delay(100); //

    client.subscribe("response");
  }

  // if (!stopMqttLoop) {
  //   delay(100); //
    
  //   client.loop();

  //   if (stopMqttLoop) {
  //     delay(100); //

  //     Serial.println("MQTT loop stopped by message receive!");

  //     delay(100); //

  //     if (
  //       response_message == "Error: No new file update found"
  //     ) {
  //       Serial.println("No new file update found, do nothing");
  //     } else if (
  //       response_message == "Return: Allow to connect and download firmware"
  //     ) {
  //       Serial.println("Found new update, ready to update");

  //       delay(100); //

  //       Serial.println("Ping gateway");

  //       ping_ftp_server();

  //       delay(100); //

  //       uint16_t ftp_connect_flag = -1;
  //       login_ftp_server(ftp, ftp_connect_flag);

  //       delay(100); //

  //       if (ftp_connect_flag == 0) {
  //         collect_info_ftp_server(ftp);
  //       }

  //       delay(100); //

  //       String remoteFileName = target_firmware;
  //       String localFileName = target_firmware;
  //       download_file_ftp_server(ftp, remoteFileName, localFileName);

  //       delay(100); //

  //       update_firmware();
  //     }
  //   }
  // }

  lastState = currentState;
}
