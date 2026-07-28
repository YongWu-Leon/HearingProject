#!/usr/bin/env python3
# node_client.py
"""Node process: a WebSocket client that reports to the phone.

This replaces the Flask app. The direction of the link is inverted from the old
design: the phone used to connect to a board's HTTP server, and now the phone runs
the server and every node dials it. Nodes never talk to each other.

Lifecycle:
  1. read the default gateway (= the phone, on its own hotspot) -- never hardcoded
  2. connect ws://<gateway>:8765/ws
  3. send register
  4. send heartbeat every HEARTBEAT_INTERVAL_S
  5. dispatch downlink commands (play_tone / stop / ping) to the audio layer
  6. ship uplink events (tone_started / volume_changed / tone_done / error)

On disconnect: playback is aborted immediately and the pending uplink queue is
dropped, so a lost link can never leave an orphaned tone playing at an unknown
level. Reconnect uses exponential backoff with jitter (jitter matters: without it
three nodes that lost the same hotspot would retry in lockstep forever).

The network layer here is deliberately free of any audio or GPIO import -- that is
what lets mock_node.py reuse all of it with a fake audio backend on a bare board.

Run: python3 node_client.py
"""
import asyncio
import json
import random

import websockets

try:                                                    # websockets >= 13
    from websockets.asyncio.client import connect as ws_connect
except ImportError:                                     # older releases
    ws_connect = websockets.connect

import config
import controls
import net
import tone_clock
import uplink


def new_app_state():
    """The single source of truth for playback state.

    Every module reads this by reference; only the playback control path writes
    is_playing. No module keeps its own copy -- an independent flag is what once
    produced phantom entries.
    """
    return {
        'is_playing': False,
        'current_db': config.DEFAULT_DB,
        'current_frequency': config.DEFAULT_FREQUENCY,
        'current_ear': 'both',
        'seq': None,
        'tone_deadline': 0.0,
        'seg_db': config.DEFAULT_DB,
        'seg_from': 'init',
    }


