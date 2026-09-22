# config.py
"""Portable hearing tester -- central configuration (star topology, phone = hub).

Deploy the SAME folder to every Pi, each under that Pi's own home
(e.g. /home/pi-node01/HearingProj -> node01). The node id is auto-detected
from the deploy path (see NODE_BY_USER below).

Topology (replaces an earlier SoftAP mesh design): the phone opens its own
hotspot and runs a WebSocket server on WS_PORT; every node is a WebSocket
client that dials the default gateway (= the phone). Nodes never talk to
each other.

All constants live here; logic modules never hardcode pins, dB steps, paths
or network parameters. Volume is in dB (0 = full scale, -120 = floor);
the phone sends v in 0-100 linear, converted here via linear_to_db().
"""
import math
import os
import re
import socket

# Which physical Pi am I? Auto-detected from this file's install path, so it
# works regardless of which user (node_client or root power_button) runs it.
_HERE = os.path.dirname(os.path.abspath(__file__))     # e.g. /home/pi-node03/HearingProj
_DEPLOY_HOME = os.path.dirname(_HERE)                   # e.g. /home/pi-node03
DEPLOY_USER = os.path.basename(_DEPLOY_HOME)            # e.g. pi-node03

# Map deploy user -> logical node id. All three nodes run at the same time and are
# completely symmetric: only NODE_ID differs.
NODE_BY_USER = {
    "pi-node01": "node01",
    "pi-node02": "node02",
    "pi-node03": "node03",
}

# Manual override: set to e.g. "node04" to force an id; leave None to auto-detect.
MANUAL_NODE_ID = None


def _fallback_node_id():
    """Identity for a Pi not covered by NODE_BY_USER. Derived from the
    hostname rather than defaulting to node01, to avoid silent id collisions."""
    try:
        host = socket.gethostname().strip()
    except Exception:
        host = ""
    return "node-" + (re.sub(r"[^A-Za-z0-9_-]", "-", host).lower() or "unknown")


NODE_ID = (MANUAL_NODE_ID if MANUAL_NODE_ID is not None
           else NODE_BY_USER.get(DEPLOY_USER) or _fallback_node_id())

# Reported to the phone in the register message (informational only).
HW_BY_USER = {
    "pi-node01": "pi-zero-2w",
    "pi-node02": "pi-zero-w",
    "pi-node03": "pi-zero-2w",
}
HW_MODEL = HW_BY_USER.get(DEPLOY_USER, "pi-zero-2w")
AUDIO_BACKEND = "pcm5102a"        # Pirate Audio I2S DAC
FW_VERSION = "2.0.0"

# WebSocket link to the phone. The phone's IP is never hardcoded:
# net.default_gateway() reads the default route (the phone, on its hotspot).
WS_PORT = 8765
WS_PATH = "/ws"
# Development override: dial this host instead of the default gateway, so a node
# can be tested against dev_server.py on a laptop that is not the gateway.
#   HEARING_WS_HOST=192.168.1.50 python3 node_client.py
# Leave unset in production -- the phone's address must stay auto-discovered.
WS_HOST_OVERRIDE = os.environ.get("HEARING_WS_HOST") or None
HEARTBEAT_INTERVAL_S = 5         # uplink heartbeat period (seconds)
WS_OPEN_TIMEOUT_S = 8            # give up on one connect attempt after this
WS_PING_INTERVAL_S = 20          # websockets protocol-level keepalive
WS_PING_TIMEOUT_S = 20
RECONNECT_BASE_S = 1             # exponential backoff start
RECONNECT_MAX_S = 30             # exponential backoff ceiling
RECONNECT_JITTER = 0.3           # +/- fraction of the delay, avoids 3 nodes syncing
# After this many consecutive failed connect attempts, ask the network layer to
# re-establish the WiFi link (the socket cannot fix a dropped hotspot by itself).
RECONNECT_NET_RETRY_AFTER = 5

# Maintenance WiFi (hold A to switch to this network for SSH maintenance).
# These are NetworkManager connection profile NAMES, not SSIDs -- run
# `nmcli con show` to find the exact name.
MAINT_WIFI_BY_USER = {
    "pi-node01":   "netplan-wlan0-YOUR_MAINT_WIFI",
    "pi-node02": "netplan-wlan0-YOUR_MAINT_WIFI",   # verify on guest1 Pi: nmcli con show
    "pi-node03": "netplan-wlan0-YOUR_MAINT_WIFI",   # verify on guest2 Pi: nmcli con show
}
MAINT_WIFI_PROFILE = MAINT_WIFI_BY_USER.get(DEPLOY_USER, "netplan-wlan0-YOUR_MAINT_WIFI")

