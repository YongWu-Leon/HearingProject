# controls.py
"""Playback command handlers (play / stop).

These used to be Flask routes with a relay fan-out to peer boards. In the star
topology there are no peers and no HTTP control plane: the phone addresses each
node directly over its own WebSocket, so a command only ever means "do this here".
The thread-switching logic is unchanged -- see audio.Player, which joins the old
playback thread before starting a new one rather than sleeping a fixed interval.

The phone still sends v as 0-100 linear (the volume slider keeps its old
semantics); the conversion to dB happens here, at the entry point, exactly as the
old /play endpoint did.
"""
import config
import uplink


def handle_play(app_state, player, msg):
    """play_tone command: {seq, f, ear, level_db | v}.

    Level can arrive two ways, checked in this order:
      level_db  the phone's dB value, used as-is (current app -- volume is dB now)
      v         legacy 0-100 linear, converted to dB (kept for compatibility)
      neither   keep whatever level the subject had dialled in
    f defaults to the current frequency, ear to both.
    """
    seq = msg.get('seq')
    # Log the command as received. When a level fails to arrive the node falls
    # back to its own default, which looks identical to the phone having asked
    # for that default -- so the raw message is the only way to tell them apart.
    print(f"play_tone in: {msg}")

    try:
        f = float(msg.get('f', app_state['current_frequency']))
    except (TypeError, ValueError):
        f = app_state['current_frequency']
    if f <= 0:
        uplink.send("error", code="BAD_FREQUENCY", detail=f"f={msg.get('f')!r}", seq=seq)
        return

    if msg.get('level_db') is not None:
        try:
            db, _, _ = config.clamp_db(float(msg['level_db']))
        except (TypeError, ValueError):
            uplink.send("error", code="BAD_LEVEL", detail=f"level_db={msg.get('level_db')!r}", seq=seq)
            return
    elif msg.get('v') is not None:
        try:
            db, _, _ = config.clamp_db(config.linear_to_db(float(msg['v']) / 100.0))
        except (TypeError, ValueError):
            uplink.send("error", code="BAD_VOLUME", detail=f"v={msg.get('v')!r}", seq=seq)
            return
    else:
        db = app_state['current_db']

    ear = str(msg.get('ear', 'both'))
    if ear not in ('L', 'left', 'R', 'right', 'both'):
        ear = 'both'

    app_state['current_db'] = db
    print(f"Play -> {f}Hz, {db:.1f}dB, ear={ear}, seq={seq}")
    player.start(f, ear, seq)


def handle_stop(app_state, player, msg=None):
    """stop command. The playback thread emits tone_done with reason='stopped'
    as it unwinds, so nothing is reported from here."""
    if not app_state.get('is_playing'):
        return
    print("Stop.")
    player.stop()
