# @file rewrite_server_script.sh
# @author Shang Huang 
# @brief Script for rewriting server configuration
# @version 0.1
# @date 2026-04-19
# @copyright MIT License

# @brief Khai báo đường dẫn bash
#! /bin/bash

# @brief Khai báo các biến môi trường cần thiết cho script
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
END='\033[0m'

echo -e "${GREEN}[INFO] Starting server script rewrite...${END}"

# @brief Khai báo tham số đầu vào dành cho giao tiếp 
# @attention '_p' đại diện cho parameter
mqtt_server_ip_p=$1
username_p=$2
password_p=$3

# @brief Khai báo tham số đường dẫn vào dự án
project_path_p=$(pwd)

# @brief Bổ sung kiểm tra đường dẫn vào dự án để tránh lỗi khi chạy script
# @attention Đường dẫn vào dự án phải có pattern '/NCKH' để đảm bảo đúng vị trí
if [[ "$project_path_p" != *"/NCKH"* ]]; then
  echo -e "${RED}[Error] Invalid project path argument!${END}"
  exit 1
fi

# @brief Khai báo các đường dẫn file script
script_path_v="./code/script"

# @brief Bổ sung kiểm tra file script để đảm bảo tồn tại trước khi thực thi
if [[ ! -f "$script_path_v/server_script.sh" ]]; then
  echo -e "${RED}[Error] Server script not found at $script_path_v/server_script.sh!${END}"
  exit 1
fi

# @brief Khai báo đường dẫn tới database lưu trữ thông tin
database_path_v="./database"

# @brief Bổ sung kiểm tra tệp database để đảm bảo tồn tại trước khi thực thi
if [[ ! -f "$database_path_v/server_db.db" ]]; then
  echo -e "${RED}[Error] Database not found at $database_path_v/server_db.db!${END}"
  exit 1
fi

# @brief Hiển thị thông tin cấu hình đã nhận được để xác nhận trước khi tiếp tục
# @attention Không hiển thị mật khẩu trong log để đảm bảo bảo mật
echo -e "${GREEN}[INFO] Project path: $project_path_p${END}"
echo -e "${GREEN}[INFO] MQTT Server IP: $mqtt_server_ip_p${END}"
echo -e "${GREEN}[INFO] Username: $username_p${END}"
echo -e "${GREEN}[INFO] Password: [HIDDEN]${END}"
echo -e "${GREEN}[INFO] Script path: $script_path_v${END}"
echo -e "${GREEN}[INFO] Database path: $database_path_v${END}"
echo -e "${GREEN}[INFO] All checks passed.${END}"

# @brief Bắt đầu lắng nghe yêu cầu cấu hình từ gateway thông qua MQTT
echo -e "${GREEN}[INFO] Waiting for gateway configuration request incoming...${END}"
request_v=$(mosquitto_sub -h $mqtt_server_ip_p -p 1883 -u $username_p -P $password_p -C 1 -t server/request)

# @brief Hiển thị thông tin yêu cầu cấu hình đã nhận được để xác nhận trước khi tiếp tục
echo -e "${GREEN}[INFO] Received gateway configuration request: $request_v${END}"

