#! /bin/bash

# ======================================================================================================================
# LUỒNG HOẠT ĐỘNG CỦA GATEWAY SCRIPT (OTA SOFTWARE UPDATE)
# 1. KHỞI TẠO: Nhận tham số (MQTT IP, FTP IP, User/Pass), cấu hình auto-login FTP vào ~/.netrc và kiểm tra kết nối Server.
# 2. CHUẨN BỊ LOG: Kiểm tra và tạo các file lưu trữ cục bộ: device_list.txt, firmware_list.txt, ftp_log.txt...
# 3. ĐỒNG BỘ FIRMWARE: Gửi yêu cầu "getFirmwareList" tới Server qua MQTT và lưu danh sách firmware nhận được vào file local.
# 4. NHẬN YÊU CẦU TỪ ESP32: Chờ đăng ký (mosquitto_sub) lệnh "UPDATE_REQUEST" từ ESP32 trên topic nckhsv/+/request.
# 5. XÁC THỰC THIẾT BỊ: Trích xuất deviceId/chipId, gửi tới Server để kiểm tra tính hợp lệ và lấy ngày yêu cầu cuối.
# 6. LỌC FIRMWARE PHÙ HỢP: Dựa trên phản hồi từ Server, dùng jq để lọc danh sách các firmware mới hơn ngày yêu cầu cuối.
# 7. GỬI DANH SÁCH CHO ESP32: Gửi gói tin "FW_LIST_RETR" chứa mảng firmware và chuyển sang trạng thái chờ "GW_WAIT".
# 8. XỬ LÝ LỰA CHỌN: Chờ ESP32 gửi lệnh "SELECTION_REQUEST" chứa tên file firmware cụ thể (requestFile).
# 9. KIỂM TRA & TẢI BINARY:
#    - Nếu Gateway đã có sẵn file trong folder local (~/ID_firmware/): Thông báo "UPDATE_AVAILABLE" ngay lập tức.
#    - Nếu chưa có: Kết nối FTP tới Server, tìm file trong folder quản lý của device, tải về Gateway và đăng ký log.
# 10. HOÀN TẤT: Thông báo "UPDATE_AVAILABLE" cho ESP32 kèm tên file đích và kết thúc tiến trình thành công (exit 0).
# ======================================================================================================================

# Cấu hình các biến môi trường và tham số đầu vào
mqtt_server_ip=$1
server_ftp_ip=$2
username=$3
password=$4
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
END='\033[0m'

# Bắt đầu thực thi Script
echo -e "${RED}Banner: Gateway_script.sh is on running!${END}"

# Lấy địa chỉ IP của MQTT Server từ đối số (Argument) thứ nhất
echo -e "${GREEN}Info: MQTT server address is $mqtt_server_ip ${END}"

# Lấy địa chỉ IP của FTP Server từ đối số thứ hai
echo -e "${GREEN}Info: FTP server address is $server_ftp_ip ${END}"

# Cấu hình trước file .netrc để tự động đăng nhập FTP mà không cần nhập thủ công
echo -e "${GREEN}Info: Pre-configuration for auto username and password in ~/.netrc${END}"
echo "machine $server_ftp_ip login shanghuang password 181105" > ~/.netrc
chmod 600 ~/.netrc
echo -e "${GREEN}      done${END}"

# Kiểm tra kết nối tới Server bằng lệnh ping (gửi 5 gói tin)
echo -e "${GREEN}Info: Ping server for checking connection${END}"
if ping -c 5 $server_ftp_ip &> /dev/null; then
	echo -e "${GREEN}Info: Server connection is available${END}"
else
	echo -e "${RED}Error: Server connection is unavailable! Gateway turn off script${END}"
	echo -e "${RED}Action: Abort program script${END}"
	exit 1
fi
echo -e "${GREEN}      done${END}"

