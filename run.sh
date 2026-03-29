# =========================
# setup.sh (TRUE LGPIO BITBANG - PI 5 CORRECT)
# =========================
#!/bin/bash

set -e

echo "=== WS2812B E1.31 Setup for Raspberry Pi 5 (REAL LGPIO) ==="

if [ "$EUID" -eq 0 ]; then
  echo "Run as normal user, not root"
  exit
fi

# Ask for GPIO pin (default 4)
read -p "Enter GPIO pin (default 4): " PIN
PIN=${PIN:-4}

# Ask LED count
read -p "Enter number of LEDs: " LED_COUNT

# Install deps
echo "Installing dependencies..."
sudo apt update
sudo apt install -y python3-pip python3-lgpio
pip3 install --break-system-packages sacn

SCRIPT_PATH="$(pwd)/e131_ws2812b.py"
CONFIG_FILE="$(pwd)/e131_ws2812b_config.json"

# =========================
# CREATE PYTHON SCRIPT (REAL LGPIO DRIVER)
# =========================
cat <<'PYEOF' > $SCRIPT_PATH
#!/usr/bin/env python3

import argparse
import json
import time
import sacn
import lgpio

# WS2812 timing (approx ns converted to seconds)
T0H = 0.00000035
T0L = 0.00000080
T1H = 0.00000070
T1L = 0.00000060

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

h = lgpio.gpiochip_open(0)
lgpio.gpio_claim_output(h, pin)

pixels = [(0,0,0)] * led_count

# =========================
# LOW LEVEL WRITE
# =========================
def send_bit(bit):
    if bit:
        lgpio.gpio_write(h, pin, 1)
        time.sleep(T1H)
        lgpio.gpio_write(h, pin, 0)
        time.sleep(T1L)
    else:
        lgpio.gpio_write(h, pin, 1)
        time.sleep(T0H)
        lgpio.gpio_write(h, pin, 0)
        time.sleep(T0L)


def send_byte(byte):
    for i in range(8):
        send_bit((byte << i) & 0x80)


def show():
    for r,g,b in pixels:
        send_byte(g)
        send_byte(r)
        send_byte(b)
    time.sleep(0.00005)

# =========================
# TEST MODE
# =========================
if args.test:
    for i in range(min(args.test, led_count)):
        pixels[i] = (255,255,255)
    show()
    input("Press Enter to clear...")
    pixels[:] = [(0,0,0)] * led_count
    show()
    exit()

# =========================
# E1.31 RECEIVER
# =========================
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
        pixels[i] = (r,g,b)

    show()

print("E1.31 LGPIO controller running...")

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    receiver.stop()
    lgpio.gpiochip_close(h)
PYEOF

chmod +x $SCRIPT_PATH

# Save config
cat <<EOF > $CONFIG_FILE
{
    "pin": $PIN,
    "led_count": $LED_COUNT
}
EOF

# Test mode
read -p "Test LED count: " TEST_COUNT
python3 $SCRIPT_PATH --pin $PIN --count $LED_COUNT --test $TEST_COUNT

# Systemd
SERVICE_FILE="/etc/systemd/system/e131_ws2812b.service"

sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=E1.31 WS2812B (LGPIO TRUE)
After=network.target

[Service]
ExecStart=/usr/bin/python3 $SCRIPT_PATH --config $CONFIG_FILE
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable e131_ws2812b.service

echo "Done. Start with: sudo systemctl start e131_ws2812b"