# Work mode = joined to the phone's hotspot (a NetworkManager profile name).
# Currently the same profile as maintenance WiFi, so the A button is a safe
# no-op (see power_button.toggle_network); point this at a different profile
# to bring A's switch-network behaviour back.
HOTSPOT_PROFILE = MAINT_WIFI_PROFILE
WIFI_IFACE = "wlan0"

# Data file (this node). The authoritative record lives in the phone's
# SQLite database; this CSV is an offline backup only.
DATA_FILE = os.path.join(_HERE, "results.csv")

# Audio parameters. Generation is per-chunk with an absolute sample index,
# to keep phase continuous across chunk boundaries.
SAMPLE_RATE = 44100
CHUNK_SIZE = 1024                # frames per write chunk
DEFAULT_FREQUENCY = 1000         # initial frequency Hz

# TONE_DURATION is a countdown, not a fixed length: playback stops when it
# expires, and every X/Y press restarts it, so the subject can keep hunting.
TONE_DURATION = 15.0             # seconds of silence-from-buttons that ends a tone
# Hard ceiling on one tone regardless of button presses (stuck button etc).
MAX_TONE_TOTAL_SEC = 120.0

# Fade-in/out length (ms) to avoid a click at tone edges. 0 disables it.
RAMP_MS = 0

# Output device: match the Pirate Audio / HifiBerry PCM5102A DAC by name.
# HDMI is excluded explicitly -- its device name also contains 'hifi' and
# would otherwise match. Falls back to the first output device (bare-board
# mock node) when nothing matches.
AUDIO_DEV_KEYWORDS = ("hifiberry", "pcm5102", "sndrpihifiberry")
AUDIO_DEV_EXCLUDE = ("hdmi",)

# dB volume system: linear amplitude = 10 ** (db / 20); ceiling 0 dB (full
# scale), floor -120 dB. The floor is a clamp, not a mute -- silencing output
# is the job of stop/is_playing. Not acoustically calibrated (digital
# full-scale dB, not dB SPL); REF_DB is a placeholder for future calibration.
REF_DB = 0.0                     # placeholder, uncalibrated
DB_CEILING = 0.0                 # upper limit (dB)
DB_FLOOR = -120.0                # lower limit (dB); a clamp, NOT a mute
DB_STEP_DOWN = 10.0              # X button: -10 dB per press
DB_STEP_UP = 5.0                 # Y button: +5 dB per press
DEFAULT_DB = -6.0                # initial volume (~ linear 0.5)

# GPIO buttons (BCM numbering). X/Y are the subject's response keys (hunt
# for the quietest audible level); A/B are operator keys (power_button service).
BUTTON_Y = 24                    # Y: +5 dB   (older Pirate Audio batches use 20)
BUTTON_Y_LEGACY = 20             # swap BUTTON_Y to this if Y does not respond
BUTTON_X = 16                    # X: -10 dB
BUTTON_B = 6                     # B: hold to shut down
BUTTON_A = 5                     # A: hold to toggle network (work <-> maintenance)
LONG_PRESS_SEC = 3               # min hold to trigger (seconds)
LONG_PRESS_MAX_SEC = 6           # max hold; longer = accidental, ignored
POLL_INTERVAL = 0.05             # GPIO poll interval (seconds)
BUTTON_BOUNCETIME = 200          # debounce (ms)

# Watchdog (power_button service): checks the WiFi link to the phone is up,
# since a dropped hotspot is not something the WebSocket layer can repair.
HEARTBEAT_INTERVAL = 5           # watchdog poll period (seconds)
HEARTBEAT_FAIL_THRESHOLD = 3     # consecutive failures => link considered down
WATCHDOG_RETRY_ROUNDS = 3        # reconnect rounds after a drop
WATCHDOG_SLEEP = 30              # sleep (seconds) after all rounds fail, then loop
GATEWAY_PROBE_TIMEOUT = 2        # seconds to wait for one gateway ping


# ---------- derived helpers ----------
def db_to_linear(db):
    """dB to linear amplitude. Always a real amplitude -- the floor never mutes."""
    return 10 ** ((db - REF_DB) / 20.0)


def linear_to_db(linear):
    """Linear (0..1) to dB. Used to convert play_tone's v param (0..100).
    <=0 returns DB_FLOOR."""
    if linear <= 0:
        return DB_FLOOR
    return 20 * math.log10(linear) + REF_DB


def clamp_db(db):
    """Clamp dB to [DB_FLOOR, DB_CEILING]. Returns (clamped_value, at_floor, at_ceiling)."""
    at_floor = db <= DB_FLOOR
    at_ceiling = db >= DB_CEILING
    return max(DB_FLOOR, min(DB_CEILING, db)), at_floor, at_ceiling
