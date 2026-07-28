# button_handler.py
"""Subject response buttons X and Y (Pirate Audio board buttons).

  X = GPIO16 short press: volume -10 dB
  Y = GPIO24 short press: volume +5 dB

These ARE the subject's response keys. The subject presses X until the tone
disappears and Y until it comes back, converging on their quietest audible level;
each press restarts the 15 s countdown so the tone keeps playing while they hunt.
Where they settle, once the countdown finally expires, is the threshold result.
See adjustments.apply_delta for what one press does.

Presses are ignored unless app_state['is_playing'] is true. That guard reads the
single source of truth in node_client -- no module keeps its own playback flag.
(A separate copy of that flag is what once produced phantom entries.)

Uses a polling thread (not GPIO interrupts): more reliable on older Pi Zero W
kernels, and lets rapid presses be handled one by one.

A and B are NOT handled here -- they belong to the separate root power_button
service (A = hold to switch network, B = hold to shut down). The two processes use
different pins and do not conflict.
"""
import threading
import time

import RPi.GPIO as GPIO

import adjustments
import config

DEBOUNCE_SEC = config.BUTTON_BOUNCETIME / 1000.0

_app_state = None


def init_button(app_state):
    """Initialise X / Y buttons and start the polling thread."""
    global _app_state
    _app_state = app_state

    try:
        GPIO.setwarnings(False)
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(config.BUTTON_Y, GPIO.IN, pull_up_down=GPIO.PUD_UP)
        GPIO.setup(config.BUTTON_X, GPIO.IN, pull_up_down=GPIO.PUD_UP)
        print(f"X button (GPIO{config.BUTTON_X}, -10dB) and "
              f"Y button (GPIO{config.BUTTON_Y}, +5dB) polling started.")
    except Exception as e:
        print(f"Warning: GPIO init failed: {e}. X/Y buttons disabled.")
        return False

    threading.Thread(target=_poll_loop, daemon=True).start()
    return True


def _fire(delta, event):
    """One debounced press: only acts while a tone is actually playing."""
    if _app_state is None:
        return
    if not _app_state.get('is_playing'):
        # Nothing is playing, so there is no segment to close and no countdown to
        # restart. Silently ignore rather than logging a phantom row.
        return
    adjustments.apply_delta(_app_state, delta, event)


def _poll_loop():
    """Poll X / Y; fire on the debounced rising edge (on release)."""
    y_last = GPIO.HIGH
    x_last = GPIO.HIGH
    y_down_at = 0.0
    x_down_at = 0.0

    while True:
        try:
            y_now = GPIO.input(config.BUTTON_Y)
            x_now = GPIO.input(config.BUTTON_X)

            if y_last == GPIO.HIGH and y_now == GPIO.LOW:
                y_down_at = time.time()
            elif y_last == GPIO.LOW and y_now == GPIO.HIGH:
                if time.time() - y_down_at >= DEBOUNCE_SEC / 2:
                    _fire(config.DB_STEP_UP, "Y")       # Y: +5 dB

            if x_last == GPIO.HIGH and x_now == GPIO.LOW:
                x_down_at = time.time()
            elif x_last == GPIO.LOW and x_now == GPIO.HIGH:
                if time.time() - x_down_at >= DEBOUNCE_SEC / 2:
                    _fire(-config.DB_STEP_DOWN, "X")    # X: -10 dB

            y_last = y_now
            x_last = x_now
        except Exception:
            pass

        time.sleep(config.POLL_INTERVAL)
