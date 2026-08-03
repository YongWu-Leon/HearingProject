#!/usr/bin/env python3
"""Tests for the play_tone command handler.  Run:  python3 test_controls.py

No pytest on the target, so this is plain asserts with a tiny runner. It imports
nothing that needs hardware, which is what lets it run on a development machine.

The case that matters most here is the LAST one. A node running older code once
failed to recognise the level field the phone was sending and silently fell back
to its own default, so every tone played at that default while the phone believed
its request had been honoured. Nothing errored, and the node's own log looked
correct. These tests pin the behaviour that makes that failure visible.
"""
import config
import controls
import uplink


class FakePlayer:
    """Records what playback was asked for instead of touching the audio device."""

    def __init__(self):
        self.calls = []

    def start(self, frequency, ear, seq):
        self.calls.append({'f': frequency, 'ear': ear, 'seq': seq})

    def stop(self):
        self.calls.append('stop')


def fresh_state(current_db=-30.0):
    return {
        'is_playing': False,
        'current_db': current_db,
        'current_frequency': 1000.0,
        'current_ear': 'both',
        'seq': None,
        'tone_deadline': 0.0,
        'seg_db': current_db,
        'seg_from': 'init',
    }


def drain_uplink():
    """Empty the queue and return everything that was in it."""
    out = []
    while True:
        msg = uplink.get(0.01)
        if msg is None:
            return out
        out.append(msg)


# ---------------------------------------------------------------- test cases

def test_level_db_is_used_as_sent():
    state, player = fresh_state(), FakePlayer()
    drain_uplink()
    controls.handle_play(state, player, {
        'type': 'play_tone', 'seq': 1, 'f': 1000.0,
        'level_db': -40.0, 'ear': 'both',
    })
    assert state['current_db'] == -40.0, state['current_db']
    assert player.calls == [{'f': 1000.0, 'ear': 'both', 'seq': 1}], player.calls
    assert [m for m in drain_uplink() if m['type'] == 'error'] == []


def test_legacy_v_is_converted():
    state, player = fresh_state(), FakePlayer()
    drain_uplink()
    controls.handle_play(state, player, {
        'type': 'play_tone', 'seq': 2, 'f': 1000.0, 'v': 50.0, 'ear': 'both',
    })
    expected, _, _ = config.clamp_db(config.linear_to_db(0.5))
    assert abs(state['current_db'] - expected) < 1e-9, state['current_db']
    assert [m for m in drain_uplink() if m['type'] == 'error'] == []


def test_missing_level_is_reported_not_silent():
    """The regression this file exists for."""
    state, player = fresh_state(current_db=-30.0), FakePlayer()
    drain_uplink()
    controls.handle_play(state, player, {
        'type': 'play_tone', 'seq': 3, 'f': 1000.0, 'ear': 'both',
    })
    # Falling back is correct; doing it silently is not.
    assert state['current_db'] == -30.0, state['current_db']
    assert len(player.calls) == 1, 'playback should still start'

    errors = [m for m in drain_uplink() if m['type'] == 'error']
    assert len(errors) == 1, f'expected one error uplink, got {errors}'
    assert errors[0]['code'] == 'NO_LEVEL', errors[0]
    assert errors[0]['seq'] == 3, errors[0]


def test_level_is_clamped_to_the_configured_range():
    state, player = fresh_state(), FakePlayer()
    drain_uplink()
    controls.handle_play(state, player, {
        'type': 'play_tone', 'seq': 4, 'f': 1000.0, 'level_db': -999.0,
    })
    assert state['current_db'] == config.DB_FLOOR, state['current_db']

    controls.handle_play(state, player, {
        'type': 'play_tone', 'seq': 5, 'f': 1000.0, 'level_db': 99.0,
    })
    assert state['current_db'] == config.DB_CEILING, state['current_db']


def test_bad_frequency_is_rejected_without_playing():
    state, player = fresh_state(), FakePlayer()
    drain_uplink()
    controls.handle_play(state, player, {
        'type': 'play_tone', 'seq': 6, 'f': -5.0, 'level_db': -20.0,
    })
    assert player.calls == [], 'a bad frequency must not start playback'
    errors = [m for m in drain_uplink() if m['type'] == 'error']
    assert len(errors) == 1 and errors[0]['code'] == 'BAD_FREQUENCY', errors


def test_stop_is_ignored_when_nothing_is_playing():
    state, player = fresh_state(), FakePlayer()
    controls.handle_stop(state, player, {})
    assert player.calls == [], player.calls

    state['is_playing'] = True
    controls.handle_stop(state, player, {})
    assert player.calls == ['stop'], player.calls


# --------------------------------------------------------------------- runner

def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith('test_')]
    failed = 0
    for t in tests:
        try:
            t()
            print(f'  PASS  {t.__name__}')
        except AssertionError as e:
            failed += 1
            print(f'  FAIL  {t.__name__}: {e}')
    print(f'\n{len(tests) - failed}/{len(tests)} passed')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
