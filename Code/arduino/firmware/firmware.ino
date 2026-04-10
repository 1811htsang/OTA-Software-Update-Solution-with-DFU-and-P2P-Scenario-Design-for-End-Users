// Khai báo các thư viện sử dụng
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

// Khai báo hằng số cho chân nút bấm
#define req_btn_pin_def 15
#define sel_btn_pin_def 22

// Khai báo hằng số thiết bị
#define chip_id_def "0x0000FAF4"

// Khai báo biến toàn cục để lưu trạng thái nút bấm
int req_pin_laststate_glb = HIGH;
int sel_pin_laststate_glb = HIGH;
int req_pin_currentstate_glb;
int sel_pin_currentstate_glb;

// Khai báo biến toàn cục cho cấu hình Wifi
WiFiClient esp_client_glb;
const char* wifi_ssid_glb = "TM420IA";
const char* wifi_pass_glb = "23521341";

// Khai báo biến toàn cục cho cấu hình MQTT
const char* mqtt_brokerip_glb = "192.168.0.51";
int mqtt_port_glb = 1883;
PubSubClient mqtt_client_glb(esp_client_glb);
volatile bool mqtt_loopstop_flg_glb = false;

// Khai báo biến toàn cục cho trạng thái phản hồi và lựa chọn firmware
String mqtt_topicresponse_glb = "";
bool mqtt_awaitresponse_flg_glb = false;
unsigned long mqtt_responsetickcount_glb = 0;
const unsigned long mqtt_responsetimeout_glb = 15000; // 15 seconds timeout
String mqtt_responsestatus_glb = "";
bool mqtt_selectionwaiting_flg_glb = false;
int mqtt_selectedindex_glb = 0;
int mqtt_firmwarecount_glb = 0;

// Khai báo biến toàn cục cho cấu hình FTP
FTP32 ftp_serverip_fmt32_glb("192.168.0.51", 21);
IPAddress ftp_serverip_fmtip_glb(192, 168, 0, 51);

// Khai báo biến toàn cục cho thông điệp giao tiếp thiết bị và firmware
String mqtt_msg_devid_glb = "ESP32";
String mqtt_msg_res_glb = ""; // Variable to store response message
String mqtt_msg_tgfw_glb = ""; // Variable to store target firmware file name
bool fw_is_validated_glb = false;
String mqtt_fw_list_glb[100];
String fw_cur_partition_glb = "";

// Khai báo hằng số cho kích thước buffer khi tải firmware
const size_t buffer_size = 2048;

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

void print_running_partition_info() {
  Serial.println("Determining running partition...");
  const esp_partition_t *running_partition = esp_ota_get_running_partition();

  if (running_partition == NULL) {
    Serial.println("Could not determine running partition. This might be a non-OTA build.");
    const esp_partition_t *app_partition = esp_partition_find_first(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_ANY, NULL);
    if (app_partition != NULL) {
      Serial.printf("However, the first app partition found is '%s'.\n", app_partition->label);
    }
    return;
  }

  Serial.printf("Running firmware is in partition: '%s'\n", running_partition->label);
  fw_cur_partition_glb = (String)(running_partition->label);
  Serial.printf("Type: %s, SubType: %d, Offset: 0x%x, Size: %d bytes (%.2f MB)\n", 
                (running_partition->type == ESP_PARTITION_TYPE_APP) ? "APP" : "DATA",
                running_partition->subtype, running_partition->address, 
                running_partition->size, (float)running_partition->size / 1024 / 1024);
}

void login_wifi_router() {
  Serial.println("Connecting to WiFi...");
  WiFi.begin(wifi_ssid_glb, wifi_pass_glb);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected. IP: " + WiFi.localIP().toString());
  mqtt_msg_devid_glb = WiFi.macAddress();
}

void login_mqtt_brokerip_glb() {
  mqtt_client_glb.setServer(mqtt_brokerip_glb, mqtt_port_glb);
  mqtt_client_glb.setCallback(mqtt_callback);
  mqtt_client_glb.setKeepAlive(360);
  mqtt_client_glb.setSocketTimeout(360);
  if (!mqtt_client_glb.connect("ESP32_CLIENT", "esp32", "051118", "nckhsv", 1, true, "")) {
    Serial.print("MQTT connection failed, error code = ");
    Serial.println(mqtt_client_glb.state());
  } else {
    Serial.println("MQTT connected");
  }
}

