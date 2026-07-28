# USAGE.md -- Portable Hearing Tester (star topology, phone = hub)

> All nodes run the SAME code. Nothing is edited per Pi: the node id comes from
> the deploy path. See `docs/DECISIONS.md` D-009 for why the architecture changed.

---

## 0. Topology overview

```
        phone (Flutter app)
        - hotspot turned on by hand in Android settings
        - WebSocket server on 0.0.0.0:8765/ws
        - SQLite: the authoritative result store
                 ^        ^        ^
                 |        |        |   WebSocket (JSON text frames)
          +------+        |        +------+
       node01            node02          node03
    Pi Zero 2W        Pi Zero W       Pi Zero 2W
   +Pirate Audio     +Pirate Audio    (or bare, running mock_node.py)
```

- Nodes **never talk to each other**. Each one dials the phone and nothing else.
- Nodes are dumb terminals: play a tone, report the subject's button presses.
  All test state lives on the phone.
- The phone address is **never hardcoded**. Each node reads its default gateway,
  which on the phone's hotspot is the phone.

## How one test runs

1. Operator sets frequency / volume / ear on that node's card and presses Play.
2. The node plays a pure tone and starts a **15 second countdown**.
3. The subject presses **X** (quieter, -10 dB) and **Y** (louder, +5 dB) hunting
   for the quietest level they can still hear. **Every press restarts the
   countdown**, so the tone keeps going for as long as they need.
4. When they stop pressing, the countdown expires and the tone ends. The level
   they settled on is their threshold for that frequency.
5. The node reports it; the phone stores it and re-enables the Play button.

---

## 1. Node identity is auto-detected (no per-Pi editing)

From the deploy path (`config.NODE_BY_USER`):

| Deploy path | NODE_ID | Hardware |
|---|---|---|
| `/home/pi-node01/HearingProj` | node01 | pi-zero-2w |
| `/home/pi-node02/HearingProj` | node02 | pi-zero-w |
| `/home/pi-node03/HearingProj` | node03 | pi-zero-2w |

To force an id (e.g. a fourth board), set `MANUAL_NODE_ID` in `config.py`.

---

## 2. One-time system setup on each Pi

### 2.1 Pirate Audio I2S DAC -- CHECK, do not redo

**The two Pis that already produce sound have this configured.** Check before
changing anything:

```bash
grep -i "hifiberry\|dtparam=audio" /boot/firmware/config.txt   # older images: /boot/config.txt
aplay -l
```

If you see `dtoverlay=hifiberry-dac` and a card named `sndrpihifiberry`, this
section is done -- skip it. The bare board running `mock_node.py` needs nothing
here at all; it never imports PyAudio.

Only for a **fresh** Pi, add to `/boot/firmware/config.txt` and reboot:

```
dtoverlay=hifiberry-dac
gpio=25=op,dh          # Pirate Audio amp enable; harmless on the headphone version
```

Pirate Audio carries a PCM5102A DAC on the I2S pins -- the same chip and wiring
as a HifiBerry DAC, which is why the stock `hifiberry-dac` overlay drives it.
Without the overlay the board is present but silent, because nothing tells the
kernel what is attached to those pins.

> The migration spec also lists `dtparam=audio=off` (to stop HDMI audio claiming
> the default device). **Do not add it to a working Pi.** `audio.py` already
> excludes HDMI by name (`config.AUDIO_DEV_EXCLUDE`), so the problem it solves is
> already handled, and the line would remove HDMI audio for no gain.

Confirm what PyAudio actually sees:

```bash
python3 test.py
```

You want a line containing `hifiberry` or `pcm5102`. `audio.py` matches on that
name and explicitly refuses to match HDMI (HDMI's device name contains
`i2s-hifi`, which a looser keyword once wrongly caught, sending audio to HDMI so
the stream failed to open and nothing played).

Pin usage lines up with Pirate Audio's own layout, so nothing here collides:

| BCM | Pirate Audio | This code |
|---|---|---|
| 5 / 6 / 16 / 24 | on-board A / B / X / Y buttons | A / B / X / Y |
| 25 | amp enable | not touched |
| 8 / 9 / 10 / 11 / 13 | LCD over SPI | not touched (no display support) |
| 18 / 19 / 21 | I2S audio | driven by the overlay, not by this code |

### 2.2 Python dependencies

Raspberry Pi OS Bookworm blocks `pip install` system-wide (the PEP 668
"externally-managed-environment" error), and the service runs on the system
`/usr/bin/python3`, so install everything from apt rather than pip:

```bash
sudo apt install -y python3-pyaudio python3-numpy python3-rpi.gpio python3-websockets
```

(`install.sh` also installs `python3-websockets` on its own if it is missing, so
you can skip this and let the installer handle it.)

### 2.3 Configure the hotspot ON THE PHONE first

