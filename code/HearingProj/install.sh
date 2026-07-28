#!/usr/bin/env bash
# install.sh -- install the two systemd services for THIS board.
#
# Run ONCE on each Pi, as that Pi's own login user (pi-node01 / pi-node02),
# from inside the code folder:
#
#     cd ~/HearingProj && bash install.sh
#
# It reads the current user and home directory, fills those into both service
# unit files, installs them, adds the user to the gpio and audio groups, and
# enables + starts both services. Nothing needs editing by hand per board -- the
# node id itself is auto-detected from the home directory (see config.py), and
# this script fills in User=/paths from whoever runs it.
set -euo pipefail

RUN_USER="$(id -un)"
RUN_HOME="$(eval echo "~$RUN_USER")"
PROJ_DIR="$RUN_HOME/HearingProj"

if [ "$RUN_USER" = "root" ]; then
  echo "ERROR: run this as your login user (e.g. pi-node01), NOT root or sudo." >&2
  echo "       sudo is used internally only where it is actually needed." >&2
  exit 1
fi
if [ ! -f "$PROJ_DIR/node_client.py" ]; then
  echo "ERROR: expected the code at $PROJ_DIR but node_client.py is missing." >&2
  echo "       Copy the HearingProj folder into your home first." >&2
  exit 1
fi

cd "$PROJ_DIR"

# ---- retire the pre-migration (Flask / SoftAP) services ----
# The old Flask app claimed the X/Y GPIO pins (16/24). If it is still enabled --
# or its process is still running from before the code was moved aside -- the new
# node cannot claim those pins and the buttons come up as "GPIO busy". Stop,
# disable, and kill any leftovers before starting the new services.
for old in hearingproj-app hearingproj-hostapd hearingproj-dnsmasq hearingproj-uap0; do
  sudo systemctl disable --now "$old" 2>/dev/null || true
done
sudo pkill -f 'HearingProj[^ ]*/app.py' 2>/dev/null || true

# ---- Python dependencies (system-wide, for the service's /usr/bin/python3) ----
# Raspberry Pi OS Bookworm blocks `pip install` system-wide (PEP 668), so use the
# Debian packages -- they land where /usr/bin/python3 looks. numpy and pyaudio
# come with the existing image; only websockets is new.
if ! python3 -c 'import websockets' 2>/dev/null; then
  echo "Installing python3-websockets via apt..."
  sudo apt-get update && sudo apt-get install -y python3-websockets
fi
for mod in numpy pyaudio; do
  if ! python3 -c "import $mod" 2>/dev/null; then
    echo "WARNING: python3 module '$mod' is missing. Install it with:"
    echo "         sudo apt install -y python3-$mod"
  fi
done

NODE_ID="$(python3 -c 'import config; print(config.NODE_ID)' 2>/dev/null || echo '?')"
echo "Installing for user=$RUN_USER  home=$RUN_HOME  ->  node=$NODE_ID"
echo

# ---- node service (runs as the login user; needs gpio + audio) ----
sudo tee /etc/systemd/system/hearing-node.service >/dev/null <<EOF
[Unit]
Description=Hearing test node (WebSocket client + audio + X/Y buttons)
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$PROJ_DIR
ExecStart=/usr/bin/python3 $PROJ_DIR/node_client.py
Environment=PYTHONUNBUFFERED=1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ---- power service (root: A/B buttons + hotspot watchdog + shutdown) ----
sudo tee /etc/systemd/system/hearingproj-power.service >/dev/null <<EOF
[Unit]
Description=HearingProj Power / Network / Watchdog (A / B keys, hotspot watchdog)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
User=root
WorkingDirectory=$PROJ_DIR
ExecStart=/usr/bin/python3 $PROJ_DIR/power_button.py
Environment=PYTHONUNBUFFERED=1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ---- group membership for the GPIO buttons and the sound card ----
NEED_RELOGIN=0
if ! id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx gpio; then NEED_RELOGIN=1; fi
if ! id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx audio; then NEED_RELOGIN=1; fi
sudo usermod -aG gpio,audio "$RUN_USER"

# ---- enable + start ----
sudo systemctl daemon-reload
sudo systemctl enable hearing-node hearingproj-power
# restart (not just --now) so a previous run is replaced cleanly and the buttons
# are re-claimed after the old services were disabled above.
sudo systemctl restart hearing-node hearingproj-power

echo
echo "Installed and started. This board is $NODE_ID."
echo "  Watch the node:  journalctl -u hearing-node -f"
echo "  Watch A/B/watchdog:  journalctl -u hearingproj-power -f"
if [ "$NEED_RELOGIN" = "1" ]; then
  echo
  echo "IMPORTANT: you were just added to the gpio/audio groups. The buttons and"
  echo "sound card will not work until that takes effect -- reboot once now:"
  echo "  sudo reboot"
fi
