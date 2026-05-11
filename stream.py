#!/usr/bin/env python3
"""USB camera -> RTSP publisher (GStreamer / GstRtspServer).

Reads a UVC USB camera (default /dev/video0) and publishes an H.264 RTSP feed.
Used by the rtsp-stream.service systemd unit on OI Pi 5 and Pi Zero 2W companion
computers. All knobs are env-tunable so the same file works for both platforms;
the systemd unit sets per-model defaults via Environment= lines.

Env vars:
  RTSP_DEVICE        v4l2 device path             (default /dev/video0)
  RTSP_WIDTH         capture width in pixels      (default 1280)
  RTSP_HEIGHT        capture height in pixels     (default 720)
  RTSP_FRAMERATE     capture framerate            (default 30)
  RTSP_BITRATE       x264 target bitrate (kbps)   (default 2500)
  RTSP_PORT          RTSP service port            (default 8554)
  RTSP_PATH          mount point                  (default /cam)
  RTSP_INPUT_FORMAT  raw | mjpeg                  (default raw)
  LOG_LEVEL          python logging level         (default INFO)
"""
import logging
import os
import signal
import sys

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstRtspServer", "1.0")
from gi.repository import GLib, Gst, GstRtspServer

DEVICE = os.environ.get("RTSP_DEVICE", "/dev/video0")
WIDTH = int(os.environ.get("RTSP_WIDTH", "1280"))
HEIGHT = int(os.environ.get("RTSP_HEIGHT", "720"))
FRAMERATE = int(os.environ.get("RTSP_FRAMERATE", "30"))
BITRATE_KBPS = int(os.environ.get("RTSP_BITRATE", "2500"))
PORT = os.environ.get("RTSP_PORT", "8554")
MOUNT_POINT = os.environ.get("RTSP_PATH", "/cam")
INPUT_FORMAT = os.environ.get("RTSP_INPUT_FORMAT", "raw").lower()

# Pi 5 and Pi Zero 2W have no usable v4l2 H.264 hardware encoder under current
# kernels, so we always encode in software with x264enc. ultrafast+zerolatency
# keeps a single 720p30 (or 480p30 on Zero) stream well below one core.
if INPUT_FORMAT == "mjpeg":
    SOURCE = (
        f"v4l2src device={DEVICE} do-timestamp=true ! "
        f"image/jpeg,width={WIDTH},height={HEIGHT},framerate={FRAMERATE}/1 ! "
        f"jpegdec"
    )
else:
    SOURCE = (
        f"v4l2src device={DEVICE} do-timestamp=true ! "
        f"video/x-raw,width={WIDTH},height={HEIGHT},framerate={FRAMERATE}/1"
    )

PIPELINE = (
    f"{SOURCE} ! videoconvert ! "
    f"x264enc tune=zerolatency speed-preset=ultrafast "
    f"bitrate={BITRATE_KBPS} key-int-max={FRAMERATE * 2} ! "
    f"rtph264pay name=pay0 pt=96 config-interval=1"
)


class USBCameraFactory(GstRtspServer.RTSPMediaFactory):
    def __init__(self):
        super().__init__()
        self.set_shared(True)
        self.set_launch(PIPELINE)


def main() -> int:
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(message)s",
        level=os.environ.get("LOG_LEVEL", "INFO"),
    )
    log = logging.getLogger("rtsp-stream")

    if not os.path.exists(DEVICE):
        log.error("Capture device %s not present. Try: v4l2-ctl --list-devices", DEVICE)
        return 1

    Gst.init(None)
    server = GstRtspServer.RTSPServer()
    server.set_service(PORT)
    server.get_mount_points().add_factory(MOUNT_POINT, USBCameraFactory())

    if server.attach(None) == 0:
        log.error("Failed to attach RTSP server on port %s", PORT)
        return 1

    log.info(
        "Publishing rtsp://0.0.0.0:%s%s (device=%s %dx%d@%dfps, %d kbps, input=%s)",
        PORT, MOUNT_POINT, DEVICE, WIDTH, HEIGHT, FRAMERATE, BITRATE_KBPS, INPUT_FORMAT,
    )

    loop = GLib.MainLoop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, loop.quit)
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
