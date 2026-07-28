#!/usr/bin/env python3
# dev_server.py
"""Development WebSocket server -- stands in for the phone app.

Runs on a laptop so the nodes can be brought up and tested before the Flutter app
exists, and so node-side problems can be diagnosed without a phone in the loop.
It speaks exactly the same protocol as the app: same message types, same seq
ownership (this server generates seq, the nodes echo it back).

NOT part of the deployment. Nothing on a Pi imports this.

    pip install websockets
    python3 dev_server.py

Then point the nodes at this machine. The nodes dial their default gateway, so
either run this on the machine that is the gateway, or start a node with the
gateway overridden for a quick test:

    HEARING_WS_HOST=192.168.1.50 python3 node_client.py

Commands (typed at the prompt):
    nodes                       list connected nodes
    play <node> [f] [v] [ear]   e.g. play node01 1000 30 both
    stop <node>                 stop that node
    all <f> [v] [ear]           play the same tone on every node at once
    ping <node>
    quit
"""
import asyncio
import json
import sys
from datetime import datetime

import websockets

try:                                                    # websockets >= 13
    from websockets.asyncio.server import serve as ws_serve
except ImportError:                                     # older releases
    ws_serve = websockets.serve

HOST = "0.0.0.0"
PORT = 8765
PATH = "/ws"

# node_id -> {"ws": connection, "state": str, "info": dict}
NODES = {}
# The phone owns seq; so does this stand-in. Monotonic, never reused.
_seq = 0


def next_seq():
    global _seq
    _seq += 1
    return _seq


def ts():
    return datetime.now().strftime("%H:%M:%S")


def show(msg):
    """Print one uplink message in a form that mirrors what the app would store."""
    t = msg.get("type")
    node = msg.get("node_id", "?")

    if t == "register":
        print(f"[{ts()}] {node} REGISTERED  hw={msg.get('hw')} "
              f"audio={msg.get('audio')} fw={msg.get('fw_version')}")
    elif t == "heartbeat":
        return                                   # too chatty to print every 5 s
    elif t == "tone_started":
        print(f"[{ts()}] {node} seq={msg.get('seq')} STARTED  "
              f"{msg.get('freq')}Hz {msg.get('db')}dB ear={msg.get('ear')}")
    elif t == "volume_changed":
        # seg_* describes the segment that just closed = one row in the app's
        # records table (init = white, X = light red, Y = light green).
        print(f"[{ts()}] {node} seq={msg.get('seq')} {msg.get('button')}  "
              f"-> {msg.get('current_db')}dB   "
              f"[row: {msg.get('seg_db')}dB from={msg.get('seg_from')} "
              f"held-remaining={msg.get('seg_remaining_s')}s]")
    elif t == "tone_done":
        print(f"[{ts()}] {node} seq={msg.get('seq')} DONE ({msg.get('reason')})  "
              f"THRESHOLD={msg.get('final_db')}dB @ {msg.get('freq')}Hz "
              f"ear={msg.get('ear')}")
    elif t == "error":
        print(f"[{ts()}] {node} ERROR {msg.get('code')}: {msg.get('detail')}")
    else:
        print(f"[{ts()}] {node} {t}: {msg}")


async def handler(ws, path=None):
    """One connected node. (websockets >= 13 calls the handler with one argument;
    older releases pass the path too, hence the default.)"""
    node_id = None
    peer = getattr(ws, "remote_address", None)
    print(f"[{ts()}] connection opened from {peer}")
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except ValueError:
                print(f"[{ts()}] non-JSON frame ignored: {raw!r:.100}")
                continue
            if not isinstance(msg, dict):
                continue

            if msg.get("type") == "register":
                node_id = msg.get("node_id")
                NODES[node_id] = {"ws": ws, "state": "IDLE", "info": msg}
            elif node_id and msg.get("type") == "heartbeat":
                NODES[node_id]["state"] = msg.get("state", "?")
            show(msg)
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        if node_id and NODES.get(node_id, {}).get("ws") is ws:
            del NODES[node_id]
        print(f"[{ts()}] connection closed ({node_id or peer})")


async def send_to(node_id, payload):
    entry = NODES.get(node_id)
    if entry is None:
        print(f"  no such node: {node_id} (connected: {', '.join(NODES) or 'none'})")
        return False
    try:
        await entry["ws"].send(json.dumps(payload))
        return True
    except Exception as e:
        print(f"  send to {node_id} failed: {e}")
        return False


async def console():
    """Read commands from stdin without blocking the event loop."""
    loop = asyncio.get_event_loop()
    print("commands: nodes | play <node> [f] [v] [ear] | all <f> [v] [ear] | "
          "stop <node> | ping <node> | quit\n")
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            await asyncio.sleep(0.2)
            continue
        parts = line.split()
        if not parts:
            continue
        cmd = parts[0].lower()

        if cmd in ("quit", "exit"):
            print("bye")
            loop.stop()
            return

        if cmd == "nodes":
            if not NODES:
                print("  (none connected)")
            for nid, e in NODES.items():
                print(f"  {nid:10s} {e['state']:8s} {e['info'].get('hw', '?')}")

        elif cmd == "play" and len(parts) >= 2:
            seq = next_seq()
            await send_to(parts[1], {
                "type": "play_tone",
                "seq": seq,
                "f": float(parts[2]) if len(parts) > 2 else 1000.0,
                "v": float(parts[3]) if len(parts) > 3 else 30.0,
                "ear": parts[4] if len(parts) > 4 else "both",
            })
            print(f"  -> play_tone seq={seq}")

        elif cmd == "all" and len(parts) >= 2:
            for nid in list(NODES):
                seq = next_seq()
                await send_to(nid, {
                    "type": "play_tone",
                    "seq": seq,
                    "f": float(parts[1]),
                    "v": float(parts[2]) if len(parts) > 2 else 30.0,
                    "ear": parts[3] if len(parts) > 3 else "both",
                })
                print(f"  -> {nid} play_tone seq={seq}")

        elif cmd == "stop" and len(parts) >= 2:
            await send_to(parts[1], {"type": "stop", "seq": _seq})

        elif cmd == "ping" and len(parts) >= 2:
            await send_to(parts[1], {"type": "ping"})

        else:
            print("  commands: nodes | play <node> [f] [v] [ear] | "
                  "all <f> [v] [ear] | stop <node> | ping <node> | quit")


async def main():
    async with ws_serve(handler, HOST, PORT):
        print(f"dev server listening on ws://{HOST}:{PORT}{PATH}")
        print("waiting for nodes to register...\n")
        await console()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, RuntimeError):
        pass
