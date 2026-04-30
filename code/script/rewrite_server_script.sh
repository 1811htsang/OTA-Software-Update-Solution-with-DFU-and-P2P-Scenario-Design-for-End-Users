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

# @brief Tạo CRC-16 cho chuỗi hex
crc16_hex_v() {
  python3 - "$1" <<'PY'
import binascii
import sys

packet_hex = sys.argv[1]
packet_bytes = bytes.fromhex(packet_hex)
print(f"{binascii.crc_hqx(packet_bytes, 0xFFFF):04X}")
PY
}

# @brief Parse gói tin request từ gateway theo encode rule FF D1 Sync_Token CRC
parse_gateway_config_request_v() {
  local packet_v
  local cleaned_packet_v
  local header_v
  local gateway_id_v
  local sync_token_v
  local crc_v
  local packet_without_crc_v
  local calculated_crc_v

  packet_v="$1"
  cleaned_packet_v=$(echo "$packet_v" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')

  if [[ ${#cleaned_packet_v} -ne 16 ]]; then
    echo -e "${RED}[Error] Invalid gateway request length: $cleaned_packet_v${END}"
    return 1
  fi

  header_v=${cleaned_packet_v:0:2}
  gateway_id_v=${cleaned_packet_v:2:2}
  sync_token_v=${cleaned_packet_v:4:8}
  crc_v=${cleaned_packet_v:12:4}
  packet_without_crc_v=${cleaned_packet_v:0:12}
  calculated_crc_v=$(crc16_hex_v "$packet_without_crc_v")

  if [[ "$header_v" != "FF" || "$gateway_id_v" != "D1" ]]; then
    echo -e "${RED}[Error] Invalid gateway header or id.${END}"
    return 1
  fi

  if [[ "$crc_v" != "$calculated_crc_v" ]]; then
    echo -e "${RED}[Error] CRC mismatch for gateway request.${END}"
    return 1
  fi

  gateway_header_v="$header_v"
  gateway_request_id_v="$gateway_id_v"
  gateway_sync_token_v="$sync_token_v"
  gateway_request_crc_v="$crc_v"

  return 0
}

# @brief Đóng gói một bản ghi firmware cho gateway manifest response
build_server_manifest_packet_v() {
  local device_id_v="$1"
  local fw_count_v="$2"
  local fw_id_v="$3"
  local version_v="$4"
  local priority_v="$5"
  local last_update_v="$6"
  local payload_v
  local crc_v

  payload_v=$(printf "%02X%02X%04X%04X%02X%08X" "$device_id_v" "$fw_count_v" "$fw_id_v" "$version_v" "$priority_v" "$last_update_v")
  crc_v=$(crc16_hex_v "$payload_v")
  printf '%s%s' "$payload_v" "$crc_v"
}

# @brief Gửi manifest server lên gateway sau khi nhận request đồng bộ
send_server_manifest_v() {
  local manifest_rows_v
  local manifest_line_v
  local response_lines_v=""

  manifest_rows_v=$(sqlite3 -separator '|' "$database_path_v/server_db.db" "
WITH active_fw AS (
  SELECT d.device_id, f.fw_id, f.version, f.is_force, d.last_update_timestamp
  FROM devices d
  JOIN dev_join_fw j ON d.device_id = j.device_id
  JOIN firmwares f ON j.fw_id = f.fw_id
  WHERE d.status = 1
)
SELECT a.device_id,
       (SELECT COUNT(*) FROM active_fw b WHERE b.device_id = a.device_id) AS fw_count,
       a.fw_id,
       a.version,
       a.is_force,
       a.last_update_timestamp
FROM active_fw a
ORDER BY a.device_id, a.fw_id;")

  if [[ -z "$manifest_rows_v" ]]; then
    echo -e "${RED}[Error] No firmware manifest data found in server database.${END}"
    return 1
  fi

  while IFS='|' read -r device_id_v fw_count_v fw_id_v version_v priority_v last_update_v; do
    [[ -z "$device_id_v" ]] && continue
    manifest_line_v=$(build_server_manifest_packet_v "$device_id_v" "$fw_count_v" "$fw_id_v" "$version_v" "$priority_v" "$last_update_v")
    response_lines_v+="$manifest_line_v\n"
  done <<< "$manifest_rows_v"

  mosquitto_pub -h "$mqtt_server_ip_p" -p 1883 -u "$username_p" -P "$password_p" -t server/response -m "$(printf '%b' "$response_lines_v")" -r
}

# @brief Chờ request cấu hình từ gateway
echo -e "${GREEN}[INFO] Waiting for gateway configuration request incoming...${END}"
request_v=$(mosquitto_sub -h "$mqtt_server_ip_p" -p 1883 -u "$username_p" -P "$password_p" -C 1 -t server/request)

echo -e "${GREEN}[INFO] Received gateway configuration request: $request_v${END}"

if ! parse_gateway_config_request_v "$request_v"; then
  echo -e "${RED}[Error] Failed to parse gateway configuration request!${END}"
  exit 1
fi

echo -e "${GREEN}[INFO] Gateway request parsed successfully.${END}"
echo -e "${GREEN}[INFO] Header: $gateway_header_v${END}"
echo -e "${GREEN}[INFO] Request ID: $gateway_request_id_v${END}"
echo -e "${GREEN}[INFO] Sync Token: $gateway_sync_token_v${END}"

if ! send_server_manifest_v; then
  exit 1
fi

echo -e "${GREEN}[INFO] Server manifest response sent successfully.${END}"

# @brief Đợi một yêu cầu xác thực tiếp theo nếu luồng vận hành cần tiếp tục
echo -e "${GREEN}[INFO] Waiting for gateway validation request incoming...${END}"
validate_request_v=$(mosquitto_sub -h "$mqtt_server_ip_p" -p 1883 -u "$username_p" -P "$password_p" -C 1 -t server/request)
echo -e "${GREEN}[INFO] Received gateway validation request: $validate_request_v${END}"

exit 0