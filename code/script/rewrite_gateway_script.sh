# @file rewrite_gateway_script.sh
# @author Shang Huang 
# @brief Script for rewriting gateway configuration
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

echo -e "${GREEN}[INFO] Starting gateway script rewrite...${END}"

# @brief Khai báo tham số đầu vào dành cho giao tiếp 
# @attention '_p' đại diện cho parameter
mqtt_server_ip_p=$1
username_p=$2
password_p=$3
realtime_mode_p=$4

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
if [[ ! -f "$script_path_v/gateway_script.sh" ]]; then
  echo -e "${RED}[Error] Gateway script not found at $script_path_v/gateway_script.sh!${END}"
  exit 1
fi

# @brief Khai báo đường dẫn tới database lưu trữ thông tin
database_path_v="./database"

# @brief Bổ sung kiểm tra tệp database để đảm bảo tồn tại trước khi thực thi
if [[ ! -f "$database_path_v/gateway_db.db" ]]; then
  echo -e "${RED}[Error] Database not found at $database_path_v/gateway_db.db!${END}"
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

# @brief Bắt đầu lắng nghe yêu cầu cập nhật từ ESP32 thông qua MQTT
echo -e "${GREEN}[INFO] Waiting for end user request incoming...${END}"
request_v=$(mosquitto_sub -h $mqtt_server_ip_p -p 1883 -u $username_p -P $password_p -C 1 -t nckhsv/+/request)

# @brief Hiển thị thông tin yêu cầu đã nhận từ ESP32 để xác nhận trước khi tiếp tục
echo -e "${GREEN}[INFO] Received end user request: $request_v${END}"

# @brief Trích xuất thông tin từ yêu cầu nhận được để xác định thiết bị và loại yêu cầu
device_id_v=$(echo $request_v | cut -d' ' -f1)
ctrl_code_v=$(echo $request_v | cut -d' ' -f2)
firmware_id_v=$(echo $request_v | cut -d' ' -f3)
current_ver_v=$(echo $request_v | cut -d' ' -f4)
checksum_v=$(echo $request_v | cut -d' ' -f5)

# @brief Hiển thị thông tin trích xuất được để xác nhận trước khi tiếp tục
echo -e "${GREEN}[INFO] Extracted Device ID: $device_id_v${END}"
echo -e "${GREEN}[INFO] Extracted Control Code: $ctrl_code_v${END}"
echo -e "${GREEN}[INFO] Extracted Firmware ID: $firmware_id_v${END}"
echo -e "${GREEN}[INFO] Extracted Current Version: $current_ver_v${END}"
echo -e "${GREEN}[INFO] Extracted Checksum: $checksum_v${END}"

# @brief Bắt đầu xử lý yêu cầu dựa trên thông tin đã trích xuất
# @attention Cần thực hiện kiểm tra checksum 
#            để đảm bảo tính toàn vẹn của dữ liệu
query_v="
  SELECT 
    MAX(f.fw_id), 
    f.version, 
    f.file_size, 
    j.is_force 
  FROM firmwares f
  JOIN dev_join_fw j ON f.fw_id = j.fw_id
  WHERE j.device_id = $device_id_v 
  AND f.version > $current_ver_v; 
-- Kết quả này dùng để đóng gói vào bản tin 0xBB gửi ESP32
"
fetching_result_v=$(sqlite3 $database_path_v/gateway_db.db "$query_v")

# @brief Bắt đầu so khớp yêu cầu so với cơ sở dữ liệu nội bộ của gateway 
#        để xác định xem có cần cập nhật firmware hay không
# @attention Lưu ý đối chiếu với realtime_mode_p để 
#            quyết định kịch bản xử lý tiếp theo 
# @example Nếu realtime_mode_p là 1 
#           thì là kịch bản GW và SV realtime đồng bộ FW
#          Nếu realtime_mode_p là 0
#           thì là kịch bản GW và SV không đồng bộ FW 
#           GW cần kiểm tra so khớp FW từ database nội bộ với FW của server 
#           để để kiểm tra xem có cần update FW của GW trước 
#           khi cho phép thiết bị cập nhật FW hay không

# @brief Hiển thị kết quả truy vấn để xác nhận trước khi tiếp tục
echo -e "${GREEN}[INFO] Database query result: $fetching_result_v${END}"

# @brief Bắt đầu parsing kết quả truy vấn để xác định thông tin firmware mới nhất
# @attention chỉ lấy fw_id và version để so sánh với yêu cầu của ESP32
fetching_fw_id_v=$(echo $fetching_result_v | cut -d'|' -f1)
fetching_version_v=$(echo $fetching_result_v | cut -d'|' -f2)

# @brief Kiểm tra nếu fw_id từ request của ESP32 đã là phiên bản mới nhất thì không cần cập nhật
if [[ "$fetching_fw_id_v" -le "$firmware_id_v" ]]; then
  echo -e "${YELLOW}[INFO] No update needed. Device is already on the latest firmware version.${END}"
  exit 0
else 
  if [[ "$realtime_mode_p" -eq 1 ]]; then
    echo -e "${GREEN}[INFO] Realtime mode enabled. Proceeding with firmware update...${END}"
    # @brief Thực hiện các bước cần thiết để cập nhật firmware cho thiết bị
  else 
    echo -e "${GREEN}[INFO] Non-realtime mode enabled. Checking gateway firmware version...${END}"
    # @brief Thực hiện các bước cần thiết để kiểm tra giữa GW và SV
  fi
fi