void mqtt_callback(char* topic, byte* payload, unsigned int length) {
  Serial.print("Message arrived [");
  mqtt_msg_res_glb = "";
  Serial.print(topic);
  DynamicJsonDocument doc(1024);
  DeserializationError error = deserializeJson(doc, payload, length);
  if (error) {
    Serial.print("deserializeJson() failed: ");
    Serial.println(error.c_str());
    return;
  }
  const char* status = doc["status"];
  Serial.printf("\nResponse status: %s\n", status ? status : "(null)");
  const char* message = doc["message"];
  if (status == nullptr) return;
  mqtt_responsestatus_glb = String(status);

  if (strcmp(status, "BAD_REQUEST") == 0 || strcmp(status, "SERVER_UNEXPECTED_ERROR") == 0 || strcmp(status, "DEV_VAL_FAILED") == 0) {
    Serial.printf("Error received: %s\n", message);
    mqtt_msg_res_glb = String(message ? message : "");
    mqtt_loopstop_flg_glb = true;
  } else if (strcmp(status, "DEV_VAL_SUCCESS") == 0) {
    Serial.printf("Validation success: %s\n", message);
    fw_is_validated_glb = true;
    mqtt_msg_res_glb = String(message ? message : "");
  } else if (strcmp(status, "FW_LIST_RETR") == 0) {
    JsonArray array = doc["mqtt_fw_list_glb"].as<JsonArray>();
    Serial.println("Available firmware list:");
    mqtt_firmwarecount_glb = 0;
    for (JsonVariant v : array) {
      const char* fname = v["name"]; // Trích xuất trường "name" từ object
      if (fname != nullptr) {
        Serial.printf("  %d: %s\n", mqtt_firmwarecount_glb, fname);
        if (mqtt_firmwarecount_glb < 100) mqtt_fw_list_glb[mqtt_firmwarecount_glb++] = String(fname);
      }
    }
    
    if (mqtt_firmwarecount_glb > 0) {
      // Chọn ngẫu nhiên một index trong danh sách firmware nhận được
      randomSeed(millis()); // Khởi tạo hạt giống ngẫu nhiên
      mqtt_selectedindex_glb = random(0, mqtt_firmwarecount_glb);
      Serial.printf("Randomly selected firmware: %s (Index: %d)\n", mqtt_fw_list_glb[mqtt_selectedindex_glb].c_str(), mqtt_selectedindex_glb);
    }

    mqtt_msg_res_glb = "FW_LIST_RETR";
    mqtt_loopstop_flg_glb = true; 
  } else if (strcmp(status, "GW_WAIT") == 0 || strcmp(status, "FW_FOUND") == 0 || strcmp(status, "FW_NOT_FOUND") == 0) {
    mqtt_msg_res_glb = String(message ? message : "");
    mqtt_loopstop_flg_glb = true;
  } else if (strcmp(status, "UPDATE_AVAILABLE") == 0) {
    const char* targetFirmware = doc["targetFirmware"];
    mqtt_msg_tgfw_glb = String(targetFirmware ? targetFirmware : "");
    mqtt_msg_res_glb = "Return: Allow to connect and download firmware";
    mqtt_loopstop_flg_glb = true;
  } else if (strcmp(status, "UPDATE_UNAVAILABLE") == 0) {
    mqtt_msg_res_glb = "Error: No new file update found";
    mqtt_loopstop_flg_glb = true;
  }
}

void sendUpdateRequest(PubSubClient& mqtt_client_glb) {
  JsonDocument doc;
  String deviceId = WiFi.macAddress();
  deviceId.replace(":", "");
  doc["deviceId"] = deviceId;
  doc["chipId"] = chip_id_def;
  doc["requestType"] = "UPDATE_REQUEST";
  String output;
  serializeJson(doc, output);
  String requestTopic = "nckhsv/" + deviceId + "/request";
  mqtt_client_glb.publish(requestTopic.c_str(), output.c_str(), true);
}

