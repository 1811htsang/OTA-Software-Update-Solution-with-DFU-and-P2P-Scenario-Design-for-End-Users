#!/bin/bash

# --- CẤU HÌNH BIẾN ---
WLAN_IFACE="wlp1s0"      # Card Wifi phát mạng
ETH_IFACE="wlp3s0f4u2u2"         # Card Ethernet nhận internet
SSID="TM420IA"
WPA_PASS="23521341"
IP_ADDR="192.168.0.1"
NETMASK="255.255.255.0"
DHCP_RANGE="192.168.0.50,192.168.0.150"

# Đường dẫn file tạm
HOSTAPD_CONF="./hostapd_temp.conf"
DNSMASQ_CONF="./dnsmasq_temp.conf"

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
   echo "Script này phải được chạy với quyền sudo!"
   exit 1
fi

# --- HÀM KHÔI PHỤC (REVERT) ---
function cleanup {
    echo -e "\n\n[!] Đang dừng AP và khôi phục cài đặt hệ thống..."
    
    # Dừng các tiến trình
    pkill hostapd
    pkill dnsmasq
    
    # Khôi phục IP và NetworkManager
    ip addr flush dev $WLAN_IFACE
    nmcli device set $WLAN_IFACE managed yes
    systemctl restart NetworkManager
    
    # Khôi phục systemd-resolved
    systemctl unmask systemd-resolved
    systemctl start systemd-resolved
    
    # Khôi phục Firewalld nếu có
    systemctl start firewalld 2>/dev/null
    
    # Xóa file cấu hình tạm
    rm -f $HOSTAPD_CONF $DNSMASQ_CONF
    
    echo "[+] Đã khôi phục trạng thái ban đầu. Hẹn gặp lại!"
    exit
}

# Bắt sự kiện nhấn CTRL+C
trap cleanup SIGINT

# --- BẮT ĐẦU CẤU HÌNH ---
echo "[0/6] CLear dữ liệu cũ ..."
pkill hostapd
pkill dnsmasq
sudo rm /var/lib/dnsmasq/dnsmasq.leases

echo "[1/6] Chuẩn bị giao diện mạng..."
nmcli device set $WLAN_IFACE managed no
systemctl stop firewalld 2>/dev/null  # Tắt firewalld để tránh xung đột
systemctl mask systemd-resolved
systemctl stop systemd-resolved

echo "[2/6] Thiết lập địa chỉ IP tĩnh cho $WLAN_IFACE..."
ip link set $WLAN_IFACE up
ip addr flush dev $WLAN_IFACE
ip addr add $IP_ADDR/24 dev $WLAN_IFACE

echo "[3/6] Tạo file cấu hình tạm thời..."
# Tạo hostapd.conf
cat <<EOF > $HOSTAPD_CONF
interface=$WLAN_IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$WPA_PASS
EOF

# Tạo dnsmasq.conf
cat <<EOF > $DNSMASQ_CONF
interface=$WLAN_IFACE
bind-interfaces
dhcp-sequential-ip
no-ping
dhcp-authoritative
dhcp-ignore-clid
dhcp-ignore-names
dhcp-range=$DHCP_RANGE,12h
dhcp-option=option:router,$IP_ADDR
dhcp-option=option:dns-server,8.8.8.8,1.1.1.1
log-queries
log-dhcp
EOF

echo "[4/6] Kích hoạt IP Forwarding và NAT (Internet Sharing)..."
sudo sysctl -w net.ipv4.ip_forward=1


echo "[5/6] Khởi chạy dịch vụ..."
hostapd $HOSTAPD_CONF > /dev/null 2>&1 &
dnsmasq -C $DNSMASQ_CONF -d &

echo "------------------------------------------------------------"
echo "  WIFI ACCESS POINT ĐANG HOẠT ĐỘNG"
echo "  SSID: $SSID"
echo "  Password: $WPA_PASS"
echo "  IP Gate: $IP_ADDR"
echo "  Danh sách thiết bị kết nối sẽ hiện bên dưới (Dnsmasq log):"
echo "  NHẤN CTRL+C ĐỂ DỪNG VÀ KHÔI PHỤC HỆ THỐNG"
echo "------------------------------------------------------------"

# Giữ script chạy để theo dõi log dnsmasq
tail -f /var/lib/dnsmasq/dnsmasq.leases &
wait