# Kiểm tra và tạo file danh sách thiết bị (device_list.txt) nếu chưa tồn tại
echo -e "${GREEN}Info: Logging for device check${END}"
if [ ! -f ~/device_list.txt ]; then
	touch ~/device_list.txt
fi
echo -e "${GREEN}      done${END}"

# Kiểm tra và khởi tạo file log FTP (ftp_log.txt), làm trống file mỗi lần chạy lại
echo -e "${GREEN}Info: Logging for ftp configuration${END}"
if [ ! -f ~/ftp_log.txt ]; then
	touch ~/ftp_log.txt
fi
echo > ~/ftp_log.txt
echo -e "${GREEN}      done${END}"

# Kiểm tra và tạo file chứa danh sách firmware thô từ Server (firmware_list.txt)
echo -e "${GREEN}Info: Logging for firmware list preparation${END}"
if [ ! -f ~/firmware_list.txt ]; then
	touch ~/firmware_list.txt
fi
echo -e "${GREEN}      done${END}"

# Kiểm tra và tạo file lưu thông tin các firmware đã được đăng ký/tải về (registered_firmware_list.txt)
echo -e "${GREEN}Info: Logging for registered firmware list${END}"
if [ ! -f ~/registered_firmware_list.txt ]; then
	touch ~/registered_firmware_list.txt
fi
echo -e "${GREEN}      done${END}"

# Gửi yêu cầu lấy toàn bộ danh sách Firmware hiện có từ Server thông qua MQTT topic "server/request"
echo -e "${GREEN}Info: Send request to get firmware list from server${END}"
mosquitto_pub \
	-h $mqtt_server_ip \
	-p 1883 \
	-u $username \
	-P $password \
	-t server/request \
	-m "{\"from\":\"gateway\", \"request\":\"getFirmwareList\"}" \
	-r
echo -e "${GREEN}      done${END}"

# Chờ đợi và nhận phản hồi (1 gói tin) chứa danh sách firmware từ Server
echo -e "${GREEN}Info: Waiting for firmware list response from server${END}"
firmwarelist_response_message=$(mosquitto_sub -h $mqtt_server_ip -p 1883 -u $username -P $password -C 1 -t server/response )
echo -e "${GREEN}      done${END}"

# Cấu trúc dữ liệu firmware nhận được dự kiến có dạng JSON Object:
# {
#   "deviceID_1": [ "firmware_v1.bin", "firmware_v2.bin", ... ],
#   "deviceID_2": [ "firmware_v1.bin", "firmware_v2.bin", ... ],
#   ...
# }
# Xử lý thông tin nhận được bằng công cụ jq
echo -e "${YELLOW}Receive: Firmware list response message - $firmwarelist_response_message${END}"
echo "$firmwarelist_response_message" | jq '.'
firmwareList=$(echo "$firmwarelist_response_message" | jq '.firmwareList')

# Kiểm tra nếu danh sách firmware bị rỗng hoặc lỗi, dừng script ngay lập tức
if [ -z "$firmwareList" ] || [ "$firmwareList" = "null" ]; then
	echo -e "${RED}Error: Blank firmware list from server${END}"
	echo -e "${RED}Action: Abort program script${END}"
	exit 1
fi

## Lưu nội dung danh sách firmware vào file cục bộ để xử lý sau này
echo -e "${GREEN}Info: Saving firmware list to local file${END}"
echo "$firmwareList" > ~/firmware_list.txt
echo -e "${GREEN}      done${END}"

# Chờ đợi yêu cầu cập nhật (UPDATE_REQUEST) từ ESP32 gửi lên topic mặc định
echo -e "${GREEN}Info: Waiting for update request from ESP32${END}"
request_message=$(mosquitto_sub -h $mqtt_server_ip -p 1883 -u $username -P $password -C 1 -t nckhsv/+/request )
echo -e "${GREEN}      done${END}"

