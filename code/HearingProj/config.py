# config.py
"""Portable hearing tester -- central configuration (star topology, phone = hub).

Deploy the SAME folder to every Pi, each under that Pi's own home:
    /home/pi-node01/HearingProj      -> node01
    /home/pi-node02/HearingProj    -> node02
    /home/pi-node03/HearingProj    -> node03

The node id is AUTO-DETECTED from the deploy path (see NODE_BY_USER below), so you
do NOT edit anything per Pi -- the same code just works on all three.

Topology (replaces the old SoftAP mesh -- see docs/DECISIONS.md D-009):
    phone hotspot  <--WiFi--  node01 / node02 / node03
  - The phone opens its own hotspot and runs a WebSocket server on WS_PORT.
  - Every node is a WebSocket CLIENT that dials the default gateway (= the phone).
  - Nodes never talk to each other; there is no relay and no per-node AP.

Design principles:
  - All constants live here; logic modules never hardcode pins, dB steps, paths or
    network parameters.
  - Volume is accounted for in dB (0 dB = full scale, -80 dB = silent). The phone
    still sends v in 0-100 linear; the conversion happens here via linear_to_db().
"""
import math
import os
import re
import socket

# ============================================================
# Which physical Pi am I? -- auto-detected from this file's install path.
# Works whether the process runs as the login user (node_client) or root
# (power_button), because it reads the folder the code sits in, not who runs it.
# ============================================================
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
    """Identity for a Pi deployed somewhere NODE_BY_USER does not cover.

    Derived from the hostname rather than defaulting to node01. A silent
    collision would leave two boards fighting over one card on the phone --
    each one's messages overwriting the other's state, with no error anywhere.
    An unexpected extra card named after the host is far easier to diagnose.
    """
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

# ============================================================
# WebSocket link to the phone
#   The phone's IP is NEVER hardcoded: net.default_gateway() reads the default
#   route, which on the phone's hotspot is the phone itself.
# ============================================================
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

# ============================================================
# Maintenance WiFi (hold A to switch to this network for SSH maintenance)
# NOTE: these are NetworkManager connection profile NAMES, not SSIDs.
#       The two are different identifiers -- run `nmcli con show` to find the
#       exact name. Do not put an SSID here.
# ============================================================
MAINT_WIFI_BY_USER = {
    "pi-node01":   "netplan-wlan0-YOUR_MAINT_WIFI",
    "pi-node02": "netplan-wlan0-YOUR_MAINT_WIFI",   # verify on guest1 Pi: nmcli con show
    "pi-node03": "netplan-wlan0-YOUR_MAINT_WIFI",   # verify on guest2 Pi: nmcli con show
}
MAINT_WIFI_PROFILE = MAINT_WIFI_BY_USER.get(DEPLOY_USER, "netplan-wlan0-YOUR_MAINT_WIFI")

# Work mode = joined to the phone's hotspot. A NetworkManager connection profile
# NAME (not the SSID).
#
# CURRENT SETUP: the phone hotspot the nodes dial IS the same network already
# saved as the maintenance WiFi ("netplan-wlan0-YOUR_MAINT_WIFI"), so this points
# straight at MAINT_WIFI_PROFILE. That means:
#   - no new "phone-hotspot" profile has to be created; the boards already have
#     this connection saved, and each board resolves the right per-user name via
#     MAINT_WIFI_BY_USER above;
#   - the A button has nothing to switch to, so it becomes a safe no-op
#     (see power_button.toggle_network). B still shuts down.
# To bring the A button back later, set this to a DIFFERENT profile name (e.g. a
# maintenance router) -- everything else keeps working unchanged.
HOTSPOT_PROFILE = MAINT_WIFI_PROFILE
WIFI_IFACE = "wlan0"

# ============================================================
# Data file (this node) -- lives next to the code, i.e. in this Pi's own home,
# so it is always writable by the run user and needs no per-Pi path editing.
#
# NOTE: the AUTHORITATIVE record now lives in the phone's SQLite database. This
# CSV is an offline BACKUP only -- it is the only thing that survives when the
# WebSocket link is down (there is no store-and-forward replay by design).
# ============================================================
DATA_FILE = os.path.join(_HERE, "results.csv")

# ============================================================
# Audio parameters
#   Per-chunk generation with an absolute sample index keeps phase continuous
#   across chunk boundaries -- never pre-generate a whole buffer.
# ============================================================
SAMPLE_RATE = 44100
CHUNK_SIZE = 1024                # frames per write chunk
DEFAULT_FREQUENCY = 1000         # initial frequency Hz

