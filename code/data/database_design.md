# Thiết kế Cơ sở dữ liệu SQLite cho Server

## 1. Bảng `devices` (Quản lý thiết bị End-user)

Lưu trữ thông tin định danh và trạng thái hiện tại của từng ESP32.

```sql
CREATE TABLE devices (
  device_id INTEGER PRIMARY KEY,    -- Khớp với ID 8-bit (0-255)
  mac_address TEXT UNIQUE,          -- Định danh vật lý để tránh trùng ID
  current_version INTEGER,          -- Phiên bản hiện tại thiết bị đang chạy (2.5 -> 25)
  last_update_timestamp INTEGER,    -- Unix Timestamp lần cập nhật cuối thành công
  status INTEGER DEFAULT 1          -- 1: Online, 0: Offline, 2: Updating...
);
```

## 2. Bảng `firmwares` (Kho lưu trữ Metadata Firmware)

Bảng này dùng để tạo gói tin **0xBB (Response)**.

```sql
CREATE TABLE firmwares (
  fw_id INTEGER PRIMARY KEY,        -- Khớp với FW ID 16-bit
  version INTEGER,                  -- Phiên bản (ví dụ 26 cho v2.6)
  file_path TEXT,                   -- Đường dẫn tuyệt đối trên Gateway để FTP truy cập
  file_size INTEGER,                -- Kích thước file (bytes) để gửi cho ESP32
  checksum_sha256 TEXT,             -- Mã băm để ESP32 kiểm tra sau khi tải xong
  is_force INTEGER DEFAULT 0,       -- 0: Thường, 1: Bắt buộc (Force Update)
  sync_status INTEGER DEFAULT 1     -- 1: Đã đồng bộ từ Server, 0: Cần tải từ Server về GW
);
```

## 3. Bảng `peers_map` (Phục vụ kịch bản P2P)

Đây là bảng "linh hồn" của P2P. Nó cho biết thiết bị nào đã có bản firmware nào để Gateway điều hướng ESP32 khác đến tải (thay vì tải từ Gateway).

```sql
CREATE TABLE peers_map (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id INTEGER,                -- ID của thiết bị đóng vai trò "Source" (ví dụ ESP32-S3)
  fw_id INTEGER,                    -- ID firmware mà thiết bị này đang giữ
  version INTEGER,                  -- Phiên bản mà nó đang có
  ip_address TEXT,                  -- IP nội bộ để ESP32 khác kết nối FTP P2P
  last_verified INTEGER,            -- Lần cuối Gateway xác nhận Node này còn online
  FOREIGN KEY(device_id) REFERENCES devices(device_id)
);
```

## 4. Bảng `system_sync` (Giả lập trạng thái Real-time)

Dùng để kiểm tra xem Gateway và Server có đang khớp nhau không.

```sql
CREATE TABLE system_sync (
  sync_key TEXT PRIMARY KEY,        -- Ví dụ: 'last_manifest_sync'
  last_sync_timestamp INTEGER,      -- Unix timestamp lần cuối hỏi Server
  server_status TEXT                -- 'OK', 'MAINTENANCE', v.v.
);
```

## Hướng dẫn sử dụng với sqlite

- `sqlite3 firmware_update.db` để mở database.
- Sử dụng các câu lệnh SQL để thêm/sửa/xóa dữ liệu.

## Ví dụ 1

Khi nhận Request từ ESP32 (ID: 05, Ver: 25):
Gateway chạy: `SELECT * FROM firmwares WHERE version > 25 AND sync_status = 1;`
Dữ liệu trả về (fw_id, version, size, is_force) được nạp trực tiếp vào Gói tin `0xBB`.

## Ví dụ 2

Khi ESP32 gửi Select (ID: 1000):
Gateway kiểm tra P2P trước: `SELECT ip_address FROM peers_map WHERE fw_id = 1000 AND version = 26 LIMIT 1;`
Nếu có kết quả: Gateway đóng gói IP của Peer vào Gói tin `0xDD`.
Nếu không có: Gateway đóng gói IP của chính nó (Jetson Nano) vào Gói tin `0xDD`.
