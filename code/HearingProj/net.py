# net.py
"""Network layer: join the phone's hotspot, or switch to maintenance WiFi.

This replaces the old SoftAP topology entirely. Nodes no longer run an access
point, a uap0 virtual interface, hostapd or dnsmasq -- the phone provides the
hotspot and every node is an ordinary WiFi client of it.

Two modes, toggled by holding the A button (unchanged behaviour, see power_button):
  work  -> joined to the phone's hotspot (config.HOTSPOT_PROFILE). This is what
           the node boots into and what testing runs on.
  maint -> joined to the maintenance WiFi (config.MAINT_WIFI_PROFILE), for SSH.
           This matters more than it used to: in work mode the node is on the
           phone's hotspot, so without the phone present there is no other way in.

NOTE: HOTSPOT_PROFILE and MAINT_WIFI_PROFILE are NetworkManager connection profile
NAMES, not SSIDs. The two are different identifiers -- `nmcli con show` lists the
names. Both profiles are created once at deploy time (see USAGE.md); this module
only brings them up and down.

WARNING: every nmcli path here requires real-hardware verification -- none of it
can be exercised on a development machine.
"""
import socket
import struct
import subprocess

import config


def _run(args, check=False):
    """Run one command; with check=True print a warning on failure."""
    r = subprocess.run(args, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"[net] command failed ({r.returncode}): {' '.join(args)}\n      {r.stderr.strip()}")
    return r


def _con_exists(name):
    return name in _run(["nmcli", "-t", "-f", "NAME", "con", "show"]).stdout.split("\n")


def _con_active(name):
    return name in _run(["nmcli", "-t", "-f", "NAME", "con", "show", "--active"]).stdout.split("\n")


# ---------- default gateway discovery ----------

def default_gateway():
    """IP of the default gateway, i.e. the phone when joined to its hotspot.

    The phone's address is deliberately NOT hardcoded (it is not always
    192.168.43.1 -- it varies by vendor and Android version). Reads /proc/net/route
    directly, which needs no external process; falls back to parsing `ip route`.
    Returns None when there is no default route, which means the WiFi link is down.
    """
    try:
        with open("/proc/net/route") as f:
            next(f)                                  # skip the header line
            for line in f:
                parts = line.strip().split()
                if len(parts) < 3:
                    continue
                iface, dest, gateway, flags = parts[0], parts[1], parts[2], parts[3]
                # dest 00000000 = default route; flag 0x2 = RTF_GATEWAY
                if dest != "00000000" or not int(flags, 16) & 0x2:
                    continue
                # The field is a little-endian hex u32.
                return socket.inet_ntoa(struct.pack("<L", int(gateway, 16)))
    except Exception as e:
        print(f"[net] /proc/net/route read failed ({e}); falling back to `ip route`")

    try:
        out = _run(["ip", "route", "show", "default"]).stdout.split()
        if "via" in out:
            return out[out.index("via") + 1]
    except Exception as e:
        print(f"[net] `ip route` parse failed: {e}")
    return None


def gateway_reachable(timeout=None):
    """Ping the default gateway once. Used by the watchdog to tell a dropped
    hotspot (which needs an nmcli reconnect) from a merely closed socket."""
    gw = default_gateway()
    if gw is None:
        return False
    timeout = timeout or config.GATEWAY_PROBE_TIMEOUT
    r = _run(["ping", "-c", "1", "-W", str(int(timeout)), gw])
    return r.returncode == 0


# ---------- work mode: the phone's hotspot ----------

def up_work():
    """Bring up the connection to the phone's hotspot."""
    if not _con_exists(config.HOTSPOT_PROFILE):
        print(f"[net] connection profile '{config.HOTSPOT_PROFILE}' does not exist. "
              f"Create it once with nmcli -- see USAGE.md.")
        return False
    return _run(["sudo", "nmcli", "con", "up", config.HOTSPOT_PROFILE],
                check=True).returncode == 0


def down_work():
    _run(["sudo", "nmcli", "con", "down", config.HOTSPOT_PROFILE])


def work_is_active():
    return _con_active(config.HOTSPOT_PROFILE)


def ensure_work_mode():
    """Call on boot / when switching back to work mode: make sure the node is on
    the phone's hotspot. Idempotent."""
    if work_is_active() and default_gateway() is not None:
        return True
    ok = up_work()
    print(f"[net] work mode {'established' if ok else 'FAILED'} "
          f"(node {config.NODE_ID}, profile {config.HOTSPOT_PROFILE})")
    return ok


# ---------- maintenance WiFi (A button) ----------

def to_maintenance():
    """Switch to maintenance WiFi (for SSH)."""
    print(f"[net] switching to maintenance WiFi: {config.MAINT_WIFI_PROFILE}")
    down_work()
    for attempt in range(3):
        if _run(["sudo", "nmcli", "con", "up", config.MAINT_WIFI_PROFILE]).returncode == 0:
            print("[net] connected to maintenance WiFi.")
            return True
        print(f"[net] attempt {attempt + 1} failed, retrying...")
    print("[net] failed to connect to maintenance WiFi.")
    return False


def to_work():
    """Switch from maintenance WiFi back to work mode."""
    _run(["sudo", "nmcli", "con", "down", config.MAINT_WIFI_PROFILE])
    return ensure_work_mode()


# ---------- watchdog helper ----------

def reconnect_hotspot():
    """Rejoin the phone's hotspot after a drop. Rescans first, because the phone
    may have been switched off and back on while the node kept a stale scan list."""
    _run(["sudo", "nmcli", "dev", "wifi", "rescan"])
    if _run(["sudo", "nmcli", "con", "up", config.HOTSPOT_PROFILE]).returncode == 0:
        print("[net] rejoined the phone hotspot.")
        return True
    return False
