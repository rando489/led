# =========================
# setup.sh (FULLY SELF-CONTAINED - Pi 5 LGPIO)
# =========================
#!/bin/bash

set -e

echo "=== WS2812B E1.31 Setup for Raspberry Pi 5 (LGPIO) ==="

# Prevent running as root
if [ "$EUID" -eq 0 ]; then
  echo "Run this script as a normal user, not root."
  exit
fi

# Ask for GPIO pin (default 4)
read -p "Enter GPIO pin (default 4): " PIN
PIN=${PIN:-4}

# Ask for LED count
read -p "Enter number of LEDs: " LED_COUNT

# Install dependencies
echo "Installing dependencies..."
sudo apt update
sudo apt install -y python3-pip python3-lgpio
pip3 install --break-system-packages rpi_ws281x sacn

# Paths
SCRIPT_PATH="$(pwd)/e131_ws2812b.py"
CONFIG_FILE="$(pwd)/e131_ws2812b_config.json"

# =========================
# CREATE PYTHON SCRIPT
# =========================
cat <<'PYEOF' > $SCRIPT_PATH
#!/usr/bin/env python3

import argparse
import json
import time
import sacn
from rpi_ws281x import PixelStrip, Color

parser = argparse.ArgumentParser()
parser.add_argument("--pin", type=int)
parser.add_argument("--count", type=int)
parser.add_argument("--test", type=int)
parser.add_argument("--config", type=str)
args = parser.parse_args()

# Load config
if args.config:
    with open(args.config, 'r') as f:
        cfg = json.load(f)
        pin = cfg['pin']
        led_count = cfg['led_count']
else:
    pin = args.pin
    led_count = args.count

strip = PixelStrip(led_count, pin, strip_type=0x00100800)
strip.begin()

# TEST MODE
if args.test:
    print(f"Lighting first {args.test} LEDs...")
    for i in range(args.test):
        strip.setPixelColor(i, Color(255, 255, 255))
    strip.show()

    input("Press Enter to clear...")

    for i in range(led_count):
        strip.setPixelColor(i, Color(0, 0, 0))
    strip.show()
    exit()

# E1.31
receiver = sacn.sACNreceiver()
receiver.start()

UNIVERSE = 1

@receiver.listen_on('universe', universe=UNIVERSE)
def callback(packet):
    data = packet.dmxData

    for i in range(min(len(data)//3, led_count)):
        r = data[i*3]
        g = data[i*3+1]
        b = data[i*3+2]
        strip.setPixelColor(i, Color(r, g, b))

    strip.show()

print("E1.31 listener running...")

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    receiver.stop()
PYEOF

chmod +x $SCRIPT_PATH

# =========================
# SAVE CONFIG
# =========================
cat <<EOF > $CONFIG_FILE
{
    "pin": $PIN,
    "led_count": $LED_COUNT
}
EOF

echo "Config saved to $CONFIG_FILE"

# =========================
# TEST MODE
# =========================
echo "\n=== TEST MODE ==="
read -p "Enter number of LEDs to light up for testing: " TEST_COUNT

python3 $SCRIPT_PATH --pin $PIN --count $LED_COUNT --test $TEST_COUNT

# =========================
# SYSTEMD SERVICE
# =========================
SERVICE_FILE="/etc/systemd/system/e131_ws2812b.service"

echo "Creating systemd service..."

sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=E1.31 WS2812B Controller (Pi 5 LGPIO)
After=network.target

[Service]
ExecStart=/usr/bin/python3 $SCRIPT_PATH --config $CONFIG_FILE
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable e131_ws2812b.service

echo "\nSetup complete!"
echo "Start with: sudo systemctl start e131_ws2812b"
