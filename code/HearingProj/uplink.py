# uplink.py
"""Outbound message queue: node -> phone.

Audio/GPIO threads drop plain dicts here rather than touching the asyncio
WebSocket loop directly; node_client drains the queue and ships them. Keeps
audio/button modules free of any network import. Every message automatically
carries type + node_id.
"""
import queue

import config

# Bounded so a dead link fills the queue instead of growing unbounded on a 512MB
# Pi; dropping is fine since the event is still on disk in this node's CSV backup.
MAX_PENDING = 200

_q = queue.Queue(maxsize=MAX_PENDING)


def send(msg_type, **fields):
    """Queue one uplink message. Never blocks, never raises."""
    msg = {"type": msg_type, "node_id": config.NODE_ID}
    msg.update(fields)
    try:
        _q.put_nowait(msg)
    except queue.Full:
        print(f"[uplink] queue full, dropped {msg_type}")


def get(timeout=None):
    """Pop one message, or None if nothing arrived within timeout seconds."""
    try:
        return _q.get(timeout=timeout)
    except queue.Empty:
        return None


def drain():
    """Discard everything pending. Called after a disconnect, since those
    messages describe an already-aborted tone."""
    dropped = 0
    while True:
        try:
            _q.get_nowait()
            dropped += 1
        except queue.Empty:
            break
    if dropped:
        print(f"[uplink] dropped {dropped} stale message(s) after disconnect")
    return dropped
