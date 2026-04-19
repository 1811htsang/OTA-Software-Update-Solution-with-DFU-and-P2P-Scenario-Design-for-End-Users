# Hướng dẫn tạo bảng phân vùng - *partition table* tùy chọn
Theo tài liệu `Partition tables` của ESP-IDF, địa chỉ gốc ban đầu của bảng là `0x8000`. Độ dài cố định của bảng là `0xCOO` ~ `3072` bytes => Nghĩa là cho phép tối đa 95 đầu vào - `entry` trong bảng.
Ở đây mỗi `entry` là 1 phân vùng - `partition` được xác định tại vị trí đầu tiên là `0x8000 + 0x100`.

Trong đó bảng sẽ tuân theo mẫu và lưu thành tệp `csv` như sau:
```
# ESP-IDF Partition Table
# Name,   Type, SubType, Offset,  Size, Flags
nvs,      data, nvs,     0x9000,  0x6000,
phy_init, data, phy,     0xf000,  0x1000,
factory,  app,  factory, 0x10000, 1M,
```
Ta có các cột như sau:
- `Name` dùng để lưu tên cho phân vùng với độ dài tối đa là `16` byte. Vượt quá độ dài sẽ bị cắt ngắn.
- `Type` là loại phân vùng, có thể được specified là tên hoặc số từ `0_10` đến `254_10` (`0x00_16` đến `0xFE_16`). 
    - `app` (`0x00`)
    - `data` (`0x01`)
    - `bootloader` (`0x02`) - {mặc định phân vùng này không được thêm vào trong bảng bởi vì không được yêu cầu và không ảnh hưởng đến chức năng hệ thống, **chỉ hữu dụng trong bootloader OTA update và flash partitioning, kể cả không thể hiện trong bảng cũng sẽ vẫn hữu dụng để thực hiện OTA**}
    - `partition_table` (`0x03`) - {**mặc định phân vùng này cũng không thêm vào bất kỳ bảng phân vùng nào trong ESP-IDF**}
    - Đối với các địa chỉ `0x04_16` đến `0xFE_16` sẽ được sử dụng cho các phân vùng tùy chỉnh. 
- Bootloader sẽ không sử dụng các phân vùng khác ngoài `app` và `data`. Tuy nhiên, các phân vùng này vẫn có thể được sử dụng trong ứng dụng của bạn.
- `SubType` là sự cụ thể của loại phân vùng với độ dài tối đa `8` bit. Ở hiện tại ESP-IDF ở thời điểm hiện tại chỉ specify cho các loại phân vùng `app` và `data`.
    - Khi `Type = app`, `SubType` có thể là: 
        - `factory` (`0x00`)
        - `ota_0` (`0x10`) đến `ota_15` (`0x1F`)
        - `test` (`0x20`)
    - Khi `Type = bootloader`, `SubType` có thể là:
        - `primary` (`0x00` - đây được xem là bootloader giai đoạn 2 tại vị trí `0x1000` trong bộ nhớ. **Đối với việc sử dụng ESP-IDF thì sẽ có công cụ hỗ trợ tự động, còn Arduino IDE thì không chắc chắn**)
        - `ota` (`0x01` - đây được xem là phân vùng bootloader tạm thời được sử dụng để hỗ trợ tải firmware cho chức năng OTA. **Đối với việc sử dụng ESP-IDF thì sẽ có công cụ hỗ trợ tự động, còn Arduino IDE thì không chắc chắn**) 
        - `recovery` (`0x02` - đây được xem là phân vùng recovery sử dụng cho thực hiện cập nhật OTA an toàn)
    - Khi `Type = partition_table`, `SubType` có thể là: 
        - `primary` (`0x00` - đây được xem là bảng phân vùng chính tại vị trí `0x8000` trong bộ nhớ)
        - `ota` (`0x01` - đây được xem là phân vùng của bảng phân vùng được sử dụng bởi chức năng OTA cho việc tải firmware)
        - Độ lớn của `Type = partition_table` được set cố định ở `0x1000` và áp dụng thống nhất đối với mọi `SubType` của `Type`. 
    - Khi `Type = data`, `SubType` có thể là:
        - `ota` (`0x00` - đây được xem là phân vùng dữ liệu OTA để lưu trữ thông tin về slot firmware OTA đang lựa chọn hiện tại. Phân vùng này nên có dung lượng `12288` bytes)
        - `phy` (`0x01` - dùng để lưu trữ dữ liệu khởi tạo vật lý cho phép config trên từng thiết bị thay vì trong firmware. Trong config mặc định thì phân vùng phy không được sử dụng và dữ liệu phy được khởi tạo bởi chính firmware. Do đó, không cần khai báo trên bảng để tiết kiệm bộ nhớ).
        - `nvs` (`0x02` - dùng để lưu trữ dữ liệu điều chỉnh PHY trên từng thiết bị, dữ liệu Wi-Fi nếu có khai báo, nên lưu trữ ít nhất `0x3000` byte và lưu trữ riêng biệt)
        - `nvs_keys` (`0x04` - dùng để lưu trữ phân vùng khóa NVS) 

        