# Trích xuất các trường thông tin cần thiết từ bản tin JSON của ESP32 (DeviceId, ChipId, RequestType)
echo -e "${YELLOW}Receive: Request message - $request_message${END}"
echo "$request_message" | jq '.'
deviceID=$(echo "$request_message" | jq '.deviceId')
deviceID_clean=$(echo "$deviceID" | tr -d '"')
chipID=$(echo "$request_message" | jq '.chipId')
requestType=$(echo "$request_message" | jq '.requestType')

# Kiểm tra tính toàn vẹn của bản tin: Nếu thiếu bất kỳ trường nào, phản hồi lỗi BAD_REQUEST cho ESP32
# -z dùng để kiểm tra chuỗi rỗng
if [ -z "$deviceID" ] || [ -z "$chipID" ] || [ -z "$requestType" ]; then
	echo -e "${RED}Error: Invalid request${END}"
	echo -e "${RED}Action: BAD_REQUEST response, abort program script${END}"
	# Gửi thông báo lỗi về topic đích của riêng ESP32 đó
	mosquitto_pub \ 
		-h $mqtt_server_ip \ 
		-p 1883 \ 
		-u $username \
		-P $password \
		-t nckhsv/$deviceID_clean/response \
		-m "{\"status\":\"BAD_REQUEST\", \"message\":\"Blank request found\"}" \
		-r
	exit 1
fi

# Kiểm tra giá trị của requestType: Chỉ chấp nhận "UPDATE_REQUEST" để bắt đầu quy trình
if [ "$requestType" != "\"UPDATE_REQUEST\"" ]; then
	echo -e "${RED}Error: Invalid requestType value${END}"
	echo -e "${RED}Action: BAD_REQUEST response, abort program script${END}"
	# Phản hồi lỗi nếu ESP32 gửi yêu cầu không đúng định dạng quy định
	mosquitto_pub \
		-h $mqtt_server_ip \
		-p 1883 \
		-u $username \
		-P $password \
		-t nckhsv/$deviceID_clean/response \
		-m "{\"status\":\"BAD_REQUEST\", \"message\":\"Invalid requestType\"}" \
		-r
	exit 1
fi

sleep 5

# Ở giai đoạn này, Gateway cần gửi thông tin lên Server để xác thực (Validation) thiết bị
# Server sẽ phản hồi trạng thái hợp lệ và cung cấp ngày yêu cầu cuối cùng (lastRequestDate)
# Dựa vào đó Gateway sẽ lọc ra các file firmware "mới" phù hợp cho thiết bị

# Gửi thông tin (deviceID, chipID) qua Server để kiểm tra lịch sử và tính chính danh
echo -e "${GREEN}Info: Sending device info to server for validation and checking suitable firmware${END}"

mosquitto_pub \
	-h $mqtt_server_ip \
	-p 1883 \
	-u $username \
	-P $password \
	-t server/request \
	-m "{\"deviceId\": $deviceID, \"chipId\": $chipID, \"requestType\": \"CHECK_INFO\" }" \
	-r

# Chờ đợi Server xử lý và trả về kết quả xác thực
echo -e "${GREEN}Info: Waiting for server response for device validation and suitable firmware check${END}"
return_message=$(mosquitto_sub -h $mqtt_server_ip -p 1883 -u $username -P $password -C 1 -t server/response)

# Thông tin Server phản hồi dự kiến có dạng JSON:
# {
#   "validationResult": "VALID" / "INVALID",
#   "lastRequestDate": "YYYY-MM-DD"
# }

# Kiểm tra nếu Server phản hồi rỗng (có lỗi từ phía Server)
echo -e "${YELLOW}Receive: Server response - $return_message${END}"
echo "$return_message" | jq '.'
validationResult=$(echo "$return_message" | jq '.validationResult')
lastRequestDate=$(echo "$return_message" | jq '.lastRequestDate' | tr -d '"')

