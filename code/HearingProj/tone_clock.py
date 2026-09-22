# tone_clock.py
"""The idle countdown that decides when a tone ends.

TONE_DURATION is how long the tone keeps running after the subject's last
X/Y press; each press calls reset() to push the deadline back out. Pure time
arithmetic over app_state, no audio/GPIO dependency.
"""
import time

import config


def reset(app_state):
    """Restart the countdown. Called at tone start and on every X/Y press."""
    app_state['tone_deadline'] = time.monotonic() + config.TONE_DURATION


def remaining(app_state):
    """Seconds left, floored at 0."""
    return max(0.0, app_state.get('tone_deadline', 0.0) - time.monotonic())


def expired(app_state, hard_deadline=None):
    """Whether playback should stop now. hard_deadline is the MAX_TONE_TOTAL_SEC
    ceiling (a stuck button cannot push it out)."""
    now = time.monotonic()
    if hard_deadline is not None and now >= hard_deadline:
        return True
    return now >= app_state.get('tone_deadline', 0.0)
