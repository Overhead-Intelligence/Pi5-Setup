#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# OI CM4 Setup Script
# Script to install dependencies and configure Raspberry Pi CM4

USER_DIR="/home/droneman"
SYSTEM_SERVICES="${USER_DIR}/oi-pi5-toolkit/system-services"

echo "Starting system setup for CM4..."

# Ensure timezone is UTC
sudo timedatectl set-timezone UTC

# Update the package list and upgrade existing packages (only once)
sudo apt-get update && sudo apt-get upgrade -y

CORE_PKGS=(git meson ninja-build pkg-config gcc g++ python3-pip)

echo "Installing Mavlink-Router dependencies..."
for program in "${CORE_PKGS[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$program" 2>/dev/null | grep -q "install ok installed"; then
        echo "Installing $program..."
        sudo apt-get install -y "$program"
    else
        echo "$program is already installed. Skipping..."
    fi

    # Update python3-pip
    if [[ "$program" == "python3-pip" ]]; then
        echo "Configuring python3-pip..."

        # Python setup
        echo "Checking for Python external management removal..."
        if [ -f /usr/lib/python3.11/EXTERNALLY-MANAGED ]; then
            echo "Removing requirement for Python virtual environment..."
            sudo mv /usr/lib/python3.11/EXTERNALLY-MANAGED /usr/lib/python3.11/EXTERNALLY-MANAGED.old
        else
            echo "Python external management already disabled. Skipping..."
        fi

        pip3 install --upgrade pip
    fi
done

# Install mavlink interfacing dependencies
sudo pip3 install pymavlink pyserial

cd "$USER_DIR"

# Mavlink router setup
if [ -d "$USER_DIR/mavlink-router" ]; then
    echo "Mavlink-router repository already exists. Skipping..."
else
    git clone https://github.com/intel/mavlink-router.git
    cd "$USER_DIR/mavlink-router"
    git submodule update --init --recursive
    sudo meson setup build .
    sudo ninja -C build install
    sudo systemctl enable mavlink-router.service
fi

cd "$USER_DIR"

# Modify /boot/firmware/config.txt to enable UARTs and disable Bluetooth and Wi-Fi
echo "Configuring /boot/firmware/config.txt..."

cfg="/boot/firmware/config.txt"
for overlay in uart0 uart2 uart3 uart5 disable-bt disable-wifi; do
  if ! grep -q "^dtoverlay=${overlay}$" "$cfg"; then
    echo "dtoverlay=${overlay}" | sudo tee -a "$cfg"
  else
    echo "dtoverlay=${overlay} already set. Skipping..."
  fi
done

# Mavlink router config file
if [ -d "/etc/mavlink-router" ]; then
    echo "Mavlink-router config already exists. Skipping..."
else
    sudo mkdir /etc/mavlink-router
    sudo bash -c "cat > /etc/mavlink-router/main.conf <<EOF
[General]
# debug options are 'error, warning, info, debug'
DebugLogLevel = debug
TcpServerPort = 5760
[UartEndpoint flightcontroller]
# For CM4, change ttyS1 to ttyAMA2
Device = /dev/ttyAMA0
Baud = 115200
[UdpEndpoint doodle]
Mode = Server
Address = 0.0.0.0
Port = 10001
RetryTimeout = 5
[UdpEndpoint lte]
Mode = Server
Address = 0.0.0.0
Port = 10002
RetryTimeout = 5
[UdpEndpoint MAVROS]
Mode = Server
Address = 0.0.0.0
Port = 10003
RetryTimeout = 5
[UdpEndpoint MagCompForwarder]
Mode = Normal
Address = 0.0.0.0
Port = 10004
RetryTimeout = 5
[UdpEndpoint PhotoGram]
Mode = Normal
Address = 0.0.0.0
Port = 10005
RetryTimeout = 5
[UdpEndpoint MAVLinkReader]
Mode = Normal
Address = 0.0.0.0
Port = 10006
RetryTimeout = 5
[UdpEndpoint Internal7]
Mode = Normal
Address = 0.0.0.0
Port = 10007
RetryTimeout = 5
[UdpEndpoint Internal8]
Mode = Normal
Address = 0.0.0.0
Port = 10008
RetryTimeout = 5
[UdpEndpoint Internal9]
Mode = Normal
Address = 0.0.0.0
Port = 10009
RetryTimeout = 5
[UdpEndpoint Internal10]
Mode = Normal
Address = 0.0.0.0
Port = 10010
RetryTimeout = 5
[UdpEndpoint External0]
Mode = Server
Address = 0.0.0.0
Port = 11000
RetryTimeout = 5
[UdpEndpoint External1]
Mode = Server
Address = 0.0.0.0
Port = 11001
RetryTimeout = 5
[UdpEndpoint External2]
Mode = Server
Address = 0.0.0.0
Port = 11002
RetryTimeout = 5
[UdpEndpoint External3]
Mode = Server
Address = 0.0.0.0
Port = 11003
RetryTimeout = 5
[UdpEndpoint External4]
Mode = Server
Address = 0.0.0.0
Port = 11004
RetryTimeout = 5
[UdpEndpoint External5]
Mode = Server
Address = 0.0.0.0
Port = 11005
RetryTimeout = 5
[UdpEndpoint External6]
Mode = Server
Address = 0.0.0.0
Port = 11006
RetryTimeout = 5
[UdpEndpoint External7]
Mode = Server
Address = 0.0.0.0
Port = 11007
RetryTimeout = 5
[UdpEndpoint External8]
Mode = Server
Address = 0.0.0.0
Port = 11008
RetryTimeout = 5
[UdpEndpoint External9]
Mode = Server
Address = 0.0.0.0
Port = 11009
RetryTimeout = 5
[UdpEndpoint External10]
Mode = Server
Address = 0.0.0.0
Port = 11010
RetryTimeout = 5
[UdpEndpoint Support]
Mode = Server
Address = 0.0.0.0
Port = 10020
RetryTimeout = 5
[UdpEndpoint Support1]
Mode = Server
Address = 0.0.0.0
Port = 10021
RetryTimeout = 5
EOF"
fi

