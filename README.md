# HearingProj — Portable Multi-User Hearing Screening System

A low-cost, portable **pure-tone hearing screening** system built around a
**star topology**: a phone is the hub, and one or more Raspberry Pi nodes are
dumb test terminals. One operator can run several subjects at the same time,
each on their own node, from a single phone app.

> ⚠️ **Disclaimer — research prototype, not a medical device.**
> This project is an engineering prototype for education and research. It has
> **not** been acoustically calibrated to dB SPL (levels are digital
> full-scale dB), and it is **not** a certified audiometer. Do not use it for
> clinical diagnosis or any medical decision.

---

## How a test works

1. On the phone app, the operator picks a **frequency / level / ear** for a
   node and presses **Play**.
2. The node plays a pure tone and starts a **15-second countdown**.
3. The subject presses the response buttons to converge on their own **minimum
   audible level** (one button steps the level **down**, the other steps it
   **up**). **Every press resets the countdown to 15 s**, so the subject can
   take as long as they need.
4. When the subject stops pressing and the countdown runs out, the level they
   settled on **is the hearing threshold** for that frequency.
5. The node reports the result; the phone stores it in SQLite and re-lights the
   Play button.

The countdown lives on the **node**, because only the node knows when a button
press last reset it. The phone never runs its own timer.

---

## Architecture

```
                Phone (Flutter app)
                ├─ System hotspot (turned on manually by the user)
                ├─ WebSocket server  0.0.0.0:8765/ws
                └─ SQLite  (single source of truth for results)
                     ▲        ▲        ▲
                     │        │        │   WebSocket (JSON text frames)
                  node01   node02   node03
                Pi Zero 2W  Pi Zero W   ...
                +PirateAudio +PirateAudio
```

- The phone is the **hub**; each node is a **WebSocket client** that dials in.
  **Nodes never talk to each other.**
- Nodes discover the phone by **reading the default route** — the phone's
  hotspot IP is never hard-coded (it varies by phone vendor / OS version).
- All three nodes run the **same code**; a node identifies itself
  automatically from its home-directory path (or a manual override).

This star design deliberately replaced an earlier P2P / relay approach. The
design constraints that must not be regressed are documented inline in the
source — see the module docstrings in `code/HearingProj/config.py` and
`node_client.py`.

---

## Repository structure

```
.
├── code/
│   ├── HearingProj/        # Raspberry Pi node firmware (Python)
│   │   ├── node_client.py      # main process: asyncio WebSocket client
│   │   ├── audio.py            # pure-tone generation & playback
│   │   ├── controls.py         # play / stop handling
│   │   ├── adjustments.py      # dB adjustment + threshold accounting
│   │   ├── button_handler.py   # physical response buttons (GPIO)
│   │   ├── tone_clock.py       # resettable 15-second countdown
│   │   ├── net.py              # hotspot connect / default-gateway discovery
│   │   ├── config.py           # all constants live here
│   │   ├── mock_node.py        # fake-audio node for testing on a bare board
│   │   ├── dev_server.py       # dev WebSocket server (stands in for the phone)
│   │   ├── systemd/            # service units for deployment
│   │   └── USAGE.md            # ★ node deployment guide
│   └── hearing_client/     # Flutter app (the phone hub)
│       └── lib/
│           ├── services/       # WebSocket server, DB, foreground service
│           ├── models/         # node session + record models
│           ├── widgets/        # node cards
│           └── screens/        # home + records screens
├── README.md
└── LICENSE
```

---

## Tech stack

| Side | Key pieces |
|---|---|
| Node (Raspberry Pi) | Python `asyncio` + `websockets`, `PyAudio` + `NumPy`, `RPi.GPIO`, NetworkManager (`nmcli`), `systemd` |
| Phone (app) | Flutter, `shelf_web_socket` (WS server), `sqflite` (storage), `flutter_foreground_task` (background keep-alive) |

Target hardware: **Raspberry Pi Zero W / Zero 2W** with a **Pirate Audio**
I2S DAC (PCM5102A) and its on-board buttons.

---

## Getting started

### Raspberry Pi node
Follow the step-by-step deployment guide:
[`code/HearingProj/USAGE.md`](code/HearingProj/USAGE.md). It covers the audio
overlay, NetworkManager hotspot profile, and the two `systemd` services.

> The phone's hotspot **must be 2.4 GHz + WPA2-PSK** — the Pi Zero has no 5 GHz
> radio, and WPA3 on the Zero W is unreliable.

### Phone app
```bash
cd code/hearing_client
flutter pub get
flutter run          # or: flutter build apk
```

### Develop / test without hardware
You can exercise the whole protocol on a dev machine — no Pi, no phone:

```bash
# terminal 1 — a WebSocket server that stands in for the phone
python code/HearingProj/dev_server.py

# terminal 2 — a fake-audio node
python code/HearingProj/mock_node.py --node-id node01
```

For the app: `flutter analyze` and `flutter test` (the test-assembler unit
tests cover the trickiest message-reassembly logic).

---

## Project status

- **Design & code:** complete; everything testable on a dev machine passes
  (protocol, reconnect, multi-node, `flutter analyze` / `flutter test`).
- **On real hardware:** single-node → dual-node → data round-trip validation is
  in progress.
- **Not done (by design, for now):** dB-SPL acoustic calibration,
  store-and-forward on disconnect, automated threshold-search algorithms.

---

## License

Released under the [MIT License](LICENSE) © 2026 Leon Wu.

Developed as a Master of Engineering (MEng) project, supervised by
Dr. Vijay Parsa.
