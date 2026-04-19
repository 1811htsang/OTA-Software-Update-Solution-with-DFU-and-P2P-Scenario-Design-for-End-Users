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