echo "Adding droneman user to tty group"
sudo usermod -aG tty droneman

cd "$USER_DIR"

echo "[INFO] Installing GStreamer and Python dependencies..."
sudo apt-get install -y \
  python3-gi python3-gi-cairo gir1.2-gst-rtsp-server-1.0 \
  gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly gstreamer1.0-libav \
  gstreamer1.0-rtsp python3-pip

echo "[INFO] Creating RTSP script directory..."
mkdir -p /home/droneman/gst-rtsp-server
cd /home/droneman/gst-rtsp-server

echo "[INFO] Writing stream.py..."
cat << 'EOF' > /home/droneman/gst-rtsp-server/stream.py
#!/usr/bin/env python3

import gi
gi.require_version('Gst', '1.0')
gi.require_version('GstRtspServer', '1.0')
from gi.repository import Gst, GstRtspServer, GLib

Gst.init(None)

class RTSPServer:
    def __init__(self):
        self.server = GstRtspServer.RTSPServer()
        self.server.set_service("30000")

        factory = GstRtspServer.RTSPMediaFactory()
        factory.set_shared(True)

        resolution = (1280, 720)
        framerate = 30
        device = "/dev/video0"

        if Gst.ElementFactory.find("v4l2h264enc"):
            print("[INFO] Using hardware encoder (v4l2h264enc)")
            encoder = 'v4l2h264enc extra-controls="controls,video_bitrate=1000000"'
        else:
            print("[INFO] Using software encoder (x264enc)")
            encoder = "x264enc tune=zerolatency bitrate=1000 speed-preset=ultrafast"

        pipeline = (
            f"( v4l2src device={device} ! image/jpeg,width={resolution[0]},height={resolution[1]},framerate={framerate}/1 ! "
            f"jpegdec ! videoconvert ! {encoder} ! h264parse ! rtph264pay config-interval=1 name=pay0 pt=96 )"
        )

        factory.set_launch(pipeline)
        self.server.get_mount_points().add_factory("/test", factory)
        self.server.attach(None)

    def run(self):
        print("Stream ready at rtsp://<raspberry_pi_ip>:30000/test")
        loop = GLib.MainLoop()
        loop.run()

if __name__ == '__main__':
    server = RTSPServer()
    server.run()
EOF

chmod +x /home/droneman/gst-rtsp-server/stream.py
chown -R droneman:droneman /home/droneman/gst-rtsp-server

echo "[INFO] Creating systemd service..."
cat << 'EOF' | sudo tee /etc/systemd/system/rtsp-stream.service > /dev/null
[Unit]
Description=RTSP Streamer Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /home/droneman/gst-rtsp-server/stream.py
WorkingDirectory=/home/droneman/gst-rtsp-server
Restart=always
User=droneman
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[INFO] Enabling and starting service..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable rtsp-stream.service
sudo systemctl start rtsp-stream.service

echo "[DONE] RTSP Streamer is live! Connect to rtsp://<raspberry_pi_ip>:30000/test"

cd "$USER_DIR"

echo "[*] Stopping ModemManager and updating packages..."
sudo systemctl stop ModemManager.service

echo "[*] Installing LTE modem tools..."
sudo apt-get install -y libqmi-utils udhcpc minicom iptables

echo "[*] Creating LTE directory..."
mkdir -p /home/droneman/LTE

echo "[*] Creating wwan0-setup.sh..."
cat << 'EOF' | sudo tee /home/droneman/LTE/wwan0-setup.sh > /dev/null
set -e

echo "[*] Bringing down wwan0 interface..."
sudo ip link set wwan0 down

echo "[*] Setting raw_ip mode..."
echo 'Y' | sudo tee /sys/class/net/wwan0/qmi/raw_ip

echo "[*] Bringing up wwan0..."
sudo ip link set wwan0 up

echo "[*] Setting modem to online mode..."
sudo qmicli -d /dev/cdc-wdm0 --dms-set-operating-mode='online'

echo "[*] Starting network with APN..."
sudo qmicli -p -d /dev/cdc-wdm0 \
    --device-open-net='net-raw-ip|net-no-qos-header' \
    --wds-start-network="apn='vzwinternet',ip-type=4" \
    --client-no-release-cid

echo "[*] Requesting IP address with udhcpc..."
sudo udhcpc -q -f -i wwan0

echo "[*] Applying TTL rule for Verizon..."
sudo iptables -t mangle -A PREROUTING -j TTL --ttl-set 65
EOF

echo "[*] Setting executable permission on wwan0-setup.sh..."
chmod +x /home/droneman/LTE/wwan0-setup.sh

echo "[*] Creating systemd service: wwan0-setup.service..."
cat << EOF | sudo tee /etc/systemd/system/wwan0-setup.service > /dev/null
[Unit]
Description=Setup LTE connection on wwan0
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 30
ExecStart=/bin/bash /home/droneman/LTE/wwan0-setup.sh

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Enabling wwan0-setup.service..."
sudo systemctl daemon-reload
sudo systemctl enable wwan0-setup.service

echo "[*] Installing ZeroTier..."
curl -s https://install.zerotier.com | sudo bash -

echo "[✓] LTE setup complete."

echo "Setup complete. A reboot is required to apply all changes."
read -rp "Do you want to reboot now? [y/N]: " reboot_choice
if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
  sudo reboot
else
  echo "Reboot skipped. Please reboot manually before using the system."
fi
