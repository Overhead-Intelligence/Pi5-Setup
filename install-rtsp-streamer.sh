#!/bin/bash
#
# Standalone installer for the USB->RTSP streamer.
#
# Works on an already-set-up Pi 5 or Pi Zero 2W. Installs GStreamer + Python
# bindings, drops stream.py into ~/gst-rtsp-server/, and registers
# rtsp-stream.service. Auto-detects model and picks sane defaults.
#
# Usage:
#   curl -fsSLO https://raw.githubusercontent.com/Overhead-Intelligence/oi-pi-setup-scripts/main/install-rtsp-streamer.sh
#   chmod +x install-rtsp-streamer.sh
#   ./install-rtsp-streamer.sh
#
set -euo pipefail

USER_NAME="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
APP_DIR="${USER_HOME}/gst-rtsp-server"
VENV_DIR="/opt/rtsp-venv"
STREAM_PY_URL="https://raw.githubusercontent.com/Overhead-Intelligence/oi-pi-setup-scripts/main/stream.py"

log() { echo -e "\n[install-rtsp-streamer] $*"; }

if [[ $EUID -eq 0 ]]; then
    echo "Run as the normal user (droneman). It will sudo where needed." >&2
    exit 1
fi

# --- Detect model and pick defaults ---
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
log "Detected: ${MODEL}"

case "$MODEL" in
    *"Pi Zero 2"*)
        RTSP_WIDTH=640
        RTSP_HEIGHT=480
        RTSP_FRAMERATE=30
        RTSP_BITRATE=1000
        RTSP_INPUT_FORMAT=mjpeg
        ;;
    *"Pi 5"*)
        RTSP_WIDTH=1280
        RTSP_HEIGHT=720
        RTSP_FRAMERATE=30
        RTSP_BITRATE=2500
        RTSP_INPUT_FORMAT=raw
        ;;
    *)
        # Conservative defaults for anything else (Pi 4, CM4, etc.)
        RTSP_WIDTH=1280
        RTSP_HEIGHT=720
        RTSP_FRAMERATE=30
        RTSP_BITRATE=2000
        RTSP_INPUT_FORMAT=raw
        ;;
esac
log "Defaults: ${RTSP_WIDTH}x${RTSP_HEIGHT}@${RTSP_FRAMERATE} ${RTSP_BITRATE}kbps input=${RTSP_INPUT_FORMAT}"

sudo -v

# --- Packages ---
log "Installing GStreamer + Python GI packages..."
sudo apt-get update
sudo apt-get install -y \
    python3-gi python3-gi-cairo gir1.2-gst-rtsp-server-1.0 \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    gstreamer1.0-rtsp v4l-utils

# --- Permissions for v4l2 ---
log "Ensuring ${USER_NAME} is in the 'video' group..."
sudo usermod -aG video "$USER_NAME"

# --- Python venv (system-site-packages so it sees python3-gi) ---
if [ ! -d "$VENV_DIR" ]; then
    log "Creating venv at ${VENV_DIR}..."
    sudo python3 -m venv "$VENV_DIR" --system-site-packages
else
    log "Venv ${VENV_DIR} already present."
fi

# --- Drop stream.py ---
mkdir -p "$APP_DIR"
log "Installing stream.py to ${APP_DIR}/stream.py..."
if [ -f "$(dirname "$(readlink -f "$0")")/stream.py" ]; then
    cp "$(dirname "$(readlink -f "$0")")/stream.py" "${APP_DIR}/stream.py"
else
    curl -fsSL "$STREAM_PY_URL" -o "${APP_DIR}/stream.py"
fi
chmod +x "${APP_DIR}/stream.py"

# --- systemd unit ---
log "Writing /etc/systemd/system/rtsp-stream.service..."
sudo tee /etc/systemd/system/rtsp-stream.service > /dev/null <<EOF
[Unit]
Description=USB Camera RTSP Streamer
After=network.target

[Service]
Environment=RTSP_DEVICE=/dev/video0
Environment=RTSP_WIDTH=${RTSP_WIDTH}
Environment=RTSP_HEIGHT=${RTSP_HEIGHT}
Environment=RTSP_FRAMERATE=${RTSP_FRAMERATE}
Environment=RTSP_BITRATE=${RTSP_BITRATE}
Environment=RTSP_PORT=8554
Environment=RTSP_PATH=/cam
Environment=RTSP_INPUT_FORMAT=${RTSP_INPUT_FORMAT}
ExecStart=${VENV_DIR}/bin/python3 ${APP_DIR}/stream.py
WorkingDirectory=${APP_DIR}
Restart=always
RestartSec=3
User=${USER_NAME}

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rtsp-stream.service
sudo systemctl restart rtsp-stream.service

# --- Status report ---
IP="$(hostname -I | awk '{print $1}')"
cat <<EOF

------------------------------------------------------------
RTSP streamer installed.

Test from another machine on the same network:
  ffplay rtsp://${IP:-<pi-ip>}:8554/cam
  vlc    rtsp://${IP:-<pi-ip>}:8554/cam

Inspect:
  systemctl status rtsp-stream.service
  journalctl -u rtsp-stream.service -f

If the camera isn't at /dev/video0, find it with:
  v4l2-ctl --list-devices
Then edit /etc/systemd/system/rtsp-stream.service (RTSP_DEVICE=...)
and run: sudo systemctl daemon-reload && sudo systemctl restart rtsp-stream.service

NOTE: you may need to log out and back in for the 'video' group to take effect.
------------------------------------------------------------
EOF
