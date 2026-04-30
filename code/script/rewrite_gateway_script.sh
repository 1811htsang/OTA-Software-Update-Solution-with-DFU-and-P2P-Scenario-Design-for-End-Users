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

# @brief CRC-16 dùng cho packet hex
crc16_hex_v() {
  python3 - "$1" <<'PY'
import binascii
import sys

packet_hex = sys.argv[1]
packet_bytes = bytes.fromhex(packet_hex)
print(f"{binascii.crc_hqx(packet_bytes, 0xFFFF):04X}")
PY
}

# @brief Tạo request đồng bộ cấu hình từ gateway sang server
build_gateway_config_request_v() {
  local sync_token_dec_v
  local sync_token_hex_v
  local packet_without_crc_v
  local crc_v

  sync_token_dec_v=$(date +%s)
  sync_token_hex_v=$(printf "%08X" "$sync_token_dec_v")
  packet_without_crc_v="FFD1${sync_token_hex_v}"
  crc_v=$(crc16_hex_v "$packet_without_crc_v")
  printf '%s%s' "$packet_without_crc_v" "$crc_v"
}

# @brief Đảm bảo bảng lưu cache firmware tồn tại trong database gateway
ensure_gateway_database_schema_v() {
  sqlite3 "$database_path_v/gateway_db.db" <<'SQL'
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS firmwares (
  fw_id INTEGER PRIMARY KEY,
  version INTEGER NOT NULL,
  file_path TEXT,
  file_size INTEGER DEFAULT 0,
  checksum_sha256 TEXT,
  is_force INTEGER DEFAULT 0,
  sync_status INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS dev_join_fw (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id INTEGER NOT NULL,
  fw_id INTEGER NOT NULL,
  version INTEGER NOT NULL,
  is_force INTEGER DEFAULT 0,
  UNIQUE(device_id, fw_id)
);

CREATE TABLE IF NOT EXISTS system_sync (
  sync_key TEXT PRIMARY KEY,
  last_sync_timestamp INTEGER,
  server_status TEXT
);
SQL
}

# @brief Lưu manifest server vào database gateway
store_gateway_manifest_packet_v() {
  local packet_hex_v="$1"
  local clean_packet_hex_v
  local device_id_hex_v
  local fw_count_hex_v
  local fw_id_hex_v
  local version_hex_v
  local priority_hex_v
  local last_update_hex_v
  local crc_hex_v
  local payload_hex_v
  local calculated_crc_v
  local device_id_dec_v
  local fw_count_dec_v
  local fw_id_dec_v
  local version_dec_v
  local priority_dec_v
  local last_update_dec_v
  local local_file_path_v

  clean_packet_hex_v=$(echo "$packet_hex_v" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')

  if [[ ${#clean_packet_hex_v} -ne 26 ]]; then
    echo -e "${RED}[Error] Invalid server packet length: $clean_packet_hex_v${END}"
    return 1
  fi

  device_id_hex_v=${clean_packet_hex_v:0:2}
  fw_count_hex_v=${clean_packet_hex_v:2:2}
  fw_id_hex_v=${clean_packet_hex_v:4:4}
  version_hex_v=${clean_packet_hex_v:8:4}
  priority_hex_v=${clean_packet_hex_v:12:2}
  last_update_hex_v=${clean_packet_hex_v:14:8}
  crc_hex_v=${clean_packet_hex_v:22:4}
  payload_hex_v=${clean_packet_hex_v:0:22}
  calculated_crc_v=$(crc16_hex_v "$payload_hex_v")

  if [[ "$crc_hex_v" != "$calculated_crc_v" ]]; then
    echo -e "${RED}[Error] CRC mismatch for server packet: $clean_packet_hex_v${END}"
    return 1
  fi

  device_id_dec_v=$((16#$device_id_hex_v))
  fw_count_dec_v=$((16#$fw_count_hex_v))
  fw_id_dec_v=$((16#$fw_id_hex_v))
  version_dec_v=$((16#$version_hex_v))
  priority_dec_v=$((16#$priority_hex_v))
  last_update_dec_v=$((16#$last_update_hex_v))
  local_file_path_v="./code/arduino/firmware/cache/fw_${fw_id_dec_v}_v${version_dec_v}.bin"

  sqlite3 "$database_path_v/gateway_db.db" <<SQL
INSERT INTO firmwares (fw_id, version, file_path, file_size, checksum_sha256, is_force, sync_status)
VALUES ($fw_id_dec_v, $version_dec_v, '$local_file_path_v', 0, '', $priority_dec_v, 1)
ON CONFLICT(fw_id) DO UPDATE SET
  version = excluded.version,
  file_path = excluded.file_path,
  is_force = excluded.is_force,
  sync_status = excluded.sync_status;

INSERT INTO dev_join_fw (device_id, fw_id, version, is_force)
VALUES ($device_id_dec_v, $fw_id_dec_v, $version_dec_v, $priority_dec_v)
ON CONFLICT(device_id, fw_id) DO UPDATE SET
  version = excluded.version,
  is_force = excluded.is_force;

INSERT INTO system_sync (sync_key, last_sync_timestamp, server_status)
VALUES ('last_manifest_sync', $last_update_dec_v, 'OK')
ON CONFLICT(sync_key) DO UPDATE SET
  last_sync_timestamp = excluded.last_sync_timestamp,
  server_status = excluded.server_status;
SQL

  echo -e "${GREEN}[INFO] Cached server manifest for device $device_id_dec_v, fw $fw_id_dec_v.${END}"
}

# @brief Làm mới manifest từ server qua MQTT
refresh_manifest_from_server_v() {
  local request_packet_v
  local response_packets_v
  local response_line_v

  request_packet_v=$(build_gateway_config_request_v)
  echo -e "${GREEN}[INFO] Gateway config request packet: $request_packet_v${END}"

  mosquitto_pub \
    -h "$mqtt_server_ip_p" \
    -p 1883 \
    -u "$username_p" \
    -P "$password_p" \
    -t server/request \
    -m "$request_packet_v" \
    -r

  response_packets_v=$(mosquitto_sub -h "$mqtt_server_ip_p" -p 1883 -u "$username_p" -P "$password_p" -C 1 -W 3 -t server/response)

  if [[ -z "$response_packets_v" ]]; then
    echo -e "${RED}[Error] No manifest response received from server.${END}"
    return 1
  fi

  while IFS= read -r response_line_v; do
    [[ -z "$response_line_v" ]] && continue
    store_gateway_manifest_packet_v "$response_line_v" || return 1
  done <<< "$response_packets_v"
}

# @brief Tìm firmware local theo firmware id
get_local_firmware_v() {
  sqlite3 -separator '|' "$database_path_v/gateway_db.db" "
SELECT fw_id, version, file_path, file_size, is_force, sync_status
FROM firmwares
WHERE fw_id = $1
LIMIT 1;"
}

# @brief Đóng gói phản hồi cho ESP32 theo rule 0xBB
build_gateway_device_response_v() {
  local status_v="$1"
  local fw_count_v="$2"
  local fw_id_v="$3"
  local version_v="$4"
  local file_size_v="$5"
  local force_v="$6"
  local payload_v
  local crc_v

  payload_v=$(printf "%02X%02X%02X%04X%04X%08X%02X" 0xBB "$status_v" "$fw_count_v" "$fw_id_v" "$version_v" "$file_size_v" "$force_v")
  crc_v=$(crc16_hex_v "$payload_v")
  printf '%s%s' "$payload_v" "$crc_v"
}

# @brief Gửi packet phản hồi sang ESP32
publish_device_response_v() {
  local device_id_v="$1"
  local response_hex_v="$2"

  mosquitto_pub \
    -h "$mqtt_server_ip_p" \
    -p 1883 \
    -u "$username_p" \
    -P "$password_p" \
    -t "nckhsv/$device_id_v/response" \
    -m "$response_hex_v" \
    -r
}

echo -e "${GREEN}[INFO] Synchronizing gateway manifest from server...${END}"
ensure_gateway_database_schema_v
if ! refresh_manifest_from_server_v; then
  exit 1
fi

echo -e "${GREEN}[INFO] Waiting for end user request incoming...${END}"
request_v=$(mosquitto_sub -h "$mqtt_server_ip_p" -p 1883 -u "$username_p" -P "$password_p" -C 1 -t nckhsv/+/request)
echo -e "${GREEN}[INFO] Received end user request: $request_v${END}"

device_id_v=$(echo "$request_v" | cut -d' ' -f1)
ctrl_code_v=$(echo "$request_v" | cut -d' ' -f2)
firmware_id_v=$(echo "$request_v" | cut -d' ' -f3)
current_ver_v=$(echo "$request_v" | cut -d' ' -f4)
checksum_v=$(echo "$request_v" | cut -d' ' -f5)

# @brief Hiển thị thông tin trích xuất được để xác nhận trước khi tiếp tục
echo -e "${GREEN}[INFO] Extracted Device ID: $device_id_v${END}"
echo -e "${GREEN}[INFO] Extracted Control Code: $ctrl_code_v${END}"
echo -e "${GREEN}[INFO] Extracted Firmware ID: $firmware_id_v${END}"
echo -e "${GREEN}[INFO] Extracted Current Version: $current_ver_v${END}"
echo -e "${GREEN}[INFO] Extracted Checksum: $checksum_v${END}"

local_record_v=$(get_local_firmware_v "$firmware_id_v")

if [[ -z "$local_record_v" ]]; then
  echo -e "${YELLOW}[INFO] Firmware $firmware_id_v not found locally. Refreshing from server...${END}"
  if ! refresh_manifest_from_server_v; then
    exit 1
  fi
  local_record_v=$(get_local_firmware_v "$firmware_id_v")
fi

if [[ -z "$local_record_v" ]]; then
  echo -e "${RED}[Error] Firmware $firmware_id_v still not available after sync.${END}"
  exit 1
fi

IFS='|' read -r local_fw_id_v local_version_v local_file_path_v local_file_size_v local_force_v local_sync_status_v <<< "$local_record_v"

if [[ "$realtime_mode_p" -eq 1 ]]; then
  echo -e "${GREEN}[INFO] Realtime mode: trust local cache and compare versions directly.${END}"
else
  echo -e "${GREEN}[INFO] Non-realtime mode: local cache has been refreshed from server before decision.${END}"
fi

if [[ "$local_version_v" -le "$current_ver_v" ]]; then
  echo -e "${YELLOW}[INFO] No update needed. Local firmware version is not newer than device version.${END}"
  response_hex_v=$(build_gateway_device_response_v 0 0 "$local_fw_id_v" "$local_version_v" "$local_file_size_v" "$local_force_v")
  publish_device_response_v "$device_id_v" "$response_hex_v"
  exit 0
fi

echo -e "${GREEN}[INFO] Update available. Preparing device response packet.${END}"

if [[ ! -f "$local_file_path_v" ]]; then
  mkdir -p "$(dirname "$local_file_path_v")"
  : > "$local_file_path_v"
fi

response_hex_v=$(build_gateway_device_response_v 1 1 "$local_fw_id_v" "$local_version_v" "$local_file_size_v" "$local_force_v")
publish_device_response_v "$device_id_v" "$response_hex_v"

echo -e "${GREEN}[INFO] Device response published successfully.${END}"

exit 0
