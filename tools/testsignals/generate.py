#!/usr/bin/env python3
"""Generate the reference test signals used to calibrate and regression-test
the analyzer against reference meters.

Every file is 48 kHz, 24-bit PCM WAV. A manifest.json next to the files records,
for each signal, what it is for and the theoretical values a correct meter
should show.

Usage:  python3 generate.py OUTPUT_DIR
Needs:  numpy
"""
import json
import os
import sys
import wave

import numpy as np

FS = 48_000
RNG = np.random.default_rng(20261105)


def db(x):
    return 20 * np.log10(x)


def amp(dbfs):
    return 10 ** (dbfs / 20)


def t(seconds):
    return np.arange(int(round(seconds * FS))) / FS


def sine(freq, seconds, dbfs, phase=0.0):
    return amp(dbfs) * np.sin(2 * np.pi * freq * t(seconds) + phase)


def silence(seconds):
    return np.zeros(int(round(seconds * FS)))


def white(seconds, rms_dbfs):
    x = RNG.standard_normal(int(round(seconds * FS)))
    return x / np.sqrt(np.mean(x**2)) * amp(rms_dbfs)


def pink(seconds, rms_dbfs):
    n = int(round(seconds * FS))
    spec = np.fft.rfft(RNG.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / FS)
    f[0] = f[1]
    spec /= np.sqrt(f)  # -3 dB/octave
    spec[0] = 0
    x = np.fft.irfft(spec, n)
    return x / np.sqrt(np.mean(x**2)) * amp(rms_dbfs)


def log_sweep(f0, f1, seconds, dbfs):
    tt = t(seconds)
    k = np.log(f1 / f0)
    return amp(dbfs) * np.sin(2 * np.pi * f0 * seconds / k * (np.exp(tt / seconds * k) - 1))


