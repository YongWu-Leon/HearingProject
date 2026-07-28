# audio.py
"""Pure-tone generation and playback (moved out of the old Flask app.py).

The generation core is unchanged from the Flask version: tones are built ONE CHUNK
AT A TIME from an absolute sample index, so phase stays continuous across chunk
boundaries. Never go back to pre-generating a whole buffer -- that is what caused
clicks at the boundaries.

What DID change is when playback stops. It used to run a fixed 15 s of samples.
Now 15 s is a COUNTDOWN: the loop runs until app_state['tone_deadline'] passes,
and every X/Y press pushes that deadline back out to now + TONE_DURATION (see
button_handler). So the subject can take as long as they need to hunt for their
quietest audible level, and the tone ends 15 s after they stop adjusting. Whatever
level they settled on is the threshold result reported to the phone.

app_state (owned by node_client) is the single source of truth for playback state.
Only this module's play_tone and the stop path write is_playing.
"""
import threading
import time

import numpy as np
import pyaudio

import config
import records
import tone_clock
import uplink


def get_output_device_index():
    """Prefer the Pirate Audio / HifiBerry PCM5102A DAC; fall back to the first
    available output device (which is what the bare-board mock node gets)."""
    p = pyaudio.PyAudio()
    first_index = None
    dac_index = None
    print("--- Available audio output devices ---")
    try:
        for i in range(p.get_device_count()):
            info = p.get_device_info_by_index(i)
            if info['maxOutputChannels'] > 0:
                print(f"  [index={i}] {info['name']} "
                      f"(output channels: {info['maxOutputChannels']})")
                if first_index is None:
                    first_index = i
                name = info['name'].lower()
                # Keep the FIRST match and never match HDMI. (HDMI's name contains
                # 'i2s-hifi', which a looser 'hifi' keyword wrongly caught, sending
                # audio to HDMI -> stream failed to open -> no sound.)
                if (dac_index is None
                        and not any(k in name for k in config.AUDIO_DEV_EXCLUDE)
                        and any(k in name for k in config.AUDIO_DEV_KEYWORDS)):
                    dac_index = i
    finally:
        p.terminate()

    chosen = dac_index if dac_index is not None else first_index
    if chosen is None:
        print("Warning: no available output device found")
        uplink.send("error", code="AUDIO_DEV_NOT_FOUND",
                    detail="PyAudio reported no output device")
    elif dac_index is None:
        print(f"Warning: no {config.AUDIO_DEV_KEYWORDS[0]} device; "
              f"falling back to index={chosen}")
    else:
        print(f"Auto-selected device index={chosen}")
    print("------------------------")
    return chosen


OUTPUT_DEVICE_INDEX = get_output_device_index()


def _ramp_gains(start, n, fs, now, deadline):
    """Fade-in / fade-out envelope for one chunk, or None when RAMP_MS is 0.

    Disabled by default (config.RAMP_MS = 0), which reproduces the previous
    behaviour byte for byte. Set RAMP_MS to 10 if hardware listening reveals a
    click at the stream edges. The fade-out is chunk-granular: it triggers on the
    chunk where the countdown is about to expire.
    """
    if config.RAMP_MS <= 0:
        return None
    ramp_n = int(fs * config.RAMP_MS / 1000.0)
    if ramp_n <= 0:
        return None

    gains = None
    if start < ramp_n:                                   # fade in
        idx = np.arange(start, start + n, dtype=np.float32)
        gains = np.clip(idx / ramp_n, 0.0, 1.0)
    if (deadline - now) <= (config.RAMP_MS / 1000.0):    # fade out
        out = np.linspace(1.0, 0.0, n, dtype=np.float32)
        gains = out if gains is None else gains * out
    return gains


