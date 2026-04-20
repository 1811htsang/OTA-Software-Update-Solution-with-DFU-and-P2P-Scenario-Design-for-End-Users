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

is_pass= parse_gateway_config_request "$request_v"

# @brief Gọi hàm phân tích yêu cầu cấu hình từ gateway
if [[ $is_pass -eq 0 ]]; then
  echo -e "${GREEN}[INFO] Gateway configuration request parsed successfully.${END}"
else
  echo -e "${RED}[Error] Failed to parse gateway configuration request!${END}"
  exit 1
fi

# @brief Sau khi phân tích yêu cầu cấu hình, server sẽ thực hiện các bước cần thiết để cập nhật cấu hình và phản hồi lại gateway
# @attention Bước này sẽ gọi sqlite để lấy cấu hình toàn bộ 
#            các thiết bị và gửi lại cho gateway thông qua MQTT
sqlite3 