#! /bin/bash

# Script hoạt động của gate way trong hệ thống cập nhật firmware OTA cho ESP32 qua MQTT và FTP.
# Hoạt động của script:
# 1. Khởi tạo và Tham số đầu vào:
# 	Script nhận hai tham số khi chạy: 
# 		mqtt_server_ip (địa chỉ IP của máy chủ MQTT) 
# 		server_ftp_ip (địa chỉ IP của máy chủ FTP).
# In ra thông báo bắt đầu hoạt động và địa chỉ MQTT server.
# 2. Cấu hình FTP tự động đăng nhập (.netrc):
# 	Tạo hoặc ghi thêm vào file ~/.netrc các thông tin đăng nhập FTP 
# 	để cho phép lệnh ftp tự động đăng nhập mà không cần nhập username/password thủ công. 
# 	Có hai cặp thông tin đăng nhập được cấu hình.
# 	Phân quyền cho file ~/.netrc là 600 để chỉ chủ sở hữu có thể đọc/ghi, tăng cường bảo mật.
# 3. Kiểm tra kết nối tới Server FTP:
# 	Sử dụng lệnh ping để kiểm tra kết nối tới server_ftp_ip 5 lần.
# 	Nếu không kết nối được, in thông báo lỗi và thoát script.
# 4. Kiểm tra và tạo file log/danh sách thiết bị:
# 	Kiểm tra sự tồn tại của ~/device_list.txt và tạo nếu chưa có.
# 	Kiểm tra sự tồn tại của ~/ftp_log.txt, ~/last_ftp_log.txt, ~/diff_check.txt và tạo chúng nếu chưa có.
# 5. Chờ yêu cầu cập nhật từ ESP32 (qua MQTT):
# 	Sử dụng mosquitto_sub để lắng nghe một tin nhắn MQTT trên topic nckhsv/+/request (với QoS 1) từ ESP32.
# 	Lưu tin nhắn nhận được vào biến request_message.
# 6. Xử lý và xác thực yêu cầu từ ESP32:
# 	Hiển thị tin nhắn nhận được và phân tích cú pháp JSON để lấy deviceID, chipID, và requestType.
# 	Xác thực cơ bản: Kiểm tra xem deviceID, chipID, và requestType có rỗng hay không. 
# 	Nếu rỗng, gửi lỗi "Invalid request message" qua MQTT và thoát.
# 	Xác thực loại yêu cầu: Kiểm tra xem requestType có phải là "UPDATE_REQUEST" hay không. 
# 	Nếu không phải, gửi lỗi "Invalid request type" qua MQTT và thoát.
# 7. Gửi thông tin thiết bị đến Server (qua MQTT) để xác thực và kiểm tra firmware:
# 	Nếu yêu cầu từ ESP32 hợp lệ, script gửi một tin nhắn JSON chứa
# 	deviceID, chipID, và requestType: "CHECK_INFO" tới topic server/request trên server_ftp_ip.
# 8. Chờ phản hồi từ Server (về xác thực và danh sách firmware):
# 	Lắng nghe phản hồi từ server trên topic server/response qua mqtt_server_ip.
# 	Phân tích cú pháp JSON từ phản hồi để lấy validationResult và suitableFirmware.
# 9. Kiểm tra kết quả xác thực từ Server:
# 	Nếu validationResult không phải là "VALID", in thông báo lỗi, 
# 	gửi thông báo lỗi "Device validation failed" cho ESP32 qua MQTT và thoát.
# 	Nếu thiết bị được xác thực thành công, gửi thông báo "Device validated successfully" 
# 	và danh sách firmware phù hợp (suitableFirmware) cho ESP32.
# 10. Kiểm tra file binary trong thư mục FTP cục bộ của Gateway:
# 	Kiểm tra xem có bất kỳ file .bin nào trong thư mục ~/FTP_Site/ hay không.
# 	Nếu có, thông báo "Contain binary file for update in gateway" và "Continue searching for new update".
# 	Nếu không, thông báo "No binary found in gateway, check for firmware in server".
# 11. Kết nối FTP tới Server để kiểm tra firmware mới:
# 	Kết nối tới server_ftp_ip bằng FTP.
# 	Thực hiện lệnh ls để liệt kê các file trên server FTP và chuyển hướng output vào ~/ftp_log.txt.
# 12. So sánh log FTP để phát hiện firmware mới:
# 	Hiển thị nội dung của ~/ftp_log.txt và ~/last_ftp_log.txt.
# 	Lần đầu hoạt động: Nếu ~/last_ftp_log.txt trống, sao chép nội dung của ~/ftp_log.txt vào đó.
# 	Các lần sau:
# 		Sử dụng diff để so sánh ~/ftp_log.txt và ~/last_ftp_log.txt, lưu kết quả vào diff_check.txt.
# 		Cập nhật ~/last_ftp_log.txt bằng nội dung hiện tại của ~/ftp_log.txt.
# 		Trích xuất tên file .bin mới (nếu có) từ diff_check.txt bằng grep.
# 13. Tải firmware mới và thông báo cho ESP32:
# 	Nếu tìm thấy file .bin mới (update_file không rỗng):
# 		Tải file này từ server FTP về thư mục ~/FTP_Site cục bộ của gateway.
# 		Liệt kê các file trong ~/FTP_Site để xác nhận.
# 		Gửi thông báo "Info: Target firmware is $update_file" và
# 		"Return: Allow to connect and download firmware" cho ESP32 qua MQTT.
# 		Thoát script với mã 0 (thành công).
# 	Nếu không tìm thấy file cập nhật mới:
# 		Gửi thông báo lỗi "Error: No new file update found" cho ESP32 qua MQTT.
# 14. Kết thúc script:
# 	Nếu không có yêu cầu cập nhật nào được tìm thấy từ ESP32 ngay từ đầu, in "No update request found!".