def play_tone(app_state, frequency, ear='both', seq=None):
    """Play a pure tone on the selected channel(s) until the countdown expires.

    Stops immediately when is_playing becomes False (operator pressed Stop, or the
    link dropped). Generated per chunk from an absolute sample index so phase stays
    continuous. Each chunk re-reads app_state['current_db'] and converts it to a
    linear amplitude, which is what makes X/Y volume changes audible in real time.
    """
    app_state['is_playing'] = True
    app_state['current_frequency'] = frequency
    app_state['current_ear'] = ear
    app_state['seq'] = seq
    # The first segment of a test is the level the phone sent -- 'init' in the
    # phone's records table (white row); X/Y presses open the later segments.
    app_state['seg_db'] = app_state['current_db']
    app_state['seg_from'] = 'init'

    play_left = ear in ('L', 'left', 'both')
    play_right = ear in ('R', 'right', 'both')
    two_pi_f = 2 * np.pi * frequency

    fs = config.SAMPLE_RATE
    chunk = config.CHUNK_SIZE
    tone_clock.reset(app_state)
    hard_deadline = time.monotonic() + config.MAX_TONE_TOTAL_SEC

    p = None
    stream = None
    completed = False
    try:
        p = pyaudio.PyAudio()
        open_kwargs = dict(format=pyaudio.paFloat32, channels=2,
                           rate=fs, output=True)
        if OUTPUT_DEVICE_INDEX is not None:
            open_kwargs['output_device_index'] = OUTPUT_DEVICE_INDEX
        stream = p.open(**open_kwargs)

        records.log_event(app_state, "play", remaining=config.TONE_DURATION)
        uplink.send("tone_started", seq=seq, freq=frequency,
                    db=round(app_state['current_db'], 2), ear=ear)

        start = 0
        while app_state['is_playing']:
            now = time.monotonic()
            deadline = min(app_state['tone_deadline'], hard_deadline)
            if now >= deadline:
                completed = True
                break

            n = chunk
            # Absolute sample index -> phase is continuous across chunks.
            t = np.arange(start, start + n) / fs
            wave = np.sin(two_pi_f * t).astype(np.float32)

            gains = _ramp_gains(start, n, fs, now, deadline)
            if gains is not None:
                wave = wave * gains

            stereo = np.zeros(n * 2, dtype=np.float32)
            if play_left:
                stereo[0::2] = wave
            if play_right:
                stereo[1::2] = wave

            stereo *= config.db_to_linear(app_state['current_db'])   # real-time dB
            stream.write(stereo.tobytes())
            start += n

        if not completed:
            print("Playback interrupted.")

    except Exception as e:
        print(f"Audio output error: {e}")
        uplink.send("error", code="AUDIO_STREAM_ERROR", detail=str(e))
    finally:
        if stream is not None:
            stream.stop_stream()
            stream.close()
        if p is not None:
            p.terminate()
        app_state['is_playing'] = False

        # The final segment closes here. Its dB is the subject's threshold for this
        # frequency: they stopped adjusting and the countdown ran out.
        left = 0.0 if completed else tone_clock.remaining(app_state)
        reason = "completed" if completed else "stopped"
        records.log_event(app_state, "end" if completed else "stop", remaining=left)
        uplink.send("tone_done",
                    seq=seq,
                    reason=reason,
                    freq=frequency,
                    ear=ear,
                    final_db=round(app_state['current_db'], 2),
                    final_linear=round(config.db_to_linear(app_state['current_db']), 5),
                    seg_from=app_state.get('seg_from', 'init'),
                    seg_remaining_s=round(left, 2))
        print(f"Audio stream closed ({reason}).")


class Player:
    """Owns the playback thread. Switching tones joins the old thread before
    starting the new one, so two audio streams never run at once -- a fixed sleep
    is not reliable under load."""

    def __init__(self, app_state, play_func=play_tone):
        self._app_state = app_state
        self._play = play_func
        self._thread = None

    def start(self, frequency, ear, seq):
        self._app_state['is_playing'] = False
        prev = self._thread
        if prev is not None and prev.is_alive():
            prev.join(timeout=2.0)
            if prev.is_alive():
                print("[warn] old playback thread did not exit within 2s; "
                      "possible double audio (verify on hardware)")
        t = threading.Thread(target=self._play,
                             args=(self._app_state, frequency, ear, seq),
                             daemon=True)
        self._thread = t
        t.start()

    def stop(self):
        """Ask the playback loop to end. The thread emits tone_done itself."""
        self._app_state['is_playing'] = False

    def join(self, timeout=2.0):
        if self._thread is not None and self._thread.is_alive():
            self._thread.join(timeout=timeout)
