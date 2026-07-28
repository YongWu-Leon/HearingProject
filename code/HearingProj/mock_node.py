#!/usr/bin/env python3
# mock_node.py
"""Simulated node for a bare Pi (no Pirate Audio, no sound card, no GPIO).

Reuses the ENTIRE network layer from node_client -- registration, heartbeat,
command dispatch, uplink queue, exponential-backoff reconnect. Only the audio
backend is faked. That is the whole point of keeping the network layer free of
audio and GPIO imports: this file proves the split holds.

What it fakes:
  - play_tone -> emits tone_started, then simulates a subject hunting for their
    threshold: a few random X/Y presses 300-800 ms apart, each one emitting
    volume_changed and restarting the countdown, exactly as real buttons do.
  - the tone then ends when the countdown expires, emitting tone_done.

Use it to exercise registration, heartbeats, disconnect/reconnect, several nodes
at once and seq correlation without tying up a real test rig.

Run: python3 mock_node.py
Override the id so it does not collide with a real node:
    python3 mock_node.py --node-id node09
"""
import argparse
import asyncio
import random
import threading
import time

import config
import node_client
import records
import tone_clock
import uplink

# How many simulated response presses before the subject settles. Real subjects
# converge in a handful of presses; the range keeps sessions varied.
PRESSES_MIN = 2
PRESSES_MAX = 5
PRESS_GAP_MIN_S = 0.3
PRESS_GAP_MAX_S = 0.8


class MockPlayer:
    """Stand-in for audio.Player with the same start/stop/join surface."""

    def __init__(self, app_state):
        self._app_state = app_state
        self._thread = None

    def start(self, frequency, ear, seq):
        self._app_state['is_playing'] = False
        prev = self._thread
        if prev is not None and prev.is_alive():
            prev.join(timeout=2.0)
        t = threading.Thread(target=self._run, args=(frequency, ear, seq),
                             daemon=True)
        self._thread = t
        t.start()

    def stop(self):
        self._app_state['is_playing'] = False

    def join(self, timeout=2.0):
        if self._thread is not None and self._thread.is_alive():
            self._thread.join(timeout=timeout)

    # ---------- the fake "playback" ----------

    def _run(self, frequency, ear, seq):
        st = self._app_state
        st['is_playing'] = True
        st['current_frequency'] = frequency
        st['current_ear'] = ear
        st['seq'] = seq
        st['seg_db'] = st['current_db']
        st['seg_from'] = 'init'

        tone_clock.reset(st)
        hard_deadline = time.monotonic() + config.MAX_TONE_TOTAL_SEC

        records.log_event(st, "play", remaining=config.TONE_DURATION)
        uplink.send("tone_started", seq=seq, freq=frequency,
                    db=round(st['current_db'], 2), ear=ear)
        print(f"[mock] tone_started seq={seq} {frequency}Hz "
              f"{st['current_db']:.1f}dB ear={ear}")

        presses_left = random.randint(PRESSES_MIN, PRESSES_MAX)
        next_press_at = time.monotonic() + random.uniform(
            PRESS_GAP_MIN_S, PRESS_GAP_MAX_S)

        completed = False
        while st['is_playing']:
            now = time.monotonic()
            if tone_clock.expired(st, hard_deadline):
                completed = True
                break

            if presses_left > 0 and now >= next_press_at:
                # Bias towards X (quieter), which is what hunting for a threshold
                # from an audible starting level actually looks like.
                self._fake_press("X" if random.random() < 0.6 else "Y")
                presses_left -= 1
                next_press_at = time.monotonic() + random.uniform(
                    PRESS_GAP_MIN_S, PRESS_GAP_MAX_S)

            time.sleep(0.05)

        st['is_playing'] = False
        left = 0.0 if completed else tone_clock.remaining(st)
        reason = "completed" if completed else "stopped"
        records.log_event(st, "end" if completed else "stop", remaining=left)
        uplink.send("tone_done",
                    seq=seq,
                    reason=reason,
                    freq=frequency,
                    ear=ear,
                    final_db=round(st['current_db'], 2),
                    final_linear=round(config.db_to_linear(st['current_db']), 5),
                    seg_from=st.get('seg_from', 'init'),
                    seg_remaining_s=round(left, 2))
        print(f"[mock] tone_done seq={seq} {reason} "
              f"threshold={st['current_db']:.1f}dB")

    def _fake_press(self, source):
        """Same effect as a real X/Y press. adjustments is not imported here on
        purpose -- it is exercised on real hardware; duplicating the few lines
        keeps the mock runnable on a board with nothing installed but websockets."""
        st = self._app_state
        delta = config.DB_STEP_UP if source == "Y" else -config.DB_STEP_DOWN

        prev_db = st.get('seg_db', st['current_db'])
        prev_from = st.get('seg_from', 'init')
        left = tone_clock.remaining(st)

        new_db, at_floor, at_ceiling = config.clamp_db(st['current_db'] + delta)
        st['current_db'] = new_db
        st['seg_db'] = new_db
        st['seg_from'] = source
        tone_clock.reset(st)

        records.log_event(st, source, remaining=left)
        uplink.send("volume_changed",
                    seq=st.get('seq'),
                    button=source,
                    current_db=round(new_db, 2),
                    current_linear=round(config.db_to_linear(new_db), 5),
                    at_floor=at_floor,
                    at_ceiling=at_ceiling,
                    seg_db=round(prev_db, 2),
                    seg_from=prev_from,
                    seg_remaining_s=round(left, 2))
        print(f"[mock] {source} -> {new_db:+.1f} dB (held {left:.1f}s)")


def main():
    parser = argparse.ArgumentParser(description="Simulated hearing test node")
    parser.add_argument("--node-id", default=None,
                        help="override config.NODE_ID (e.g. node09) so a mock "
                             "does not collide with a real node")
    args = parser.parse_args()

    if args.node_id:
        config.NODE_ID = args.node_id
    config.HW_MODEL = "mock"
    config.AUDIO_BACKEND = "none"

    app_state = node_client.new_app_state()
    player = MockPlayer(app_state)
    client = node_client.NodeClient(app_state, player)

    print(f"[mock] {config.NODE_ID} starting (no audio, no GPIO)")
    try:
        asyncio.run(client.run())
    except KeyboardInterrupt:
        print("\n[mock] stopped.")
        player.stop()


if __name__ == '__main__':
    main()