# Kiểm tra tính hợp lệ của bản tin phản hồi từ Server
if [ -z "$validationResult" ] || [ -z "$lastRequestDate" ]; 
then
	echo -e "${RED}Error: Blank response from server, suspect error from server${END}"
	echo -e "${RED}Action: BAD_REQUEST response server, UNEXPECTED_ERROR response esp32, abort program script${END}"
	# Báo lỗi ngược lại cho Server
	mosquitto_pub \
		-h $mqtt_server_ip \
		-p 1883 \
		-u $username \
		-P $password \
		-t nckhsv/$deviceID_clean/response \
		-m "{\"status\":\"BAD_REQUEST\", \"message\":\"Blank response, disconnect\"}" \
		-r

	# Thông báo lỗi hệ thống cho ESP32 để thiết bị thử lại sau
	mosquitto_pub \
		-h $mqtt_server_ip \
		-p 1883 \
		-u $username \
		-P $password \
		-t nckhsv/$deviceID_clean/response \
		-m "{\"status\":\"SERVER_UNEXPECTED_ERROR\", \"message\":\"Server cant respond to validation request, try again later\"}" \
		-r
	exit 1
fi


# Kiểm tra xem Server có chấp nhận thiết bị hay không (VALID)
if [ "$validationResult" != "\"VALID\"" ]; then
	echo -e "${RED}Error: Device validation failed${END}"
	echo -e "${RED}Action: DEV_VAL_FAILED response, abort program script${END}"
	# Từ chối quy trình cập nhật nếu Server báo thiết bị không hợp lệ
	mosquitto_pub \
		-h $mqtt_server_ip \
		-p 1883 \
		-u $username \
		-P $password \
		-t nckhsv/$deviceID_clean/response \
		-m "{\"status\":\"DEV_VAL_FAILED\", \"message\":\"Server failed to validate the device, refuse to proceed with update request\"}" \
		-r
	exit 1
fi

# Thiết bị đã được xác thực thành công. Tiếp tục quy trình lọc Firmware.
echo -e "${GREEN}Info: Device validated successfully${END}"

# Gửi tín hiệu thông báo xác thực thành công cho ESP32
mosquitto_pub \
	-h $mqtt_server_ip \
	-p 1883 \
	-u $username \
	-P $password \
	-t nckhsv/$deviceID_clean/response \
	-m "{\"status\":\"DEV_VAL_SUCCESS\",\"message\":\"Server validated device successfully\"}" \
	-r

sleep 3

# Tải danh sách firmware từ file cục bộ và tiến hành lọc:
# 1. Lấy ra các firmware thuộc về deviceID này.
# 2. Lọc bỏ các firmware cũ dựa trên lastRequestDate nhận được từ Server.
# Yêu cầu định dạng ngày trong JSON phải là "YYYY-MM-DD".
suitable_firmware_list=$(jq --arg deviceID "$deviceID_clean" --arg lastRequestDate "$lastRequestDate" '.[$deviceID] | map(select(.date >= $lastRequestDate))' ~/firmware_list.txt)

echo "$suitable_firmware_list"

# Nếu sau khi lọc không còn bản cập nhật nào mới hơn, thông báo UPDATE_UNAVAILABLE
if [ "$suitable_firmware_list" == "[]" ]; then
	echo "${GREEN}Info: No new firmware is found, response back to device${END}"
	mosquitto_pub \
		-h $mqtt_server_ip \
		-p 1883 \
		-u $username \
		-P $password \
		-t nckhsv/$deviceID_clean/response \
		-m "{\"status\":\"UPDATE_UNAVAILABLE\", \"message\":\"No new update is released at this moment\"}" \
		-r
	exit 1

fi

# Gửi danh sách các bản firmware phù hợp (FW_LIST_RETR) để người dùng/ESP32 lựa chọn
mosquitto_pub \
	-h $mqtt_server_ip \
	-p 1883 \
	-u $username \
	-P $password \
	-t nckhsv/$deviceID_clean/response \
	-m "{\"status\":\"FW_LIST_RETR\",\"firmwareList\":$suitable_firmware_list}" \
	-r

