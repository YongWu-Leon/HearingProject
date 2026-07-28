# records.py
"""Local CSV event log -- OFFLINE BACKUP ONLY.

The authoritative record now lives in the phone's SQLite database: every event
written here is also pushed to the phone over the WebSocket link, and the phone is
what the operator reads and exports. This file exists so that data is not lost
while the link is down (there is no store-and-forward replay by design), and as a
field debugging aid.

Columns: NodeID, Timestamp, Frequency, Volume_dB, Volume_linear, Channel, Event, Remaining_s
Event in {play, X, Y, stop, end}
  play  playback started at the level the phone sent
  X / Y subject pressed a response key; Remaining_s is what was left on the
        countdown at that moment, i.e. how long that level had been held
  end   countdown expired -- this row's Volume_dB is the threshold result
  stop  operator stopped the tone early

Old-format files (which had a BoardID column and no Remaining_s) are not migrated;
delete any stale results.csv at deploy time.
"""
import csv
import os
import time

import config

_HEADER = ["NodeID", "Timestamp", "Frequency",
           "Volume_dB", "Volume_linear", "Channel", "Event", "Remaining_s"]


def log_event(app_state, event, remaining=None):
    """Append one event row to the CSV backup."""
    db = app_state.get("current_db", config.DEFAULT_DB)
    row = [
        config.NODE_ID,
        time.strftime("%Y-%m-%d %H:%M:%S"),
        app_state.get("current_frequency", 0),
        round(db, 2),
        round(config.db_to_linear(db), 5),
        app_state.get("current_ear", "both"),
        event,
        "" if remaining is None else round(remaining, 2),
    ]
    try:
        os.makedirs(os.path.dirname(config.DATA_FILE), exist_ok=True)
        file_exists = os.path.isfile(config.DATA_FILE)
        with open(config.DATA_FILE, mode="a", newline="") as f:
            writer = csv.writer(f)
            if not file_exists:
                writer.writerow(_HEADER)
            writer.writerow(row)
    except Exception as e:
        # A disk write failure must not break playback / button handling; just log it.
        print(f"[records] CSV write failed: {e}")


def read_all():
    """Return the whole CSV as text, or an empty string if there is none yet."""
    if not os.path.isfile(config.DATA_FILE):
        return ""
    try:
        with open(config.DATA_FILE, "r") as f:
            return f.read()
    except Exception as e:
        print(f"[records] CSV read failed: {e}")
        return ""


def clear():
    """Delete the local CSV backup. Returns True if a file was removed."""
    try:
        if os.path.isfile(config.DATA_FILE):
            os.remove(config.DATA_FILE)
            return True
        return False
    except Exception as e:
        print(f"[records] CSV delete failed: {e}")
        return False
