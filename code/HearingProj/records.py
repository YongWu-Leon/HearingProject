# records.py
"""Local CSV event log -- OFFLINE BACKUP ONLY. The phone's SQLite database is
the authoritative record; this file guards against data loss while the link
is down and serves as a field debugging aid.

Columns: NodeID, Timestamp, Frequency, Volume_dB, Volume_linear, Channel, Event, Remaining_s
Event in {play, X, Y, stop, end}: play=started, X/Y=response key press
(Remaining_s = countdown left when pressed), end=countdown expired (threshold
result), stop=operator stopped early.
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
        # Must not break playback/button handling on a write failure.
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