sleep 3

# Chuyển sang trạng thái chờ đợi lựa chọn từ phía người dùng thiết bị
mosquitto_pub \
	-h $mqtt_server_ip \
	-p 1883 \
	-u $username \
	-P $password \
	-t nckhsv/$deviceID_clean/response \
	-m "{\"status\":\"GW_WAIT\",\"message\":\"Gateway is waiting selection response\"}" \
	-r

# Chờ đợi ESP32 gửi lựa chọn cụ thể (SELECTION_REQUEST) qua topic riêng ".../select"
echo -e "${GREEN}Info: Waiting for selection response from ESP32${END}"
selection_message=$(mosquitto_sub -h $mqtt_server_ip -p 1883 -u $username -P $password -C 1 -t nckhsv/$deviceID_clean/select)

# Phân tích nội dung lựa chọn nhận được từ ESP32
echo -e "${YELLOW}Receive: Selection message - $selection_message ${END}"
echo "$selection_message" | jq '.'
deviceID=$(echo "$selection_message" | jq '.deviceId')
chipID=$(echo "$selection_message" | jq '.chipId') 
isValidate=$(echo "$selection_message" | jq '.isValidate')
requestType=$(echo "$selection_message" | jq '.requestType') 
requestFile=$(echo "$selection_message" | jq '.requestFile') 

# Kiểm tra dữ liệu lựa chọn: Nếu rổng hoặc thiếu trường quan trọng, báo lỗi và dừng
if [ -z "$deviceID" ] || [ -z "$chipID" ] || [ -z "$requestType" ]; then
	echo -e "${RED}Error: Invalid request${END}"
	echo -e "${RED}Action: BAD_REQUEST response, abort program script${END}"
	# Phản hồi lỗi bản tin không hợp lệ cho thiết bị
	mosquitto_pub \ 
		-h $mqtt_server_ip \ 
		-p 1883 \ 
		-u $username \
		-P $password \
		-t nckhsv/$deviceID_clean/response \
		-m "{\"status\":\"BAD_REQUEST\", \"message\":\"Blank request found\"}" \
		-r
	exit 1
fi

# Kiểm tra cờ isValidate: Thiết bị phải gửi lại trạng thái đã xác thực thành công
if [ "$isValidate" == "false" ]; then
	echo -e "Error: Device must be validated successfully by server at this stage${END}"
	echo -e "Action: Abort program script${END}"
	exit 1
fi


# Bắt đầu kiểm tra file Firmware thực tế trong kho lưu trữ của Gateway (Cục bộ)
echo -e "${GREEN}Info: Passed early validation, checking local storage for firmware file${END}"

