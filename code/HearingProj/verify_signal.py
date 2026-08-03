#!/usr/bin/env python3
"""Signal-purity verification for the node's tone generator.

Runs entirely on a development machine -- no Pi, no DAC, no sound card. It
imports the node's own config module and reproduces the exact chunk-by-chunk
synthesis used in audio.play_tone, so what is measured is the code that ships,
not a re-implementation of it.

WHY THIS EXISTS
    An acoustic measurement of the finished system contains three error sources
    stacked together: the generator (software), the DAC, and the transducer.
    Establishing here that the DIGITAL signal is clean lets any deviation found
    in the acoustic measurements be attributed to the hardware rather than to
    the generator. That is the whole point -- error attribution.

WHAT IT CHECKS
    1. Frequency accuracy      -- does a nominal 1 kHz request produce 1 kHz?
    2. Harmonic distortion     -- is the waveform a clean sine (THD)?
    3. Phase continuity        -- does chunk-wise generation introduce boundary
                                  artefacts? Compared against both a continuous
                                  reference and a deliberately naive generator
                                  that resets phase every chunk.
    4. Level accuracy          -- does a requested dB produce that amplitude?
    5. Floor behaviour         -- is DB_FLOOR a clamp rather than digital silence,
                                  and is it representable at the output bit depth?
    6. Clipping                -- does full scale stay within +/-1.0?

USAGE
    python verify_signal.py                 # table to stdout + CSV + plots
    python verify_signal.py --no-plots      # skip matplotlib
    python verify_signal.py --out DIR       # choose the output directory
"""
import argparse
import csv
import os

import numpy as np

import config

# Standard audiometric frequencies. 10 kHz is omitted because its harmonics fall
# above Nyquist, which makes the THD figure meaningless rather than merely small.
TEST_FREQUENCIES = [125, 250, 500, 1000, 2000, 4000, 8000]

# Levels used for the dB-scale check, spanning the full working range.
TEST_LEVELS_DB = [0.0, -6.0, -20.0, -40.0, -60.0, -80.0, -100.0, -120.0]

ANALYSIS_SECONDS = 4.0
HARMONICS = (2, 3, 4, 5)


# ---------------------------------------------------------------- generation

def generate_chunked(frequency, db, seconds, reset_phase_each_chunk=False):
    """Reproduce audio.play_tone's generation loop and return the left channel.

    The real loop builds one CHUNK_SIZE block at a time from an ABSOLUTE sample
    index, which is what keeps phase continuous across block boundaries. Passing
    reset_phase_each_chunk=True reproduces the naive alternative (restarting the
    time vector at zero every block) purely so the two can be compared.
    """
    fs = config.SAMPLE_RATE
    chunk = config.CHUNK_SIZE
    two_pi_f = 2 * np.pi * frequency
    total = int(fs * seconds)
    amplitude = config.db_to_linear(db)

    blocks = []
    start = 0
    while start < total:
        n = min(chunk, total - start)
        base = 0 if reset_phase_each_chunk else start
        t = np.arange(base, base + n) / fs
        wave = np.sin(two_pi_f * t).astype(np.float32)

        # audio.py writes interleaved stereo and scales the whole block by the
        # current level; mono analysis only needs one channel back out.
        stereo = np.zeros(n * 2, dtype=np.float32)
        stereo[0::2] = wave
        stereo[1::2] = wave
        stereo *= amplitude

        blocks.append(stereo[0::2])
        start += n
    return np.concatenate(blocks)


def generate_continuous(frequency, db, seconds):
    """One-shot reference signal: the ideal the chunked generator must match."""
    fs = config.SAMPLE_RATE
    total = int(fs * seconds)
    t = np.arange(0, total) / fs
    wave = np.sin(2 * np.pi * frequency * t).astype(np.float32)
    return (wave * config.db_to_linear(db)).astype(np.float32)


# ------------------------------------------------------------------ analysis