void sendSelectionRequest(PubSubClient& mqtt_client_glb, String mqtt_fw_list_glb[]) {
  JsonDocument doc;
  String deviceId = WiFi.macAddress();
  deviceId.replace(":", "");
  doc["deviceId"] = deviceId;
  doc["chipId"] = chip_id_def;
  doc["isValidate"] = fw_is_validated_glb;
  doc["requestType"] = "SELECTION_REQUEST";
  doc["requestFile"] = mqtt_fw_list_glb[mqtt_selectedindex_glb];
  String output;
  serializeJson(doc, output);
  String requestTopic = "nckhsv/" + deviceId + "/select";
  mqtt_client_glb.publish(requestTopic.c_str(), output.c_str(), true);
}

void ping_ftp_server() {
  while (!Ping.ping(ftp_serverip_fmtip_glb)) {
    Serial.println("Ping failed");
    delay(1000);
  }
  Serial.println("Ping successfully");
}

void login_ftp_server(FTP32& ftp, uint16_t& ftp_connect_flag) {
  ftp_connect_flag = ftp.connectWithwifi_pass_glb("shanghuang-jetsonnano", "181105");
  if (ftp_connect_flag != 0) {
    Serial.printf("Login unsuccessful: %d %s\n", ftp.getLastCode(), ftp.getLastMsg());
  } else {
    Serial.println("Login FTP server successfully");
  }
}

void collect_info_ftp_server(FTP32 ftp) {
  String dest, content, sysinfo;
  if (ftp.getSystemInfo(sysinfo) == 0) Serial.println("System info: " + sysinfo);
  if (ftp.pwd(dest) == 0) Serial.println("Current directory: " + dest);
  if (ftp.listContent("", FTP32::ListType::SIMPLE, content) == 0) Serial.println("List content: \n" + content);
}

void init_sdcard(bool& sdcard_init_flag) {
  Serial.println("Initializing SD card...");
  if (!SD.begin(SS)) {
    Serial.println("SD initialization failed.");
  } else {
    Serial.println("SD card present.");
    sdcard_init_flag = true;
  }
}

void collect_info_sdcard() {
  Serial.printf("Card size: %llu, Used: %llu\n", SD.cardSize(), SD.usedBytes());
}

void progress_callback(size_t current_size, size_t total_size) {
  Serial.printf("Firmware update process at %d of %d bytes...\n", current_size, total_size);
}

void download_file_ftp_server(FTP32& ftp, String remoteFileName, String localFileName) {
  String local_dir = "/" + localFileName;
  
  String deviceId = WiFi.macAddress();
  deviceId.replace(":", "");
  String ftp_dir = deviceId + "_firmware";

  Serial.println("Changing FTP directory to: " + ftp_dir);

  if (ftp.changeDir(ftp_dir.c_str()) != 0) {
    Serial.printf("Failed to change directory to: %s\n", ftp_dir.c_str());
    return;
  }
  
  uint16_t check = 0;
  size_t file_size = 0;
  char buffer[buffer_size];
  size_t total_downloaded = 0, bytes_read = 0;

  ftp.setTransferType(FTP32::TransferType::BINARY);
  if (ftp.fileSize(remoteFileName.c_str(), file_size) != 0) return;
  if (SD.totalBytes() - SD.usedBytes() < file_size) return;

  File localFile = SD.open(local_dir, FILE_WRITE, true);
  if (!localFile) return;
  localFile.setBufferSize(buffer_size);

  if (ftp.initDownload(remoteFileName.c_str()) != 0) { localFile.close(); return; }

  do {
    bytes_read = ftp.downloadData(buffer, buffer_size);
    if (bytes_read > 0) {
      localFile.write((uint8_t*)buffer, bytes_read);
      total_downloaded += bytes_read;
    }
    delay(10);
  } while (bytes_read > 0);
  localFile.close();
  Serial.printf("Downloaded %d bytes\n", total_downloaded);
}

void update_firmware() {
  File firmware = SD.open("/" + mqtt_msg_tgfw_glb);
  if (!firmware) return;
  const esp_partition_t* update_partition = NULL;
  list_and_find_partitions(update_partition);
  if (!update_partition || firmware.size() > update_partition->size) { firmware.close(); return; }

  Update.onProgress(progress_callback);
  if (!Update.begin(firmware.size(), U_FLASH, -1, -1, update_partition->label)) { firmware.close(); return; }

  Update.writeStream(firmware);
  if (Update.end() && Update.isFinished()) {
    Serial.println("Update success. Rebooting...");
    esp_ota_set_boot_partition(update_partition);
    delay(1000);
    ESP.restart();
  }
  firmware.close();
}