# Function to parse encoded packet from gateway configuration request
parse_gateway_config_request() {
  local packet="$1"

  # Ensure the packet has the minimum required length (7 bytes: Header, ID, Sync_Token, CRC)
  if [[ ${#packet} -lt 7 ]]; then
    echo -e "${RED}[Error] Invalid packet length!${END}"
    return 1
  fi

  # Extract fields from the packet
  local header="${packet:0:2}"
  local id="${packet:2:2}"
  local sync_token="${packet:4:8}"
  local crc="${packet:12:2}"

  # Check CRC 
  local calculated_crc=$(python3 -c "
    import binascii
    data = bytes.fromhex('050303E80003B20102D401653B6F00')
    crc = binascii.crc_hqx(data, 0xFFFF)
    print(f'{hex(crc).upper()}')
  ")

  # Validate the header and ID
  if [[ "$header" != "FF" || "$id" != "D1" ]]; then
    echo -e "${RED}[Error] Invalid packet header or ID!${END}"
    return 1
  fi

  # Validate CRC
  if [[ "$crc" != "${calculated_crc:2:2}" ]]; then
    echo -e "${RED}[Error] CRC check failed!${END}"
    return 1
  fi

  # Assign extracted values to variables
  gateway_header="$header"
  gateway_id="$id"
  gateway_sync_token="$sync_token"
  gateway_crc="$crc"

  echo -e "${GREEN}[INFO] Parsed packet successfully:${END}"
  echo -e "${GREEN}[INFO] Header: $gateway_header${END}"
  echo -e "${GREEN}[INFO] ID: $gateway_id${END}"
  echo -e "${GREEN}[INFO] Sync Token: $gateway_sync_token${END}"
  echo -e "${GREEN}[INFO] CRC: $gateway_crc${END}"

  return 0
}

is_pass_v= parse_gateway_config_request "$request_v"

# @brief Gọi hàm phân tích yêu cầu cấu hình từ gateway
if [[ $is_pass_v -eq 0 ]]; then
  echo -e "${GREEN}[INFO] Gateway configuration request parsed successfully.${END}"
else
  echo -e "${RED}[Error] Failed to parse gateway configuration request!${END}"
  exit 1
fi

# @brief Sau khi phân tích yêu cầu cấu hình, server sẽ thực hiện các bước cần thiết để cập nhật cấu hình và phản hồi lại gateway
# @attention Bước này sẽ gọi sqlite để lấy cấu hình toàn bộ 
#            các thiết bị và gửi lại cho gateway thông qua MQTT
command_v="
SELECT devices.device_id, devices.device_name, devices.device_type, firmwares.fw_version
FROM dev_join_fw 
  JOIN devices ON dev_join_fw.device_id = devices.device_id
  JOIN firmwares ON dev_join_fw.fw_id = firmwares.fw_id;
"

# @brief Truy vấn cơ sở dữ liệu để lấy thông tin firmware cho từng thiết bị
query_v="
  SELECT devices.device_id, firmwares.fw_id, firmwares.version, firmwares.file_size, firmwares.is_force, devices.last_update_timestamp \n
  FROM dev_join_fw \n
  JOIN devices ON dev_join_fw.device_id = devices.device_id \n
  JOIN firmwares ON dev_join_fw.fw_id = firmwares.fw_id \n
  WHERE devices.status = 1;
"

# @brief Thực thi truy vấn và lưu kết quả vào biến
results_v=$(sqlite3 "$database_path_v/server_db.db" "$query_v")

# @brief Kiểm tra nếu không có dữ liệu trả về
if [[ -z "$results_v" ]]; then
  echo -e "${RED}[Error] No data found for devices!${END}"
  exit 1
fi

# @brief Đóng gói dữ liệu trả về theo định dạng quy tắc mã hóa thông điệp
response_v=""
while IFS="|" read -r device_id fw_id version file_size is_force last_update; do
  # Chuyển đổi dữ liệu thành định dạng hex
  device_id_hex_v=$(printf "%02X" "$device_id")
  fw_id_hex_v=$(printf "%04X" "$fw_id")
  version_hex_v=$(printf "%04X" "$version")
  file_size_hex_v=$(printf "%08X" "$file_size")
  is_force_hex_v=$(printf "%02X" "$is_force")
  last_update_hex_v=$(printf "%08X" "$last_update")

  # Đóng gói thông điệp
  packet_v="$device_id_hex_v$fw_id_hex_v$version_hex_v$file_size_hex_v$is_force_hex_v$last_update_hex_v"

  # Tính toán CRC
  crc=$(python3 -c "import binascii; data=bytes.fromhex('$packet_v'); print(binascii.crc_hqx(data, 0xFFFF).to_bytes(2, 'big').hex().upper())")

  # Thêm CRC vào thông điệp
  packet_v="$packet_v$crc"

  # Thêm thông điệp vào phản hồi
  response_v+="$packet_v\n"
done <<< "$results_v"

# @brief Gửi phản hồi lại cho gateway thông qua MQTT
echo -e "${GREEN}[INFO] Sending response_v to gateway...${END}"
echo -e "$response_v" | mosquitto_pub -h "$mqtt_server_ip_p" -p 1883 -u "$username_p" -P "$password_p" -t server/response -l

# @brief Xác nhận đã gửi thành công
echo -e "${GREEN}[INFO] response_v sent successfully.${END}"

# @brief Sleep 10s để quá trình truyền hoàn tất và reset lại mqtt history để tránh lỗi khi chạy lại script
sleep 10

# @brief Gọi ./clear.sh để xóa mqtt history
# @attention Sau khi clear xong thì bắt đầu thử nghiệm giả lập kịch bản DFU
bash "$script_path_v/clear.sh"

# @brief Đợi validation request từ gateway để bắt đầu quá trình DFU
echo -e "${GREEN}[INFO] Waiting for gateway validation request incoming...${END}"
validate_request_v=$(mosquitto_sub -h "$mqtt_server_ip_p" -p 1883 -u "$username_p" -P "$password_p" -C 1 -t server/request)

# @brief Hiển thị thông tin yêu cầu xác thực đã nhận được để xác nhận trước khi tiếp tục
echo -e "${GREEN}[INFO] Received gateway validation request: $validate_request_v${END}"

# @brief Tạm thời dừng ở đây, lát làm tiếp 
end