Two settings on a modern Android phone will stop a Pi Zero associating, and both
fail silently -- the Pi just never sees the network:

| Setting | Must be | Why |
|---|---|---|
| Band | **2.4 GHz** | Pi Zero W and Zero 2W have no 5 GHz or 6 GHz radio at all |
| Security | **WPA2 PSK** | Newer phones default to WPA3-Personal or WPA2/WPA3 mixed. WPA3 (SAE) on the Zero W's BCM43438 is unreliable |

On Samsung: Settings -> Connections -> Mobile Hotspot -> Configure. Some builds
expose a single "Maximise compatibility" toggle that forces 2.4 GHz; set the
band and security explicitly anyway.

If you must run the hotspot on WPA3, the profile below needs
`wifi-sec.key-mgmt sae` instead of `wpa-psk`, and expect the Zero W to be the
one that fails.

### 2.4 Join the phone's hotspot (already done on these boards)

The boards already have a saved connection to this phone hotspot -- it is the
same network that used to be the maintenance WiFi, `netplan-wlan0-YOUR_MAINT_WIFI`.
So `config.HOTSPOT_PROFILE` is set to `MAINT_WIFI_PROFILE` and **no new profile
needs to be created.** Just confirm the saved connection is there:

```bash
nmcli con show          # you should see netplan-wlan0-YOUR_MAINT_WIFI in the list
```

If it is missing on some board, create it once (name it to match
`MAINT_WIFI_BY_USER` for that board):

```bash
sudo nmcli con add type wifi ifname wlan0 con-name netplan-wlan0-YOUR_MAINT_WIFI \
  ssid "<HOTSPOT_SSID>" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "<HOTSPOT_PASSWORD>" \
  autoconnect yes
```

**Single-network consequence:** with the work hotspot and the maintenance WiFi
being one and the same, the **A button has nothing to switch to and is a safe
no-op** (it just logs and returns; the watchdog is unaffected). B still shuts
down. To SSH into a board, put your laptop on the same phone hotspot and reach
the board at the IP the phone lists under connected devices. To bring A back
later, point `MAINT_WIFI_PROFILE` at a different network (e.g. a maintenance
router) -- no other change needed.

`config.HOTSPOT_PROFILE` must match the **connection name** (`phone-hotspot`),
not the SSID. These are different identifiers -- `nmcli con show` lists names.
The same applies to `config.MAINT_WIFI_PROFILE`.

Verify the gateway is discoverable (this is exactly what the node reads):

```bash
ip route show default
```

### 2.5 Maintenance WiFi

Confirm the profile name of the network you SSH over and put it in
`config.MAINT_WIFI_BY_USER`:

```bash
nmcli con show
```

This matters more than it used to. In work mode the node is on the phone's
hotspot, so with the phone switched off there is no other way in. Hold **A** for
3-6 s to swap to maintenance WiFi, hold it again to come back.

---

## 3. Buttons (all four unchanged)

| Key | BCM | Action |
|---|---|---|
| **X** | 16 | subject response: -10 dB, restarts the countdown |
| **Y** | 24 | subject response: +5 dB, restarts the countdown |
| **A** | 5 | hold 3-6 s: toggle work mode <-> maintenance WiFi |
| **B** | 6 | hold 3-6 s: shut down |

X/Y are handled by the node process; A/B by the root `power_button` service. The
two processes use different pins and do not conflict.

> Older Pirate Audio batches wire **Y to BCM 20** instead of 24. If Y does not
> respond, set `BUTTON_Y = BUTTON_Y_LEGACY` in `config.py`.

X/Y only act while a tone is playing. That guard reads `app_state['is_playing']`,
the single source of truth -- do not give any module its own copy of that flag.

---

## 4. Install the services

One command per board. Run it as that board's own login user (pi-node01 /
pi-node02) -- **not** with sudo. The script fills in User= and paths from
whoever runs it, installs both services, adds you to the gpio/audio groups, and
starts everything:

```bash
cd ~/HearingProj && bash install.sh
```

It prints the node id it detected (node01 on pi-node01, node02 on pi-node02),
so you can confirm the board mapped to the right identity.

> If it says you were just added to the gpio/audio groups, **reboot once**
> (`sudo reboot`) -- the buttons and sound card are not accessible until the new
> group membership takes effect.

The committed `systemd/*.service` files are the same units with a placeholder
User=; they are there for reference. `install.sh` is the supported path because
it fills in the per-board values for you.

Watch the logs:

```bash
journalctl -u hearing-node -f
```

A healthy start looks like:

```
[node] node01 (pi-zero-2w) starting, fw 2.0.0
Auto-selected device index=1
X button (GPIO16, -10dB) and Y button (GPIO24, +5dB) polling started.
[ws] connecting to ws://192.168.43.1:8765/ws
[ws] connected as node01
```

---

## 5. Testing without the phone app

