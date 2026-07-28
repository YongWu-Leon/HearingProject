#!/usr/bin/env python3
# power_button.py
"""Power / network daemon (runs as root, independent of the node client).

  B button (GPIO6), hold 3-6s: shut down
  A button (GPIO5), hold 3-6s: toggle between work mode (joined to the phone's
                               hotspot) and maintenance WiFi

Both buttons keep exactly the behaviour they always had. What changed underneath
is only what "work mode" means: it used to raise this board's own SoftAP, and now
it joins the phone's hotspot (see net.py). Holding A to reach the maintenance WiFi
matters more than before -- in work mode the node is on the phone's hotspot, so
without the phone powered on there is no other way to SSH in.

Also runs a link watchdog in a background thread: it pings the default gateway
(the phone) every HEARTBEAT_INTERVAL seconds and, after HEARTBEAT_FAIL_THRESHOLD
consecutive failures, rejoins the hotspot with nmcli. The WebSocket layer in
node_client does its own exponential-backoff reconnect, but a socket cannot repair
a dropped WiFi association -- that needs root, which is why it lives here.

Reason for a separate service: even if the node client crashes, shutdown, network
switching and the watchdog stay available, so the device never becomes
unreachable. The two processes use different GPIO pins (A/B vs X/Y) and do not
conflict.

WARNING: network commands require real-hardware verification (see net.py).
"""
import threading
import time
import os

import RPi.GPIO as GPIO

import config
import net

# Current network mode: 'work' (phone hotspot) or 'maint' (maintenance WiFi)
network_mode = "work"


# ---------- A button: network switch ----------

def toggle_network():
    global network_mode
    # If the work hotspot and the maintenance WiFi are the SAME network (a
    # single-network setup: the phone hotspot is also where you SSH from), there
    # is nothing to switch between. Toggling would drop and re-raise the same
    # connection AND flip network_mode to "maint", which pauses the watchdog --
    # so an accidental long-press would quietly stop the link from self-healing.
    # Treat A as a safe no-op instead. Point MAINT_WIFI_PROFILE at a different
    # network and A wakes back up on its own, no code change.
    if config.HOTSPOT_PROFILE == config.MAINT_WIFI_PROFILE:
        print("[net] A held, but the work hotspot and maintenance WiFi are the "
              "same network -- nothing to switch to, ignoring.")
        return
    if network_mode == "work":
        if net.to_maintenance():
            network_mode = "maint"
    else:
        net.to_work()
        network_mode = "work"


# ---------- long-press detection ----------

def wait_for_long_press(pin):
    """Return True if the hold time is within [LONG_PRESS_SEC, LONG_PRESS_MAX_SEC].
    Too short = accidental; too long = unintended -- both return False.
    """
    press_start = time.time()
    timed_out = False
    while GPIO.input(pin) == GPIO.LOW:
        if time.time() - press_start >= config.LONG_PRESS_MAX_SEC:
            timed_out = True
            while GPIO.input(pin) == GPIO.LOW:   # wait for release
                time.sleep(config.POLL_INTERVAL)
            break
        time.sleep(config.POLL_INTERVAL)
    if timed_out:
        return False
    return (time.time() - press_start) > config.LONG_PRESS_SEC


# ---------- link watchdog thread ----------

def _watchdog_loop():
    fails = 0

    while True:
        # Only maintain the work-mode link WHILE in work mode. In maintenance
        # (SSH) mode we must leave the radio completely alone -- otherwise the
        # reconnect below would drag the node back onto the phone's hotspot and
        # drop the SSH session (single radio).
        if network_mode != "work":
            fails = 0
            time.sleep(config.HEARTBEAT_INTERVAL)
            continue

        if net.gateway_reachable():
            fails = 0
        else:
            fails += 1
            print(f"[watchdog] gateway unreachable {fails}/{config.HEARTBEAT_FAIL_THRESHOLD}")
            if fails >= config.HEARTBEAT_FAIL_THRESHOLD:
                _do_reconnect()
                fails = 0

        time.sleep(config.HEARTBEAT_INTERVAL)


def _do_reconnect():
    """Hotspot drop: if all WATCHDOG_RETRY_ROUNDS rounds fail, sleep WATCHDOG_SLEEP
    seconds before the loop tries again (the phone may simply be switched off)."""
    for rnd in range(config.WATCHDOG_RETRY_ROUNDS):
        print(f"[watchdog] hotspot reconnect round {rnd + 1}...")
        try:
            if net.reconnect_hotspot():
                return
        except Exception as e:
            print(f"[watchdog] reconnect error: {e}")
        time.sleep(2)
    print(f"[watchdog] reconnect failed, sleeping {config.WATCHDOG_SLEEP}s before retrying.")
    time.sleep(config.WATCHDOG_SLEEP)


# ---------- main loop ----------

def main():
    GPIO.setwarnings(False)
    GPIO.setmode(GPIO.BCM)
    try:
        GPIO.setup(config.BUTTON_B, GPIO.IN, pull_up_down=GPIO.PUD_UP)
        GPIO.setup(config.BUTTON_A, GPIO.IN, pull_up_down=GPIO.PUD_UP)
        print(f"B=GPIO{config.BUTTON_B}(hold {config.LONG_PRESS_SEC}-{config.LONG_PRESS_MAX_SEC}s shutdown), "
              f"A=GPIO{config.BUTTON_A}(hold to toggle network)")
    except Exception as e:
        print(f"Warning: GPIO init failed: {e}. A/B buttons disabled.")

    # Join the phone's hotspot on boot
    try:
        net.ensure_work_mode()
    except Exception as e:
        print(f"[net] failed to establish work mode on boot (verify on hardware): {e}")

    # Start the link watchdog
    threading.Thread(target=_watchdog_loop, daemon=True).start()

    try:
        while True:
            if GPIO.input(config.BUTTON_B) == GPIO.LOW:
                if wait_for_long_press(config.BUTTON_B):
                    print("Shutting down...")
                    GPIO.cleanup()
                    os.system("sudo shutdown -h now")
                    return

            if GPIO.input(config.BUTTON_A) == GPIO.LOW:
                if wait_for_long_press(config.BUTTON_A):
                    print("Toggling network...")
                    toggle_network()

            time.sleep(config.POLL_INTERVAL)

    except KeyboardInterrupt:
        print("power_button.py stopped.")
    finally:
        GPIO.cleanup()


if __name__ == '__main__':
    main()
