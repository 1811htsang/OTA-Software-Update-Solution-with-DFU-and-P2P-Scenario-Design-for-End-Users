# Quy tắc quản lý mã hóa thông điệp trong hệ thống

## Thông điệp yêu cầu cấu hình từ gateway đến server

Mã code đi từ phía Gateway chứa các trường thông tin sau:

- Header (1 byte) mang giá trị `0xFF` để chỉ định đây là một yêu cầu cấu hình từ gateway.
- ID (1 byte) mang giá trị `0xD1` để chỉ định đây là một yêu cầu cấu hình. (Lưu ý do trong hệ thống chỉ có 1 gateway nên ID này có thể được sử dụng để phân biệt nếu có nhiều gateway trong tương lai)
- Sync_Token (4 bytes) mang giá trị unix timestamp tại thời điểm gửi thông điệp. Trường này giúp server xác định thời điểm gửi yêu cầu và có thể sử dụng để đồng bộ hóa dữ liệu nếu cần thiết.
- CRC (1 byte) được tính toán dựa trên các trường trước đó để đảm bảo tính toàn vẹn của thông điệp. CRC sẽ được tính bằng cách sử dụng thuật toán CRC-16 trên các trường Header, ID và Sync_Token. CRC-16 này sẽ lấy 2 byte kết quả đầu tiên để gửi trong thông điệp, giúp giảm kích thước gói tin mà vẫn đảm bảo khả năng phát hiện lỗi cơ bản.

Server sẽ nhận được thông điệp này và trả lại thông điệp như sau:

- Mỗi thiết bị sẽ có số lượng firmware khác nhau. Do đó, với mỗi thiết bị thì server sẽ trả về một thông điệp riêng biệt chứa thông tin về firmware của thiết bị đó.
- Device_ID (1 byte) mang giá trị từ `0x01` đến `0x90` để chỉ định thiết bị cụ thể mà thông điệp này đang đề cập đến. (Lưu ý rằng Device_ID sẽ sử dụng 1 byte truncated địa chỉ MAC của thiết bị để ánh xạ đến một ID duy nhất trong hệ thống)
- FW_Count (1 byte) mang giá trị từ `0x00` đến `0xFF` để chỉ định số lượng firmware mà thiết bị này đang có. Trường này giúp server biết được có bao nhiêu firmware cần được cập nhật cho thiết bị này.
- Latest_Ver (2 bytes) là phiên bản mới nhất SV đang có (ví dụ 2.6 -> 26)
- FW_ID (2 byte) là ID của loại phần mềm dành cho thiết bị này
- Last_Update (4 byte) Unix Timestamp (Ngày cập nhật gần nhất của thiết bị này)
- Priority (1 byte) 0: Bình thường, 1: Bắt buộc (Force Update)

Ví dụ

```markdown
- Device_ID là 0x5
- FW_Count là 3
- FW_ID 1 là 0x03e8 + Priority 0
- FW_ID 2 là 0x03b2 + Priority 1
- FW_ID 3 là 0x02d4 + Priority 1
- Last_Update là 653B6F00 
-> Chuỗi packet hoàn chỉnh là `0x05 0x03 0x03e8 0x00 0x0302 0x01 0x02d4 0x01 0x653B6F00`.
Sau khi thực hiện CRC-16 trên các trường này.
-> Giả sử kết quả là `0x1A2B` 
   Thông điệp hoàn chỉnh sẽ là `0x05 0x03 0x03e8 0x00 0x0302 0x01 0x02d4 0x01 0x653B6F00 0x1A2B`
```

## Thông điệp yêu cầu cập nhật firmware từ device đến gateway

Khi một thiết bị gửi yêu cầu cập nhật firmware đến gateway, thông điệp sẽ bao gồm các trường sau:

- Device ID (1 byte) là ID duy nhất của thiết bị ESP32 (Lấy từ địa chỉ MAC).
- Control Code (1 byte) là Mã lệnh (Ví dụ: 0x01: Check update, 0x02: Heartbeat, 0x03: P2P Request).
- Firmware ID (2 byte) là ID của loại phần mềm.
- Current Version (2 byte) là Phiên bản hiện tại (Ví dụ: 25 ứng với 2.5). Có thể chia làm 1 byte Major, 1 byte Minor.
- Checksum/CRC (1 byte) là Mã kiểm tra lỗi để đảm bảo gói tin không bị sai lệch khi truyền không dây.

## Thông điệp phản hồi từ gateway đến device

Sau khi Gateway (GW) nhận request và validate Device ID từ ESP32, chúng ta cần một quy trình "Handshake" (bắt tay) để ESP32 biết có những lựa chọn nào và quyết định tải bản cập nhật nào.

| Field | Size | Giá trị/Mô tả |
| :--- | :--- | :--- |
| **Header** | 1 byte | `0xBB` (Ký hiệu gói tin Response) |
| **Status** | 1 byte | `0x00`: Không có Update, `0x01`: Có Update, `0x02`: Error |
| **FW Count (N)** | 1 byte | Số lượng Firmware khả dụng cho thiết bị này |
| **Payload (N lần)** | **9 bytes** | Lặp lại cho mỗi FW: - `FW_ID` (2B)  - `Version` (2B)  - `Size` (4B - Dung lượng file để ESP32 phân bổ bộ nhớ)  - `Force` (1B) |
| **CRC** | 2 byte | Kiểm tra toàn vẹn gói tin |

**Ví dụ thực tế:** Gateway báo có 1 bản update bắt buộc:
`0xBB 0x01 0x01 [0x03E8][0x001A][0x0004B250][0x01] [CRC]`
*(Giải thích: Có 1 FW ID 1000, Ver 2.6, Nặng 307.792 bytes, Bắt buộc)*

## Thông điệp chọn bản cập nhật từ device đến gateway

Sau khi ESP32 nhận được "Menu", nó sẽ dựa vào logic nội bộ (ưu tiên bản Force hoặc bản mới nhất) để gửi gói tin xác nhận tải.

| Field | Size | Giá trị/Mô tả |
| :--- | :--- | :--- |
| **Header** | 1 byte | `0xCC` (Ký hiệu gói tin Select) |
| **Selected FW ID** | 2 byte | ID của Firmware mà ESP32 chọn để tải |
| **Preferred Block Size** | 2 byte | ESP32 đề nghị kích thước mỗi gói dữ liệu (ví dụ 512 hoặc 1024 bytes) tùy theo dung lượng RAM trống |
| **Protocol** | 1 byte | `0x01`: FTP, `0x02`: HTTP, `0x03`: P2P (Nếu bạn muốn linh hoạt) |
| **CRC** | 2 byte | Kiểm tra toàn vẹn |

**Ví dụ thực tế:** ESP32 chọn tải FW ID 1000 qua P2P:
`0xCC 0x03E8 0x0200 0x03 [CRC]`
*(Giải thích: Chọn ID 1000, nhận mỗi block 512 bytes, dùng giao thức P2P)*

## Thông điệp dữ liệu cập nhật từ gateway đến device

| Field | Size | Mô tả |
| :--- | :--- | :--- |
| **Header** | 1 byte | `0xDD` |
| **FTP IP** | 4 byte | IP của Gateway (hoặc IP của Peer nếu là kịch bản P2P) |
| **FTP Port** | 2 byte | Thường là 21 |
| **User Len** | 1 byte | Độ dài của Username |
| **User** | Variable | Chuỗi Username (Ví dụ: "ota_user") |
| **Pass Len** | 1 byte | Độ dài của Password |
| **Pass** | Variable | Chuỗi Password |
| **Path Len** | 1 byte | Độ dài đường dẫn file |
| **File Path** | Variable | Ví dụ: `/fw/1000_v26.bin` |
| **CRC** | 2 byte | Kiểm tra toàn vẹn |