def spectrum(signal):
    """Hann-windowed magnitude spectrum and its frequency axis."""
    n = len(signal)
    window = np.hanning(n)
    mag = np.abs(np.fft.rfft(signal.astype(np.float64) * window))
    freqs = np.fft.rfftfreq(n, 1.0 / config.SAMPLE_RATE)
    return freqs, mag


def peak_frequency(freqs, mag):
    """Peak frequency refined by parabolic interpolation on the log magnitude.

    Without interpolation the answer is quantised to the FFT bin width, which
    would hide errors smaller than the bin and report false ones up to half a bin.
    """
    k = int(np.argmax(mag))
    if k == 0 or k == len(mag) - 1:
        return freqs[k]
    a, b, c = (np.log(mag[k - 1] + 1e-30), np.log(mag[k] + 1e-30),
               np.log(mag[k + 1] + 1e-30))
    delta = 0.5 * (a - c) / (a - 2 * b + c)
    return (k + delta) * (config.SAMPLE_RATE / (2.0 * (len(mag) - 1)))


def _bin_peak(mag, freqs, target, span=4):
    """Largest magnitude within +/-span bins of a target frequency."""
    k = int(round(target / (freqs[1] - freqs[0])))
    lo, hi = max(0, k - span), min(len(mag), k + span + 1)
    return float(np.max(mag[lo:hi])) if hi > lo else 0.0


def thd_percent(freqs, mag, fundamental):
    """Total harmonic distortion from harmonics 2..5, as a percentage.

    Harmonics landing above Nyquist are skipped rather than counted as zero,
    which would understate the figure.
    """
    nyquist = config.SAMPLE_RATE / 2.0
    h1 = _bin_peak(mag, freqs, fundamental)
    if h1 <= 0:
        return float('nan')
    power = 0.0
    for h in HARMONICS:
        f = fundamental * h
        if f >= nyquist:
            continue
        power += _bin_peak(mag, freqs, f) ** 2
    return 100.0 * np.sqrt(power) / h1


def spurious_ratio_db(freqs, mag, fundamental):
    """Energy outside the fundamental, relative to total, in dB.

    A phase-continuous sine puts essentially all of its energy in the fundamental
    (plus window leakage); a generator that restarts phase every block smears
    energy across the spectrum, which this figure exposes directly.
    """
    total = float(np.sum(mag ** 2))
    if total <= 0:
        return float('nan')
    bin_hz = freqs[1] - freqs[0]
    k = int(round(fundamental / bin_hz))
    lo, hi = max(0, k - 6), min(len(mag), k + 7)
    fundamental_energy = float(np.sum(mag[lo:hi] ** 2))
    outside = max(total - fundamental_energy, 1e-30)
    return 10.0 * np.log10(outside / total)


# --------------------------------------------------------------------- tests

def test_frequencies():
    rows = []
    for f in TEST_FREQUENCIES:
        sig = generate_chunked(f, -6.0, ANALYSIS_SECONDS)
        freqs, mag = spectrum(sig)
        measured = peak_frequency(freqs, mag)
        rows.append({
            'nominal_hz': f,
            'measured_hz': round(measured, 4),
            'error_hz': round(measured - f, 4),
            'error_percent': round(100.0 * (measured - f) / f, 6),
            'thd_percent': round(thd_percent(freqs, mag, f), 6),
            'peak_amplitude': round(float(np.max(np.abs(sig))), 6),
        })
    return rows


def test_levels():
    rows = []
    for db in TEST_LEVELS_DB:
        expected = 10.0 ** (db / 20.0)
        sig = generate_chunked(1000, db, 0.5)
        peak = float(np.max(np.abs(sig)))
        # Peak of a sine equals its amplitude, so this converts straight back to dB.
        measured_db = 20.0 * np.log10(peak) if peak > 0 else float('-inf')
        rows.append({
            'requested_db': db,
            'expected_amplitude': f'{expected:.3e}',
            'measured_peak': f'{peak:.3e}',
            'measured_db': round(measured_db, 3) if peak > 0 else 'silent',
            'error_db': round(measured_db - db, 4) if peak > 0 else 'n/a',
        })
    return rows