class NodeClient:
    """Owns the WebSocket link. `player` only has to provide start/stop/join."""

    def __init__(self, app_state, player):
        self.app_state = app_state
        self.player = player
        self._fail_streak = 0

    # ---------- connection loop ----------

    async def run(self):
        attempt = 0
        while True:
            gateway = config.WS_HOST_OVERRIDE or net.default_gateway()
            if gateway is None:
                print("[ws] no default route -- not joined to the phone hotspot yet")
                await self._backoff_sleep(attempt)
                attempt = min(attempt + 1, 10)
                self._note_failure()
                continue

            url = f"ws://{gateway}:{config.WS_PORT}{config.WS_PATH}"
            try:
                print(f"[ws] connecting to {url}")
                async with ws_connect(
                    url,
                    open_timeout=config.WS_OPEN_TIMEOUT_S,
                    ping_interval=config.WS_PING_INTERVAL_S,
                    ping_timeout=config.WS_PING_TIMEOUT_S,
                ) as ws:
                    print(f"[ws] connected as {config.NODE_ID}")
                    attempt = 0
                    self._fail_streak = 0
                    await self._session(ws)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                print(f"[ws] link lost: {type(e).__name__}: {e}")
                self._note_failure()

            # A dropped link must never leave a tone playing at an unknown level.
            self._abort_playback()
            await self._backoff_sleep(attempt)
            attempt = min(attempt + 1, 10)

    async def _session(self, ws):
        """One connected session: register, then run the three pumps until any
        of them ends (which means the link died)."""
        await ws.send(json.dumps({
            "type": "register",
            "node_id": config.NODE_ID,
            "hw": config.HW_MODEL,
            "audio": config.AUDIO_BACKEND,
            "fw_version": config.FW_VERSION,
        }))

        tasks = [
            asyncio.ensure_future(self._recv_loop(ws)),
            asyncio.ensure_future(self._send_loop(ws)),
            asyncio.ensure_future(self._heartbeat_loop()),
        ]
        try:
            done, pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_COMPLETED)
            for t in done:
                exc = t.exception()
                if exc is not None:
                    raise exc
        finally:
            for t in tasks:
                t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    # ---------- pumps ----------

    async def _recv_loop(self, ws):
        loop = asyncio.get_event_loop()
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except (ValueError, TypeError):
                print(f"[ws] ignoring non-JSON frame: {raw!r:.120}")
                continue
            if not isinstance(msg, dict):
                print(f"[ws] ignoring non-object frame: {msg!r:.120}")
                continue

            mtype = msg.get("type")
            if mtype == "play_tone":
                # Runs in a worker thread: handle_play joins the previous playback
                # thread, which must never block the event loop.
                await loop.run_in_executor(
                    None, controls.handle_play, self.app_state, self.player, msg)
            elif mtype == "stop":
                await loop.run_in_executor(
                    None, controls.handle_stop, self.app_state, self.player, msg)
            elif mtype == "ping":
                self._queue_heartbeat()
            else:
                # An unknown type must be ignored, not fatal: the phone may be a
                # newer build than this node.
                print(f"[ws] unknown message type {mtype!r}, ignored")

    async def _send_loop(self, ws):
        """Drain the thread-side uplink queue into the socket.

        uplink.get blocks, so it runs in an executor with a short timeout rather
        than stalling the event loop.
        """
        loop = asyncio.get_event_loop()
        while True:
            msg = await loop.run_in_executor(None, uplink.get, 0.25)
            if msg is not None:
                await ws.send(json.dumps(msg))

    async def _heartbeat_loop(self):
        while True:
            self._queue_heartbeat()
            await asyncio.sleep(config.HEARTBEAT_INTERVAL_S)

    def _queue_heartbeat(self):
        st = self.app_state
        playing = bool(st.get('is_playing'))
        uplink.send("heartbeat",
                    state="PLAYING" if playing else "IDLE",
                    seq=st.get('seq'),
                    freq=st.get('current_frequency'),
                    current_db=round(st.get('current_db', config.DEFAULT_DB), 2),
                    ear=st.get('current_ear', 'both'),
                    remaining_s=round(tone_clock.remaining(st), 2) if playing else 0.0)

    # ---------- disconnect handling ----------

    def _abort_playback(self):
        if self.app_state.get('is_playing'):
            print("[ws] aborting playback after link loss")
            self.player.stop()
            self.player.join()
        # Whatever is still queued describes a tone that no longer exists.
        uplink.drain()

    def _note_failure(self):
        self._fail_streak += 1
        if self._fail_streak == config.RECONNECT_NET_RETRY_AFTER:
            # Repairing a dropped WiFi association needs root (nmcli), which this
            # process does not have. The power_button service runs as root and its
            # watchdog rejoins the hotspot; all this process can do is say so.
            print(f"[ws] {self._fail_streak} failed attempts -- the WiFi link to "
                  f"the phone is probably down. Waiting for the power_button "
                  f"watchdog to rejoin '{config.HOTSPOT_PROFILE}'.")

    async def _backoff_sleep(self, attempt):
        delay = min(config.RECONNECT_BASE_S * (2 ** attempt), config.RECONNECT_MAX_S)
        spread = delay * config.RECONNECT_JITTER
        delay = max(0.5, delay + random.uniform(-spread, spread))
        print(f"[ws] reconnecting in {delay:.1f}s")
        await asyncio.sleep(delay)


def main():
    # Hardware modules are imported here, not at module scope, so that mock_node.py
    # can import this file on a board with no sound card and no GPIO access.
    import audio
    import button_handler

    app_state = new_app_state()
    player = audio.Player(app_state)
    button_handler.init_button(app_state)

    client = NodeClient(app_state, player)
    print(f"[node] {config.NODE_ID} ({config.HW_MODEL}) starting, "
          f"fw {config.FW_VERSION}")
    try:
        asyncio.run(client.run())
    except KeyboardInterrupt:
        print("\n[node] stopped.")
        player.stop()


if __name__ == '__main__':
    main()
