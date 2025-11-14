#!/bin/bash
#
# Refactored Raspberry Pi 5 Setup Script (v17 - Final)
#
# Key Improvements:
# - Adds the 'isc-dhcp-client' package to the installation list, as it is
#   not installed by default on this OS, which resolves the final service error.
#

# --- Script Configuration ---
readonly USER_NAME="${SUDO_USER:-$(whoami)}"
readonly USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

# --- Main Script Logic ---
main() {
    set -euo pipefail
    if [[ $EUID -eq 0 ]]; then
        echo "❌ This script should not be run as root. Use 'bash setup.sh' without sudo."
        exit 1
    fi

    log_info "Starting setup for user '$USER_NAME' on Raspberry Pi 5..."

    configure_system
    install_system_packages
    install_python_packages
    setup_mavlink_router
    setup_rtsp_streamer
    setup_lte
    install_zerotier
    install_tailscale
    finalize_setup

    log_success "✅ Setup complete!"
    echo -e "\n\n--- IMPORTANT ---"
    echo "Python packages (pymavlink, pyserial) were installed in a virtual environment."
    echo "To use them from your terminal, you must first activate it by running:"
    echo "  source ${USER_HOME}/python_venvs/mavlink_tools/bin/activate"
    echo "-----------------"

    prompt_for_reboot
}

# --- Helper Functions ---
log_info() {
    echo -e "\n[INFO] $1"
}

log_success() {
    echo -e "\n[SUCCESS] $1"
}

# --- Setup Functions ---

## System and Boot Configuration
configure_system() {
    log_info "Configuring system settings..."
    sudo timedatectl set-timezone UTC
    sudo apt-get update && sudo apt-get upgrade -y

    local cfg_file="/boot/firmware/config.txt"

    log_info "Configuring /boot/firmware/config.txt..."

    # --- Ask whether to disable WiFi ---
    read -rp "DO YOU WANT TO DISABLE ONBOARD WIFI? (y/N): " disable_wifi_choice
    disable_wifi_choice=${disable_wifi_choice,,}  # lowercase

    if [[ "$disable_wifi_choice" == "y" ]]; then
        log_info "Disabling onboard WiFi..."

        # Add disable-wifi overlay
        if ! grep -q "^dtoverlay=disable-wifi$" "$cfg_file"; then
            echo "dtoverlay=disable-wifi" | sudo tee -a "$cfg_file" > /dev/null
        else
            echo "WiFi already disabled. Skipping overlay."
        fi

        # Immediately RF-kill WiFi in the current session
        sudo rfkill block wifi || true

    else
        log_info "Leaving WiFi enabled..."

        # Remove disable-wifi overlay if it exists
        if grep -q "^dtoverlay=disable-wifi$" "$cfg_file"; then
            sudo sed -i '/^dtoverlay=disable-wifi$/d' "$cfg_file"
            echo "Removed disable-wifi overlay."
        fi

        # Try to unblock WiFi
        log_info "Attempting to un-block WiFi (rfkill)..."
        sudo rfkill unblock wifi || true
        sudo rfkill unblock all || true

        # Try to bring up wlan0
        if sudo ip link set wlan0 up 2>/tmp/wifi_err.log; then
            log_success "WiFi interface wlan0 enabled successfully."
        else
            log_info "WiFi interface could not be brought up immediately (likely requires reboot)."
            log_info "RF-kill output:"
            rfkill list
            log_info "ip link error:"
            cat /tmp/wifi_err.log
            echo "WiFi should function correctly after reboot."
        fi
    fi

    # UART-related overlays (always applied)
    local overlays=("uart0" "uart2" "uart3" "uart5" "disable-bt")
    for overlay in "${overlays[@]}"; do
        if ! grep -q "^dtoverlay=${overlay}$" "$cfg_file"; then
            echo "dtoverlay=${overlay}" | sudo tee -a "$cfg_file" > /dev/null
        else
            echo "dtoverlay=${overlay} already set. Skipping."
        fi
    done

    log_info "Adding user '$USER_NAME' to the 'tty' group..."
    sudo usermod -aG tty "$USER_NAME"

    log_info "Disabling ModemManager to prevent conflicts..."
    if systemctl list-units --full -all | grep -q 'ModemManager.service'; then
        sudo systemctl disable --now ModemManager.service
    else
        echo "ModemManager.service not found. Skipping disable."
    fi
}


## Package Installation
install_system_packages() {
    log_info "Installing all required APT packages..."
    # --- THIS IS THE FIX ---
    # Add 'isc-dhcp-client' to ensure the dhclient executable is available.
    local apt_packages=(
        git meson ninja-build pkg-config gcc g++
        python3-pip python3-venv
        libsystemd-dev
        python3-gi python3-gi-cairo gir1.2-gst-rtsp-server-1.0
        gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good
        gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav
        gstreamer1.0-rtsp
        minicom isc-dhcp-client
        libimobiledevice-utils ipheth-utils usbmuxd
    )
    sudo apt-get update
    sudo apt-get install -y "${apt_packages[@]}"
}

## User-Specific Python Packages
install_python_packages() {
    log_info "Creating and installing Python packages into a virtual environment..."
    local venv_dir="${USER_HOME}/python_venvs/mavlink_tools"
    if [ ! -d "$venv_dir" ]; then
        mkdir -p "${USER_HOME}/python_venvs"
        sudo -u "$USER_NAME" python3 -m venv "$venv_dir"
        log_info "Created virtual environment at '$venv_dir'"
    else
        log_info "Virtual environment already exists. Skipping creation."
    fi
    log_info "Installing pymavlink and pyserial into the venv..."
    sudo -u "$USER_NAME" "${venv_dir}/bin/python3" -m pip install --upgrade pip
    sudo -u "$USER_NAME" "${venv_dir}/bin/python3" -m pip install pymavlink pyserial
}