def test_phase_continuity():
    """Chunked vs continuous, and correct vs deliberately naive."""
    f, db = 1000, -6.0
    chunked = generate_chunked(f, db, ANALYSIS_SECONDS)
    continuous = generate_continuous(f, db, ANALYSIS_SECONDS)
    naive = generate_chunked(f, db, ANALYSIS_SECONDS, reset_phase_each_chunk=True)

    n = min(len(chunked), len(continuous), len(naive))
    diff_ok = float(np.max(np.abs(chunked[:n] - continuous[:n])))
    diff_naive = float(np.max(np.abs(naive[:n] - continuous[:n])))

    fr_ok, mag_ok = spectrum(chunked)
    fr_nv, mag_nv = spectrum(naive)
    return {
        'max_abs_diff_shipped': diff_ok,
        'max_abs_diff_naive': diff_naive,
        'spurious_db_shipped': round(spurious_ratio_db(fr_ok, mag_ok, f), 2),
        'spurious_db_naive': round(spurious_ratio_db(fr_nv, mag_nv, f), 2),
        'thd_shipped': round(thd_percent(fr_ok, mag_ok, f), 6),
        'thd_naive': round(thd_percent(fr_nv, mag_nv, f), 6),
    }


def test_floor_and_clipping():
    """The floor must clamp, not mute -- and must survive the output bit depth."""
    floor_amp = config.db_to_linear(config.DB_FLOOR)
    full_scale = generate_chunked(1000, config.DB_CEILING, 0.2)
    lsb24 = 2.0 ** -23
    lsb16 = 2.0 ** -15
    return {
        'floor_db': config.DB_FLOOR,
        'floor_amplitude': f'{floor_amp:.3e}',
        'floor_is_silent': floor_amp == 0.0,
        'floor_lsbs_at_24bit': round(floor_amp / lsb24, 2),
        'floor_lsbs_at_16bit': round(floor_amp / lsb16, 4),
        'ceiling_peak': round(float(np.max(np.abs(full_scale))), 6),
        'clipped': bool(np.max(np.abs(full_scale)) > 1.0),
    }


# -------------------------------------------------------------------- output

def _print_table(title, rows, columns):
    print()
    print(title)
    print('-' * 78)
    widths = [max(len(c), *(len(str(r[c])) for r in rows)) for c in columns]
    print('  '.join(c.ljust(w) for c, w in zip(columns, widths)))
    for r in rows:
        print('  '.join(str(r[c]).ljust(w) for c, w in zip(columns, widths)))


