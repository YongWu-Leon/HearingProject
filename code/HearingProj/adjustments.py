# adjustments.py
"""dB volume adjustment -- the subject's response mechanism.

X = -10 dB, Y = +5 dB. Volume is tracked as app_state['current_db'], clamped to
[DB_FLOOR, DB_CEILING]. Changes take effect in real time on the tone that is
already playing, because the playback loop re-reads current_db every chunk.

This is how a test works: the subject presses X until the tone disappears and Y
until it comes back, converging on their quietest audible level. Each press also
restarts the 15 s countdown, so the tone keeps going while they hunt. When they
stop pressing, the countdown runs out and where they landed is the threshold.

Every press closes one "segment" and opens the next. A segment is one row in the
phone's records table: its level, how it was reached (init / X / Y), and how much
countdown was left when it ended.

The Flask route wrappers are gone (there is no HTTP control plane any more); this
is now called directly by button_handler, and by node_client if the phone ever
sends a volume command.
"""
import time

import config
import records
import tone_clock
import uplink


def apply_delta(app_state, delta, source):
    """Adjust current_db by delta, close the current segment, report it upstream.

    source is 'X' or 'Y' -- it becomes the row's colour in the phone's records
    view (X = lowered = light red, Y = raised = light green).
    Returns the new dB value.
    """
    # Node-clock stamp for this press, used for two latency measurements:
    #   - the phone converts it to its own clock (via the ping/pong offset) to get
    #     the one-way press-to-phone latency;
    #   - the audio loop subtracts it to get press-to-audible latency (see audio.py).
    # It is taken here rather than in button_handler, so it excludes the GPIO poll
    # interval; that part is bounded by config.POLL_INTERVAL and reported separately.
    press_ms = time.monotonic() * 1000.0
    app_state['db_change_at_ms'] = press_ms

    # Capture the segment that is ending BEFORE anything is mutated.
    prev_db = app_state.get('seg_db', app_state['current_db'])
    prev_from = app_state.get('seg_from', 'init')
    left = tone_clock.remaining(app_state) if app_state.get('is_playing') else 0.0

    new_db, at_floor, at_ceiling = config.clamp_db(app_state['current_db'] + delta)
    app_state['current_db'] = new_db
    linear = config.db_to_linear(new_db)

    # Open the new segment and restart the countdown so the tone keeps running.
    app_state['seg_db'] = new_db
    app_state['seg_from'] = source
    if app_state.get('is_playing'):
        tone_clock.reset(app_state)

    edge = ' [floor]' if at_floor else (' [ceiling]' if at_ceiling else '')
    print(f"[{source}] {new_db:+.1f} dB (linear {linear:.4f}){edge}")

    records.log_event(app_state, source, remaining=left)
    uplink.send("volume_changed",
                seq=app_state.get('seq'),
                button=source,
                current_db=round(new_db, 2),
                current_linear=round(linear, 5),
                at_floor=at_floor,
                at_ceiling=at_ceiling,
                # The segment that just closed = one row in the phone's records view.
                seg_db=round(prev_db, 2),
                seg_from=prev_from,
                seg_remaining_s=round(left, 2),
                t_node_ms=round(press_ms, 3))
    return new_db


def volume_up(app_state):
    """Y button: +5 dB."""
    return apply_delta(app_state, config.DB_STEP_UP, "Y")


def volume_down(app_state):
    """X button: -10 dB."""
    return apply_delta(app_state, -config.DB_STEP_DOWN, "X")
