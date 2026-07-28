# tone_clock.py
"""The 15-second idle countdown that decides when a tone ends.

TONE_DURATION is not a fixed tone length. It is how long the tone keeps running
after the subject's last response-key press: every X/Y press calls reset() and
pushes the deadline back out. The tone ends when the countdown finally expires,
and the level the subject settled on is their threshold for that frequency.

Pure time arithmetic over app_state, with no audio or GPIO dependency, so the
bare-board mock node can share the same semantics without a sound card.
"""
import time

import config


def reset(app_state):
    """Restart the countdown. Called at tone start and on every X/Y press."""
    app_state['tone_deadline'] = time.monotonic() + config.TONE_DURATION


def remaining(app_state):
    """Seconds left, floored at 0.

    This is the value the phone shows in the 'remaining' column: how much
    countdown was left when a segment ended, i.e. how long that level had been
    held before the subject changed it.
    """
    return max(0.0, app_state.get('tone_deadline', 0.0) - time.monotonic())


def expired(app_state, hard_deadline=None):
    """Whether playback should stop now. hard_deadline is the MAX_TONE_TOTAL_SEC
    ceiling, which a stuck button cannot push out."""
    now = time.monotonic()
    if hard_deadline is not None and now >= hard_deadline:
        return True
    return now >= app_state.get('tone_deadline', 0.0)
