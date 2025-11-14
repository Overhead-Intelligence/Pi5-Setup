#!/bin/bash

# home directory
USER_DIR="/home/droneman"

# exit script if an error occurs
set -e

# Script to install dependencies and configure Raspberry Pi CM4
echo "Starting system setup for Pi Zero..."

# ensure timezone is UTC
sudo timedatectl set-timezone UTC

# Update the package list and upgrade existing packages
sudo apt update && sudo apt upgrade -y 

# programs to install
PROGRAMS=(
    "git"
    "meson"
    "ninja-build"
    "pkg-config"
    "gcc"
    "g++"
    "systemd"
    "python3-pip"
    "cmake"
    "libsystemd-dev"
    "libimobiledevice-utils"
    "ipheth-utils"
    "usbmuxd"
)

echo "Installing Mavlink-Router dependencies..."
for program in "${PROGRAMS[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$program" 2>/dev/null | grep -q "install ok installed"; then
        echo "Installing $program..."
        sudo apt-get install -y $program
    else
        echo "$program is already installed. Skipping..."
    fi

    # update python3-pip
    if [[ "$program" == "python3-pip" ]]; then
        echo "Configuring python3-pip..."
        
        # python setup
        echo "Checking for Python external management removal..."
        if [ -f /usr/lib/python3.13/EXTERNALLY-MANAGED.old ]; then
            echo "Python external management already disabled. Skipping..."
        else
            echo "Removing requirement for Python virtual environment..."
            sudo mv /usr/lib/python3.13/EXTERNALLY-MANAGED /usr/lib/python3.13/EXTERNALLY-MANAGED.old
        fi

        pip3 install --upgrade pip
    fi
done


# make sure we are in the correct directory
cd "$USER_DIR"

# mavlink router setup
if [ -d "$USER_DIR/mavlink-router" ]; then
    echo "Mavlink-router repository already exists. Skipping..."
else
    git clone https://github.com/mavlink-router/mavlink-router.git
    cd "$USER_DIR/mavlink-router"
    git submodule update --init --recursive
    meson setup build . -Dsystemdsystemunitdir=/lib/systemd/system
    ninja -C build -j1
    sudo ninja -C build install
    sudo systemctl enable mavlink-router.service
fi

cd "$USER_DIR"

# Modify /boot/firmware/config.txt to enable UARTs and disable Bluetooth
echo "Configuring /boot/firmware/config.txt..."

# Check if the lines already exist before adding them
CONFIG_FILE="/boot/firmware/config.txt"
if ! grep -q "dtoverlay=uart0" "$CONFIG_FILE"; then
    echo "dtoverlay=uart0" | sudo tee -a $CONFIG_FILE
    echo "dtoverlay=disable-bt" | sudo tee -a $CONFIG_FILE
else
    echo "UART and Bluetooth configurations already present in $CONFIG_FILE"
fi

#mavlink router config file
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
[UdpEndpoint Internal4]
Mode = Normal
Address = 0.0.0.0
Port = 10004
RetryTimeout = 5
[UdpEndpoint Internal5]
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
[UdpEndpoint Intenal8]
Mode = Normal
Address = 0.0.0.0
Port = 10008
RetryTimeout = 5
[UdpEndpoint Intenal9]
Mode = Normal
Address = 0.0.0.0
Port = 10009
RetryTimeout = 5
[UdpEndpoint Intenal10]
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

curl -fsSL https://tailscale.com/install.sh | sudo bash
log_success "Tailscale installed! Run 'sudo tailscale up' to authenticate."


log_info "Installing ZeroTier..."
curl -s https://install.zerotier.com | sudo bash

# Reboot to apply changes
echo "Setup complete. Please reboot to apply changes..."