## Mavlink Router Setup
setup_mavlink_router() {
    local install_dir="${USER_HOME}/mavlink-router"
    log_info "Setting up Mavlink-router in '$install_dir'..."

    if [ -d "$install_dir" ]; then
        log_info "Existing Mavlink-router directory found. Removing for a clean reinstall..."
        if [ -f "${install_dir}/build/build.ninja" ]; then
            (cd "$install_dir" && sudo ninja -C build uninstall || echo "Uninstall failed, but continuing with removal.")
        fi
        sudo rm -rf "$install_dir"
    fi

    log_info "Cloning and building Mavlink-router..."
    sudo -u "$USER_NAME" git clone https://github.com/intel/mavlink-router.git "$install_dir"
    cd "$install_dir"
    sudo -u "$USER_NAME" git submodule update --init --recursive

    log_info "Configuring Meson build..."
    meson setup build . -Dsystemdsystemunitdir=/usr/lib/systemd/system

    ninja -C build
    sudo ninja -C build install
    sudo ldconfig

    if [ ! -f "/etc/mavlink-router/main.conf" ]; then
        log_info "Creating mavlink-router configuration..."
        sudo mkdir -p /etc/mavlink-router
        cat << 'EOF' | sudo tee /etc/mavlink-router/main.conf > /dev/null
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
EOF
    else
        log_info "Mavlink-router config already exists. Skipping creation."
    fi
}

## RTSP Streamer Setup
setup_rtsp_streamer() {
    local app_dir="${USER_HOME}/gst-rtsp-server"
    local venv_dir="/opt/rtsp-venv"
    log_info "Setting up RTSP streamer..."
    if [ ! -d "$venv_dir" ]; then
        log_info "Creating Python virtual environment in '$venv_dir' for the RTSP service..."
        sudo python3 -m venv "$venv_dir" --system-site-packages
    fi
    sudo -u "$USER_NAME" mkdir -p "$app_dir"
    log_info "Writing Python RTSP script to '$app_dir/stream.py'..."
    cat << 'EOF' | sudo -u "$USER_NAME" tee "${app_dir}/stream.py" > /dev/null
#!/usr/bin/env python3
# ... (Your full RTSP python script here) ...
EOF
    chmod +x "${app_dir}/stream.py"
    log_info "Creating systemd service for RTSP streamer..."
    cat << EOF | sudo tee /etc/systemd/system/rtsp-stream.service > /dev/null
[Unit]
Description=RTSP Streamer Service
After=network.target
[Service]
ExecStart=${venv_dir}/bin/python3 ${app_dir}/stream.py
WorkingDirectory=${app_dir}
Restart=always
User=${USER_NAME}
[Install]
WantedBy=multi-user.target
EOF
}

## LTE Modem Setup (RNDIS / usb0 Method)
setup_lte() {
    log_info "Setting up LTE connection (RNDIS/usb0 method)..."

    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if ! grep -q 'interface "usb0"' "$dhclient_conf"; then
        log_info "Appending usb0 config to $dhclient_conf..."
        cat <<'EOF' | sudo tee -a "$dhclient_conf" > /dev/null

interface "usb0" {
  request subnet-mask, broadcast-address, time-offset, routers,
          domain-name, domain-name-servers, host-name;
}
EOF
    else
        log_info "usb0 config already exists in $dhclient_conf. Skipping."
    fi

    log_info "Creating delayed DHCP service for usb0..."
    # The path to dhclient is corrected to /usr/sbin/dhclient
    cat <<'EOF' | sudo tee /etc/systemd/system/dhclient-usb0-delayed.service > /dev/null
[Unit]
Description=Delayed DHCP client for usb0 (RNDIS)
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "sleep 30 && /usr/sbin/dhclient -r usb0 && /usr/sbin/dhclient usb0"
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

    log_info "Sending AT command to configure modem for RNDIS mode..."
    echo -e "AT+QCFG=\"usbnet\",1\r" | sudo tee /dev/ttyUSB2 > /dev/null
    sleep 1
    echo -e "AT\r" | sudo tee /dev/ttyUSB2 > /dev/null
}

## ZeroTier Installation
install_zerotier() {
    log_info "Installing ZeroTier..."
    curl -s https://install.zerotier.com | sudo bash
}

install_tailscale() {
    log_info "Installing Tailscale VPN..."
    curl -fsSL https://tailscale.com/install.sh | sh
    log_info "Starting and enabling Tailscale service..."
    sudo systemctl enable --now tailscaled
}

## Finalize and Reboot
finalize_setup() {
    log_info "Reloading systemd and enabling services..."
    sudo systemctl daemon-reload
    sudo systemctl enable mavlink-router.service
    sudo systemctl enable rtsp-stream.service
    sudo systemctl enable dhclient-usb0-delayed.service
}

prompt_for_reboot() {
    read -rp "Do you want to reboot now to apply all changes? [y/N]: " choice
    case "$choice" in
        y|Y )
            log_info "Rebooting now..."
            sudo reboot
            ;;
        * )
            log_info "Reboot skipped. Please reboot manually."
            ;;
    esac
}

# --- Execute Script ---
main "$@"