# Nếu file binary yêu cầu đã tồn tại trong thư mục cá nhân của thiết bị tại Gateway
if ls ~/"${deviceID}_firmware"/*.bin 1> /dev/null 2>&1; then # if firmware files exist
    echo -e "${GREEN}Info: Contain firmware file for update in gateway${END}"
    # Thông báo đã tìm thấy file tại Gateway (FW_FOUND)
    mosquitto_pub \
	    -h $mqtt_server_ip \
	    -p 1883 \
	    -u $username \
	    -P $password \
	    -t nckhsv/$deviceID_clean/response \
	    -m "{\"status\":\"FW_FOUND\",\"message\":\"Found firmware inside gateway storage\"}" \
	    -r

    sleep 5
    # Cấp phép cho ESP32 bắt đầu tải (UPDATE_AVAILABLE) kèm tên file cụ thể
    mosquitto_pub \
            -h $mqtt_server_ip \
	    -p 1883 \
	    -u $username \
	    -P $password \
	    -t nckhsv/$deviceID_clean/response \
	    -m "{\"status\":\"UPDATE_AVAILABLE\", \"targetFirmware\":$requestFile}" \
	    -r
    exit 0
else
    # Trường hợp không thấy file tại Gateway: Tiến hành tìm kiếm và tải từ Server qua FTP
    echo -e "${GREEN}Info: No binary found in gateway, check for firmware in server${END}"
    # Thông báo cho thiết bị biết Gateway đang đi tìm file từ Server (FW_NOT_FOUND)
    mosquitto_pub \
	    -h $mqtt_server_ip \
	    -p 1883 \
	    -u $username \
	    -P $password \
	    -t nckhsv/$deviceID_clean/response \
	    -m "{\"status\": \"FW_NOT_FOUND\", \"message\":\"No firmware found inside gateway, continue to check inside server storage\"}" \
	    -r

    sleep 5

    # Kết nối FTP tới Server để liệt kê nội dung thư mục tương ứng của thiết bị
    echo -e "${GREEN}Info: Connecting to FTP server to check for firmware${END}"
    ftp -iv $server_ftp_ip <<EOF > ~/ftp_log.txt 
        # Lệnh ls sẽ liệt kê file trong folder device_firmware và ghi vào ftp_log.txt
        ls "${deviceID_clean}_firmware"
EOF
    # Hiển thị nội dung log FTP vừa lấy được để theo dõi
    echo -e "${GREEN}Info: ftp current log${END}"
    cat ~/ftp_log.txt
    echo -e "${GREEN}      done${END}"

	echo -e "${GREEN}Info: Checking for requested firmware in ftp_log${END}"

	# Kiểm tra xem file mà người dùng chọn (requestFile) có thực sự tồn tại trong log FTP vừa lấy không
	if [ -z "$requestFile" ] || [ "$requestFile" = "null" ]; then
		echo -e "${GREEN}Info: requestFile is empty or null, cannot check server${END}"
		mosquitto_pub \
			-h $mqtt_server_ip \
			-p 1883 \
			-u $username \
			-P $password \
			-t nckhsv/$deviceID_clean/response \
			-m "{\"status\":\"UPDATE_UNAVAILABLE\", \"message\":\"No requested file specified\"}" \
			-r
	else
		update_file="$requestFile"
		echo -e "${GREEN}Info: Requested update file found on server: $update_file ${END}"

		# Đăng ký thông tin firmware vào registered_firmware_list.txt để đánh dấu quyền tải của thiết bị
		# Lưu trữ vết: deviceID + tên file + trạng thái registered + ngày tháng hiện tại
		echo -e "${GREEN}Info: Registrate firmware with deviceID & firmware & date to download file${END}"
		echo "$deviceID_clean $update_file registered $(date +"%Y-%m-%d")" >> ~/registered_firmware_list.txt

		# Thực hiện tải file binary từ Server về thư mục cục bộ của Gateway
		echo -e "${GREEN}Info: Redirect local directory to specific device storage${END}"
		ftp -iv $server_ftp_ip <<EOF
			binary
			cd ~/"${deviceID_clean}_firmware"
			lcd ~/"${deviceID_clean}_firmware"
			get $update_file
EOF
		# Kiểm kê lại thư mục cục bộ để chắc chắn file đã về tới Gateway
		echo -e "${GREEN}Info: Checking device storage${END}"
		ls ~/"${deviceID_clean}_firmware"
		echo -e "${GREEN}              done${END}"

		echo -e "${GREEN}Info: New binary file is allowed for update in gateway${END}"
		
		# Thông báo cuối cùng cho ESP32: Bản cập nhật đã sẵn sàng để tải từ Gateway (UPDATE_AVAILABLE)
		mosquitto_pub \
			-h $mqtt_server_ip \
			-p 1883 \
			-u $username \
			-P $password \
			-t nckhsv/$deviceID_clean/response \
			-m "{\"status\":\"UPDATE_AVAILABLE\", \"targetFirmware\":$update_file}" \
			-r
		exit 0
	fi
fi