# Hoạt động của script:

mqtt_server_ip=$1
username=$2
password=$3

# Start of the script
echo "Server_script.sh is on running!"

# Get MQTT server IP from argument
echo "MQTT server address is $mqtt_server_ip"

# Check and create device list and firmware folder of each device if not exist
echo "Logging for device check"
if [ ! -f "~/device_list.txt" ]; then
	touch ~/device_list.txt
fi

# at this space, add waiting for request of firmware list from gateway
echo "Waiting for firmware list request from gateway..."

request_list_message=$(mosquitto_sub -h $mqtt_server_ip -p 1883 -u $username -P $password -C 1 -t server/request)

echo "Received message from gateway: $request_list_message"
# Parse JSON message
echo "$request_list_message" | jq '.'
request=$(echo "$request_list_message" | jq '.request')

# Check request type
if [ "$request" != "\"getFirmwareList\"" ]; then
    echo "Invalid request type received from gateway."
    mosquitto_pub \
        -h $mqtt_server_ip \
        -p 1883 \
        -u $username \
        -P $password \
        -t server/response \
        -m "{\"response\": \"INVALID_LIST_REQUEST\"}" \
        -r
    # Suitable firmware list is empty in this case
    exit 1
else 
    # prepare firmware list for the device
    # Firmware list should be in the folder ~/*_firmware
    # At this stage, no deviceID info is available
    # so that the firmware list is prepared for all device in the folder
    # This mean that the firmwarelist contain each deviceID associated with its firmware list 
    # and the date of that firmware is also included
    # this mean the list must include deviceid, firmware name, firmware date
    all_firmware_list="{"
    for dir in ~/*_firmware/; do
    device_id=$(basename "$dir" | sed 's/_firmware//')
    firmware_files=$(ls "$dir"/*.bin 2>/dev/null | xargs -n1 basename)
    if [ -n "$firmware_files" ]; then
        firmware_array="["
        for file in $firmware_files; do
        full_path="$dir/$file"
        # Lấy ngày mtime của file (YYYY-MM-DD)
        fw_date=$(stat -c %y "$full_path" | cut -d ' ' -f1)
        firmware_array+="{\"name\":\"$file\",\"date\":\"$fw_date\"},"
        done
        firmware_array=${firmware_array%,}]  # bỏ dấu phẩy cuối và đóng mảng
        all_firmware_list+="\"$device_id\": $firmware_array,"
    fi
    done
    all_firmware_list=${all_firmware_list%,}}  # bỏ dấu phẩy cuối và đóng object
    all_firmware_list+="}"

    # the firmware list shoule be laike
    # {
    #   "deviceID1": [ {"name": "firmware1.bin", "date": "2024-01-01"}, {"name": "firmware2.bin", "date": "2024-02-01"} ],
    #   "deviceID2": [ {"name": "firmwareA.bin", "date": "2024-03-01"} ]
    # }

    # Send firmware list to gateway
    mosquitto_pub \
        -h $mqtt_server_ip \
        -p 1883 \
        -u $username \
        -P $password \
        -t server/response \
        -m "{\"validationResult\": \"VALID\",\"suitableFirmware\": $all_firmware_list}" \
        -r
fi

sleep 10 # sleep for 10 seconds to wait for next operation

./clean.sh # call clean.sh to clean previous operation data

# Wait for validation request from gateway
echo "Waiting for validation request from gateway..."
return_message=$(mosquitto_sub -h $mqtt_server_ip -p 1883 -u $username -P $password -C 1 -t server/request)

echo "Received message from gateway: $return_message"

# Parse JSON message
deviceID=$(echo "$return_message" | jq '.deviceId')
chipID=$(echo "$return_message" | jq '.chipId')
requestType=$(echo "$return_message" | jq '.requestType')

# the info server response include validation result and suitable firmware list, in json format should be like:
# {
#   "validationResult": "VALID" / "INVALID",
#   "suitableFirmware": [ "firmware_v1.bin", "firmware_v2.bin", ... ]
# }	

# from this space onward, remove sending the firmware list in the packet
# the firmware list will be set to request by the gateway at the start of the operation

# Check request type
if [ "$requestType" != "\"CHECK_INFO\"" ]; then
    echo "Invalid request type received from gateway."
    mosquitto_pub \
        -h $mqtt_server_ip \
        -p 1883 \
        -u $username \
        -P $password \
        -t server/response \
        -m "{\"validationResult\": \"INVALID\"}" \
        -r
    # Suitable firmware list is empty in this case
    exit 1
fi

# check deviceID in device_list.txt
if grep -q "$deviceID" ~/device_list.txt; then
    validationResult="VALID"
else
    # Device not found in device list will be marked as INVALID and no suitable firmware
    validationResult="INVALID"
fi

# At this stage, the device is validated
# Therefore proceed to send suitable firmware list to ESP32
echo "Device validated done"
# For simplicity, assume all device are listed in device_list.txt are valid
# The case of new device not in the list is not considered here

# Respond back to gateway with validation result and suitable firmware list
mosquitto_pub \
    -h $mqtt_server_ip \
    -p 1883 \
    -u $username \
    -P $password \
    -t server/response \
    -m "{\"validationResult\": \"$validationResult\",\"lastRequestDate\": \"$(date +"%Y-%m-%d")\"}" \
    -r

# after sending the validation result to gateway
# add current date to device_list.txt if device doesn't exist OR update its date if it exists
deviceID_clean=$(echo "$deviceID" | tr -d '"')
current_date=$(date +"%Y-%m-%d")

if grep -q "^$deviceID_clean" ~/device_list.txt; then
    # Nếu thiết bị đã tồn tại (có thể chưa có ngày hoặc ngày cũ), cập nhật lại dòng mới kèm ngày hiện tại
    sed -i "s/^$deviceID_clean.*/$deviceID_clean - $current_date/" ~/device_list.txt
    echo "Updated date for existing device: $deviceID_clean"
else
    # Nếu thiết bị chưa tồn tại, thêm mới hoàn toàn
    echo "$deviceID_clean - $current_date" >> ~/device_list.txt
    echo "Added new device with date: $deviceID_clean"
fi
# At this stage, if receive firmware registration request from gateway,
# add checking the firmware and the gateway to accept the registration
# this part add and waiting and checking/sending request to gateway

# may be at this stage, the server_script.sh can end its operation

# Look at the operation of gateway_script.sh
# The operation engaged with server_script.sh ends here
# therefore exit 0
exit 0