void setup() {
  Serial.begin(115200);
  delay(2000);
  // pinMode(req_btn_pin_def, INPUT_PULLUP);
  // pinMode(sel_btn_pin_def, INPUT_PULLUP);

  // const esp_partition_t* update_partition = NULL;
  // list_and_find_partitions(update_partition);
  print_running_partition_info();
  delay(3000); 

  login_wifi_router();
  delay(3000);

  login_mqtt_brokerip_glb();
  delay(3000);

  bool sd_ok = false;
  init_sdcard(sd_ok);
  if (sd_ok) collect_info_sdcard();
  delay(3000);
}

void loop() {
  req_pin_currentstate_glb = digitalRead(req_btn_pin_def);
  if (req_pin_laststate_glb == LOW && req_pin_currentstate_glb == HIGH) {
    login_mqtt_brokerip_glb();
    sendUpdateRequest(mqtt_client_glb);
    delay(3000);

    String subId = WiFi.macAddress();
    subId.replace(":", "");
    String responseTopic = "nckhsv/" + subId + "/response";
    mqtt_client_glb.subscribe(responseTopic.c_str());
    mqtt_topicresponse_glb = responseTopic;
    mqtt_awaitresponse_flg_glb = true;
    mqtt_responsetickcount_glb = millis();
  }

  mqtt_client_glb.loop();

  if (mqtt_awaitresponse_flg_glb) {
    if (mqtt_loopstop_flg_glb) {
      Serial.println("DEBUG: Response received, waiting 3s before processing...");
      delay(3000);

      if (mqtt_responsestatus_glb == "UPDATE_AVAILABLE") {
        ping_ftp_server();
        delay(3000);

        uint16_t ftp_ok = -1;
        login_ftp_server(ftp_serverip_fmt32_glb, ftp_ok);
        delay(3000);

        bool sd_ok = false;
        init_sdcard(sd_ok);
        if (sd_ok) collect_info_sdcard();


        if (ftp_ok == 0) {
          Serial.println("Target firmware is " + mqtt_msg_tgfw_glb);
          download_file_ftp_server(ftp_serverip_fmt32_glb, mqtt_msg_tgfw_glb, mqtt_msg_tgfw_glb);
          delay(3000);

          update_firmware();
        }
        mqtt_awaitresponse_flg_glb = false;
      } else if (mqtt_responsestatus_glb == "FW_LIST_RETR") {
        // Just received list, wait for button
        mqtt_loopstop_flg_glb = false;
      } else if (mqtt_responsestatus_glb == "GW_WAIT") {
        mqtt_selectionwaiting_flg_glb = true;
        mqtt_loopstop_flg_glb = false;
      } else if (mqtt_responsestatus_glb.indexOf("ERROR") != -1 || mqtt_responsestatus_glb == "UPDATE_UNAVAILABLE") {
        mqtt_awaitresponse_flg_glb = false;
      }
      mqtt_loopstop_flg_glb = false;
    } else if (millis() - mqtt_responsetickcount_glb > mqtt_responsetimeout_glb) {
      mqtt_awaitresponse_flg_glb = false;
    }
  }

  if (mqtt_selectionwaiting_flg_glb) {
    sel_pin_currentstate_glb = digitalRead(sel_btn_pin_def);
    if (sel_pin_laststate_glb == LOW && sel_pin_currentstate_glb == HIGH) {
      Serial.printf("Firmware selected: %s. Sending request...\n", mqtt_fw_list_glb[mqtt_selectedindex_glb].c_str());
      sendSelectionRequest(mqtt_client_glb, mqtt_fw_list_glb);
      
      // Bat lai che do cho phan hoi tu Gateway (UPDATE_AVAILABLE)
      mqtt_awaitresponse_flg_glb = true;
      mqtt_responsetickcount_glb = millis();
      mqtt_loopstop_flg_glb = false;

      delay(3000);
      mqtt_selectionwaiting_flg_glb = false;
    }
    sel_pin_laststate_glb = sel_pin_currentstate_glb;
  }
  req_pin_laststate_glb = req_pin_currentstate_glb;
}