def fade(x, ms=5):
    """Raised-cosine fade in/out so bursts don't click (except where noted)."""
    n = min(int(FS * ms / 1000), len(x) // 2)
    if n:
        w = 0.5 - 0.5 * np.cos(np.pi * np.arange(n) / n)
        x = x.copy()
        x[:n] *= w
        x[-n:] *= w[::-1]
    return x


def write_wav(path, left, right=None):
    right = left if right is None else right
    st = np.stack([left, right], axis=1)
    if np.max(np.abs(st)) > 1.0:
        raise ValueError(f"{path} clips")
    ints = np.clip(np.round(st * 8388607), -8388608, 8388607).astype("<i4")
    raw = ints.astype("<u4").view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(3)
        w.setframerate(FS)
        w.writeframes(raw)


def build():
    sig = []  # (name, left, right, purpose, expected)

    sig.append(("01_sine_1k_-20dBFS", sine(1000, 10, -20), None,
                "Level meter calibration. Reveals the RMS convention (AES17 sine = peak, or true RMS = peak - 3.01 dB).",
                {"peak_dBFS": -20.0, "true_rms_dBFS": -23.01, "aes17_rms_dBFS": -20.0}))
    sig.append(("02_sine_1k_0dBFS", sine(1000, 10, -0.0001), None,
                "Full-scale reference; clip indicator must NOT trigger.",
                {"peak_dBFS": 0.0, "true_rms_dBFS": -3.01}))
    sig.append(("03_sine_1k_-20dBFS_left_only", sine(1000, 10, -20), silence(10),
                "Channel identity, power balance at 100% left, correlation with silent channel, sum/difference mode.",
                {"left_peak_dBFS": -20.0, "right": "silence"}))

    # Tone bursts: 1 kHz at -10 dBFS, increasing length, 2 s gaps.
    burst = []
    lengths_ms = [1, 3, 5, 10, 20, 50, 100, 300, 1000]
    for ms in lengths_ms:
        burst += [sine(1000, ms / 1000, -10), silence(2.0)]  # no fade: exact length
    burst = np.concatenate([silence(1.0)] + burst)
    sig.append(("04_tone_bursts_ballistics", burst, None,
                "Peak / RMS / VU / PPM integration times. Record the maximum reading of each meter type for each burst length (1, 3, 5, 10, 20, 50, 100, 300, 1000 ms).",
                {"burst_level_dBFS": -10.0, "burst_lengths_ms": lengths_ms, "gap_s": 2.0}))

    step = np.concatenate([silence(1), sine(1000, 3, -10), silence(6)])
    sig.append(("05_step_release", step, None,
                "Release / peak crawlback rate. Record how many seconds each meter takes to fall from -10 to -30 and to -60 dBFS after the tone stops (video of the screen is ideal).",
                {"level_dBFS": -10.0, "tone_on_s": [1, 4]}))

    sig.append(("06_pink_noise_-20dBFS", pink(15, -20), None,
                "Spectrum analyzer slope and averaging. Pink noise should look flat in octave mode and fall 3 dB/octave in FFT mode.",
                {"rms_dBFS": -20.0, "slope_db_per_octave_fft": -3.0}))
    sig.append(("07_white_noise_-20dBFS", white(15, -20), None,
                "FFT bin-level calibration: white noise per-bin level depends on FFT size and window, so record it at several FFT sizes.",
                {"rms_dBFS": -20.0}))
    sig.append(("08_log_sweep_20-20k", np.concatenate([log_sweep(20, 20000, 10, -20), silence(1)]), None,
                "Spectrum analyzer peak hold and waterfall scrolling speed. The peak-hold trace after the sweep should be flat at the sine level.",
                {"level_dBFS": -20.0, "sweep_s": 10}))
    mt = sine(100, 10, -20) + sine(1000, 10, -20) + sine(10000, 10, -20)
    sig.append(("09_multitone_100_1k_10k", mt, None,
                "Spectrum analyzer frequency axis and sine-peak calibration. Each tone should read -20 dBFS on a correctly calibrated sine scale.",
                {"tones_hz": [100, 1000, 10000], "each_dBFS": -20.0}))
    res = sine(1000, 10, -20) + sine(1003, 10, -20)
    sig.append(("10_resolution_1000_1003Hz", res, None,
                "Frequency resolution. Note the smallest FFT size at which the two tones show as separate peaks.",
                {"tones_hz": [1000, 1003], "each_dBFS": -20.0}))

    n = pink(4, -20)
    u1, u2 = pink(4, -20), pink(4, -20)
    corr_l = np.concatenate([n, n, u1, sine(1000, 4, -20), sine(1000, 4, -20)])
    corr_r = np.concatenate([n, -n, u2, sine(1000, 4, -20, phase=np.pi / 2), silence(4)])
    sig.append(("11_correlation_sequence", corr_l, corr_r,
                "Correlation meter, Lissajous, phase-vs-frequency display. Five 4-second segments: identical, polarity-inverted, uncorrelated noise, 90-degree sine, left only.",
                {"segments": ["+1 identical", "-1 inverted", "~0 uncorrelated", "0 quadrature sine", "left only"], "segment_s": 4}))
    sig.append(("12_balance_6dB_left", sine(1000, 10, -20), sine(1000, 10, -26),
                "Power Balance History. Left is 6 dB louder than right, so left has 80% of the power: the balance should read +60% (80 - 20) if it is difference over total.",
                {"left_dBFS": -20, "right_dBFS": -26, "left_power_fraction": 0.799}))
    d = 48
    pn = pink(12, -20)
    sig.append(("13_delay_1ms_right", pn, np.concatenate([np.zeros(d), pn[:-d]]),
                "phase-vs-frequency display and Transfer Function delay. Right lags left by 48 samples (1.000 ms), so phase should rotate 360 degrees every 1 kHz.",
                {"delay_samples": d, "delay_ms": 1.0}))
    isp = sine(FS / 4, 10, -1.0, phase=np.pi / 4)
    sig.append(("14_intersample_peak", isp, None,
                "True-peak behaviour. An fs/4 sine at 45 degrees: every sample is at -4.01 dBFS but the true peak is -1.0 dBFS. Note which the peak meter shows.",
                {"sample_peak_dBFS": round(db(amp(-1.0) * np.sqrt(0.5)), 2), "true_peak_dBFS": -1.0}))
    sig.append(("15_dc_offset", sine(1000, 10, -20) + amp(-40), None,
                "DC handling. Compare readings with Analyzer > Remove DC Offset on and off.",
                {"sine_dBFS": -20, "dc_dBFS": -40}))
    lo = np.round(sine(1000, 10, -90) * 32767) / 32767  # 16-bit quantised, undithered
    sig.append(("16_sine_-90dBFS_16bit", lo, None,
                "Spectrum analyzer noise floor and low-level behaviour; harmonics show the truncation distortion.",
                {"level_dBFS": -90, "quantisation_bits": 16}))
    sig.append(("17_silence", silence(10), None,
                "Digital silence: record what every meter shows at rest (floor values, -inf display).",
                {}))
    return sig


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    manifest = {"sample_rate": FS, "bit_depth": 24, "channels": 2, "signals": []}
    for name, left, right, purpose, expected in build():
        write_wav(os.path.join(out, name + ".wav"), left, right)
        manifest["signals"].append({"file": name + ".wav", "seconds": round(len(left) / FS, 3),
                                    "purpose": purpose, "expected": expected})
        print(name)
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)


if __name__ == "__main__":
    main()