# TONE_DURATION is the COUNTDOWN, not a fixed length: playback stops when the
# countdown expires, and every X/Y press restarts it from TONE_DURATION. So the
# subject can keep hunting for their threshold as long as they keep pressing.
TONE_DURATION = 15.0             # seconds of silence-from-buttons that ends a tone
# Hard ceiling on one tone regardless of button presses, so a stuck button or a
# subject who never settles cannot play forever. Mirrors the phone's own timeout.
MAX_TONE_TOTAL_SEC = 120.0

# Fade-in / fade-out length in milliseconds, applied at the very start and end of
# a tone to avoid a click at the stream edges. 0 disables it, which reproduces the
# previous behaviour exactly. Set to 10 if hardware listening reveals clicks.
RAMP_MS = 0

# Output device: match the Pirate Audio / HifiBerry PCM5102A DAC by name. HDMI is
# excluded explicitly -- its device name contains 'i2s-hifi', which a looser
# 'hifi' keyword wrongly matched, sending audio to HDMI (stream failed to open,
# no sound). Falls back to the first output device when nothing matches, which is
# what the bare-board mock node needs.
AUDIO_DEV_KEYWORDS = ("hifiberry", "pcm5102", "sndrpihifiberry")
AUDIO_DEV_EXCLUDE = ("hdmi",)

# ============================================================
# dB volume system
#   linear amplitude = 10 ** (db / 20); ceiling 0 dB (= full scale 1.0),
#   floor -80 dB (~silent).
#
#   NOTE on the migration spec's REF_DB=100 / amplitude = 10^((level_db-REF_DB)/20):
#   that convention is NOT adopted. It would put every level 100 dB below the
#   current one and would not fit the existing X/Y step range or DEFAULT_DB.
#   REF_DB is kept at 0 purely as a documented placeholder for a future acoustic
#   calibration; with REF_DB = 0 the formula reduces to db_to_linear() below.
#   NOT ACOUSTICALLY CALIBRATED -- these are digital full-scale dB, not dB SPL.
# ============================================================
REF_DB = 0.0                     # placeholder, uncalibrated (see note above)
DB_CEILING = 0.0                 # upper limit (dB)
DB_FLOOR = -80.0                 # lower limit (dB); <= this outputs 0
DB_STEP_DOWN = 10.0              # X button: -10 dB per press
DB_STEP_UP = 5.0                 # Y button: +5 dB per press
DEFAULT_DB = -6.0                # initial volume (~ linear 0.5)

# ============================================================
# GPIO buttons (BCM numbering) -- all four keep their original behaviour.
#   X / Y are the SUBJECT's response keys: the subject hunts for the quietest
#   audible level, and where they settle is the threshold result.
#   A / B are operator keys handled by the separate root power_button service.
# ============================================================
BUTTON_Y = 24                    # Y: +5 dB   (older Pirate Audio batches use 20)
BUTTON_Y_LEGACY = 20             # swap BUTTON_Y to this if Y does not respond
BUTTON_X = 16                    # X: -10 dB
BUTTON_B = 6                     # B: hold to shut down
BUTTON_A = 5                     # A: hold to toggle network (work <-> maintenance)
LONG_PRESS_SEC = 3               # min hold to trigger (seconds)
LONG_PRESS_MAX_SEC = 6           # max hold; longer = accidental, ignored
POLL_INTERVAL = 0.05             # GPIO poll interval (seconds)
BUTTON_BOUNCETIME = 200          # debounce (ms)

# ============================================================
# Watchdog (power_button service). The WebSocket layer handles its own reconnect;
# this watchdog only checks that the WiFi link to the phone is still up, because a
# dropped hotspot is not something the socket can repair.
# ============================================================
HEARTBEAT_INTERVAL = 5           # watchdog poll period (seconds)
HEARTBEAT_FAIL_THRESHOLD = 3     # consecutive failures => link considered down
WATCHDOG_RETRY_ROUNDS = 3        # reconnect rounds after a drop
WATCHDOG_SLEEP = 30              # sleep (seconds) after all rounds fail, then loop
GATEWAY_PROBE_TIMEOUT = 2        # seconds to wait for one gateway ping


# ---------- derived helpers ----------
def db_to_linear(db):
    """dB to linear amplitude. db <= DB_FLOOR is treated as silence (returns 0.0)."""
    if db <= DB_FLOOR:
        return 0.0
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