def _write_csv(path, rows, columns):
    with open(path, 'w', newline='', encoding='utf-8') as fh:
        writer = csv.DictWriter(fh, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def _plots(out_dir):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    f, db = 1000, -6.0
    shipped = generate_chunked(f, db, ANALYSIS_SECONDS)
    naive = generate_chunked(f, db, ANALYSIS_SECONDS, reset_phase_each_chunk=True)

    fig, axes = plt.subplots(1, 2, figsize=(11, 4), sharey=True)
    for ax, sig, name in ((axes[0], shipped, 'Shipped (absolute sample index)'),
                          (axes[1], naive, 'Naive (phase reset per chunk)')):
        freqs, mag = spectrum(sig)
        ref = np.max(mag)
        ax.plot(freqs, 20 * np.log10(mag / ref + 1e-12), linewidth=0.7)
        ax.set_xlim(0, 8000)
        ax.set_ylim(-160, 5)
        ax.set_title(name, fontsize=10)
        ax.set_xlabel('Frequency (Hz)')
        ax.grid(alpha=0.3)
    axes[0].set_ylabel('Magnitude (dB rel. peak)')
    fig.tight_layout()
    spectrum_path = os.path.join(out_dir, 'spectrum_comparison.png')
    fig.savefig(spectrum_path, dpi=140)
    plt.close(fig)

    # Waveform around a chunk boundary, where a discontinuity would appear.
    boundary = config.CHUNK_SIZE
    span = 60
    fig, ax = plt.subplots(figsize=(7, 3.2))
    idx = np.arange(boundary - span, boundary + span)
    ax.plot(idx, shipped[idx], label='Shipped', linewidth=1.2)
    ax.plot(idx, naive[idx], label='Naive', linewidth=1.2, linestyle='--')
    ax.axvline(boundary, color='k', linewidth=0.8, alpha=0.5)
    ax.set_xlabel('Sample index (chunk boundary marked)')
    ax.set_ylabel('Amplitude')
    ax.legend(fontsize=9)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    boundary_path = os.path.join(out_dir, 'chunk_boundary.png')
    fig.savefig(boundary_path, dpi=140)
    plt.close(fig)
    return [spectrum_path, boundary_path]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', default='signal_check_out',
                        help='directory for CSV and plot output')
    parser.add_argument('--no-plots', action='store_true')
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    print('=' * 78)
    print('Signal-purity verification -- node tone generator')
    print('=' * 78)
    print(f'sample rate      {config.SAMPLE_RATE} Hz')
    print(f'chunk size       {config.CHUNK_SIZE} samples '
          f'({1000.0 * config.CHUNK_SIZE / config.SAMPLE_RATE:.2f} ms)')
    print(f'level range      {config.DB_CEILING} to {config.DB_FLOOR} dB FS')
    print(f'ramp             {config.RAMP_MS} ms')
    print(f'analysis window  {ANALYSIS_SECONDS} s')

    freq_rows = test_frequencies()
    freq_cols = ['nominal_hz', 'measured_hz', 'error_hz', 'error_percent',
                 'thd_percent', 'peak_amplitude']
    _print_table('1. Frequency accuracy and harmonic distortion (at -6 dB FS)',
                 freq_rows, freq_cols)
    _write_csv(os.path.join(args.out, 'frequency_accuracy.csv'), freq_rows, freq_cols)

    level_rows = test_levels()
    level_cols = ['requested_db', 'expected_amplitude', 'measured_peak',
                  'measured_db', 'error_db']
    _print_table('2. Level accuracy across the working range (1 kHz)',
                 level_rows, level_cols)
    _write_csv(os.path.join(args.out, 'level_accuracy.csv'), level_rows, level_cols)

    phase = test_phase_continuity()
    print()
    print('3. Phase continuity across chunk boundaries (1 kHz)')
    print('-' * 78)
    print(f'  max |shipped - continuous reference|   {phase["max_abs_diff_shipped"]:.3e}')
    print(f'  max |naive   - continuous reference|   {phase["max_abs_diff_naive"]:.3e}')
    print(f'  out-of-fundamental energy, shipped     {phase["spurious_db_shipped"]} dB')
    print(f'  out-of-fundamental energy, naive       {phase["spurious_db_naive"]} dB')
    print(f'  THD shipped / naive                    {phase["thd_shipped"]} % / '
          f'{phase["thd_naive"]} %')

    floor = test_floor_and_clipping()
    print()
    print('4. Floor behaviour and clipping')
    print('-' * 78)
    print(f'  floor level                            {floor["floor_db"]} dB FS')
    print(f'  floor amplitude                        {floor["floor_amplitude"]}')
    print(f'  floor emits digital silence            {floor["floor_is_silent"]}')
    print(f'  floor size at 24-bit output            {floor["floor_lsbs_at_24bit"]} LSB')
    print(f'  floor size at 16-bit output            {floor["floor_lsbs_at_16bit"]} LSB')
    print(f'  peak at {floor["ceiling_peak"]:.3f} full scale, clipped   {floor["clipped"]}')

    if not args.no_plots:
        try:
            for p in _plots(args.out):
                print(f'\nplot written  {p}')
        except Exception as exc:                      # pragma: no cover
            print(f'\n[warn] plots skipped: {exc}')

    print(f'\nCSV written to {os.path.abspath(args.out)}')


if __name__ == '__main__':
    main()