`dev_server.py` stands in for the app. It speaks the same protocol and generates
seq the same way, so a node can be brought up before the app is on a device.

On a laptop:

```bash
pip install websockets
python3 dev_server.py
```

On the Pi, point it at that laptop (skips gateway discovery):

```bash
HEARING_WS_HOST=192.168.1.50 python3 node_client.py
```

Then at the dev server prompt:

```
nodes                       list what has registered
play node01 1000 30 both    play 1000 Hz at volume 30 on both ears
all 2000 40                 same tone on every node at once
stop node01
quit
```

## 5.1 Simulated node (no sound card, no GPIO)

`mock_node.py` reuses the entire network layer with a fake audio backend: it
simulates a subject making a few X/Y presses and then settling. Use it to
exercise registration, heartbeats, reconnect, several nodes at once and seq
correlation without tying up a real rig.

```bash
pip3 install websockets      # the only dependency it needs
python3 mock_node.py --node-id node09
```

---

## 6. Data

**The phone is the authority.** Every event is pushed to it over the WebSocket
and stored in SQLite; that is what the records screen shows and what CSV export
produces.

Each node also appends to `results.csv` next to its code. That is an **offline
backup**: it is the only record of anything that happened while the link was
down, because there is deliberately no store-and-forward replay. Columns:

```
NodeID, Timestamp, Frequency, Volume_dB, Volume_linear, Channel, Event, Remaining_s
```

`Event` is one of `play` / `X` / `Y` / `stop` / `end`. `Remaining_s` is how much
countdown was left when that level ended. The `end` row's `Volume_dB` is the
threshold.

Delete any pre-2.0 `results.csv` at deploy time -- the old format had a `BoardID`
column and no `Remaining_s`, and is not migrated.

---

## 7. Volume and dB

The phone sends `v` as 0-100 linear (the slider keeps its old meaning) and the
node converts it to dB on arrival. Everything after that point is dB:

- 0 dB = full scale, -80 dB = silence
- X = -10 dB, Y = +5 dB, clamped to that range
- records show dB only; the 0-100 value never appears in a result

These are **digital full-scale dB, not dB SPL** -- there is no acoustic
calibration. `config.REF_DB` is a documented placeholder for one.

---

## 8. Tuning

| Constant | Default | What it does |
|---|---|---|
| `TONE_DURATION` | 15.0 | the countdown, restarted by every X/Y press |
| `MAX_TONE_TOTAL_SEC` | 120.0 | hard ceiling a stuck button cannot push out |
| `RAMP_MS` | 0 | fade in/out length. 0 = current behaviour; set 10 if you hear a click at the stream edges |
| `HEARTBEAT_INTERVAL_S` | 5 | uplink heartbeat period |
| `RECONNECT_BASE_S` / `RECONNECT_MAX_S` | 1 / 30 | reconnect backoff bounds |

---

## 9. Troubleshooting

| Symptom | Check |
|---|---|
| `[ws] no default route` | The Pi is not on the hotspot. `nmcli con up phone-hotspot`, and confirm the hotspot is actually on. |
| Connects then drops every few seconds | The phone app was backgrounded without the foreground service running -- Android tore the socket down. |
| No sound, no error | Wrong output device. Run `test.py`; if no hifiberry line appears, the overlay in 2.1 is not applied. Also check the run user is in the `audio` group. |
| Y does not respond | Old Pirate Audio batch: set `BUTTON_Y = BUTTON_Y_LEGACY` (BCM 20). |
| X/Y do nothing | They only act while a tone is playing. Also check the run user is in the `gpio` group. |
| Click at the start/end of a tone | Set `RAMP_MS = 10`. |
| Can't SSH in | The node is on the phone's hotspot. Hold **A** for 3-6 s to switch to maintenance WiFi. |
| Node online but Play stays greyed | Waiting for `tone_done`. It clears itself after 120 s. |

---

## 10. What changed from the SoftAP version

| Then | Now |
|---|---|
| Boards ran their own hotspots (SoftAP / uap0 / hostapd) | The phone runs the hotspot; nodes are ordinary clients |
| Flask HTTP server on each board | WebSocket client on each node; the phone is the server |
| Phone connected TO a board | Nodes connect TO the phone |
| `relay.py` forwarded commands between boards | No forwarding; nodes never talk to each other |
| Data authoritative in each board's CSV | Data authoritative in the phone's SQLite; CSV is a backup |
| Tone ran a fixed 15 s | 15 s countdown, restarted by every X/Y press |
| One shared control panel, `targets` picked recipients | One control panel per node, each with its own parameters |

Removed files: `app.py`, `relay.py`, `install.sh`, `hearingproj-app.service`,
`hearingproj-hostapd.service`, `hearingproj-dnsmasq.service`.
New files: `node_client.py`, `audio.py`, `uplink.py`, `tone_clock.py`,
`mock_node.py`, `dev_server.py`, `hearing-node.service`.
