# uplink.py
"""Outbound message queue: node -> phone.

Why this module exists: audio playback and GPIO polling run in ordinary threads
(PyAudio writes are blocking), while the WebSocket link runs in an asyncio loop.
Rather than let those threads touch the event loop, they drop plain dicts in here
and node_client drains the queue and ships them. That also keeps the audio and
button modules free of any network import, which is what lets mock_node.py reuse
the whole network layer with a fake audio backend.

Every message automatically carries type + node_id, per the wire protocol.
"""
import queue

import config

# Bounded on purpose. If the link is down the queue fills and further messages are
# dropped rather than growing without limit on a 512 MB Pi Zero. Dropping is the
# correct behaviour here: there is no store-and-forward replay by design (the
# phone is the authority for live data), and this node's CSV backup still has the
# event on disk.
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
    """Discard everything pending. Called after a disconnect: those messages
    describe a tone that has already been aborted, so delivering them late would
    give the phone a false picture."""
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
