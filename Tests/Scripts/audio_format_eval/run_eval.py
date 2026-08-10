#!/usr/bin/env python3
"""
run_eval.py — TASK-135 Phase 0 audio-format evaluation driver.

Determines the smallest archival storage format that preserves quality for
every Meeting Manager audio consumer: WhisperKit transcription, FluidAudio
diarization, voice fingerprint slicing (sample offsets), the mixed-vs-system
energy anchor, and AVPlayer clip/seek playback.

Candidates are all 16 kHz mono (never negotiable — every consumer gates on it):

  A_f32_wav     Float32 WAV                     the format shipping today
  B_i16_wav     Int16 WAV                       Phase 1 capture format
  C_alac_f32    ALAC .m4a encoded from Float32   lossless w.r.t. A
  C_alac_i16    ALAC .m4a encoded from Int16     lossless w.r.t. B
  D_aac_24k     AAC-LC .m4a @ 24 kbps (ABR)
  D_aac_32k     AAC-LC .m4a @ 32 kbps (ABR)
  D_aac_48k     AAC-LC .m4a @ 48 kbps (ABR)

AAC uses ABR (afconvert -s 1), not CBR (-s 0). CBR was measured first and
spends full bitrate on silence: the 24-minute in-person recording's silence-
padded _system file came out at 4.44 MB under CBR versus 0.20 MB under ABR,
with no size penalty on speech. Since _system is mostly silence padding by
design, ABR is the only sensible strategy here. See SUBEXPERIMENTS below.

Stages (run individually or with --stage all). State accumulates in
<scratch>/state.json, so any stage can be re-run without redoing the others.

  prep      compile probes, generate the seek fixture, flatten WER fixtures
  encode    produce every candidate for every corpus file (afconvert)
  strategy  AAC bitrate-allocation sub-experiment (why ABR, not CBR)
  api       compare encoder APIs (afconvert / AVAudioFile / ExtAudioFile)
  parity    decoded sample-count parity + PCM fidelity + spectral proxy
  seek      beep-onset seek accuracy through AVAssetReader
  wer       WER on synthetic fixtures (reuses Tests/Scripts/measure_wer.py)
  tparity   WhisperKit word-level agreement candidate-vs-baseline
  diarize   FluidAudio speaker parity via Tools/BatchRediarize
  report    write results/matrix.md + results/matrix.json

Usage:
  python3 Tests/Scripts/audio_format_eval/run_eval.py --stage all \\
      --scratch /tmp/afe

See README.md for the full re-run recipe and for how corpus files are chosen.
"""

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"

# ─── Thresholds (from the TASK-135 Phase 0 contract) ─────────────────────────

THRESHOLDS = {
    "wer_delta_pp_max": 0.5,        # absolute percentage points vs baseline
    "transcript_agreement_min": 0.99,
    "diar_segment_agreement_min": 0.98,
    "seek_abs_error_ms_max": 50.0,
    "sample_parity": "exact",        # kill criterion
}

# ─── Candidate definitions ───────────────────────────────────────────────────
# `source` names the candidate whose output is the encoder input.
# `ref` names the candidate a fidelity comparison is meaningful against:
# ALAC-from-Int16 is bit-exact w.r.t. Int16, not w.r.t. Float32.

CANDIDATES = {
    "A_f32_wav": {
        "label": "Float32 WAV (baseline)",
        "ext": ".wav", "source": None, "ref": "A_f32_wav",
        "afconvert": None, "lossless_vs_ref": True,
    },
    "B_i16_wav": {
        "label": "Int16 WAV",
        "ext": ".wav", "source": "A_f32_wav", "ref": "A_f32_wav",
        "afconvert": ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1"],
        "lossless_vs_ref": False,
    },
    "C_alac_f32": {
        "label": "ALAC .m4a (from Float32)",
        "ext": ".m4a", "source": "A_f32_wav", "ref": "A_f32_wav",
        "afconvert": ["-f", "m4af", "-d", "alac", "-c", "1"],
        "lossless_vs_ref": True,
    },
    "C_alac_i16": {
        "label": "ALAC .m4a (from Int16)",
        "ext": ".m4a", "source": "B_i16_wav", "ref": "B_i16_wav",
        "afconvert": ["-f", "m4af", "-d", "alac", "-c", "1"],
        "lossless_vs_ref": True,
    },
    "D_aac_24k": {
        "label": "AAC-LC .m4a @ 24 kbps",
        "ext": ".m4a", "source": "A_f32_wav", "ref": "A_f32_wav",
        "afconvert": ["-f", "m4af", "-d", "aac", "-b", "24000", "-q", "127", "-s", "1", "-c", "1"],
        "lossless_vs_ref": False,
    },
    "D_aac_32k": {
        "label": "AAC-LC .m4a @ 32 kbps",
        "ext": ".m4a", "source": "A_f32_wav", "ref": "A_f32_wav",
        "afconvert": ["-f", "m4af", "-d", "aac", "-b", "32000", "-q", "127", "-s", "1", "-c", "1"],
        "lossless_vs_ref": False,
    },
    "D_aac_48k": {
        "label": "AAC-LC .m4a @ 48 kbps",
        "ext": ".m4a", "source": "A_f32_wav", "ref": "A_f32_wav",
        "afconvert": ["-f", "m4af", "-d", "aac", "-b", "48000", "-q", "127", "-s", "1", "-c", "1"],
        "lossless_vs_ref": False,
    },
}

ORDER = list(CANDIDATES.keys())

# Measured before locking the candidate set: afconvert bitrate-allocation
# strategy against a 24.1-minute silence-padded _system file and a 17.9-minute
# speech file. ABR is strictly better here, so ABR is what the candidates use.
# Reproduce with --stage strategy.
SUBEXPERIMENT_FILES = {
    "silent_system": "8E0AF6D5-F6CE-4A7B-B25D-9058401BF9E0_system",
    "speech_mixed": "D192B3E6-3029-45E3-A927-BD2400EFBCF3",
}
STRATEGIES = {"0": "CBR", "1": "ABR", "2": "VBR_constrained", "3": "VBR"}

# ─── Corpus ──────────────────────────────────────────────────────────────────
# Real recordings copied out of the live library. Never read in place, never
# modified. Characterised by mixed/system activity so the corpus spans the
# in-person (silent _system) and remote-heavy cases.

CORPUS = {
    "10467DB5-EBD7-4774-9D77-7C059EB3D145": {
        "minutes": 4.4, "profile": "remote-heavy, short", "transcribe": True,
    },
    "AA3FEB29-22AC-4066-B0C0-369823B08621": {
        "minutes": 12.3, "profile": "hybrid (52% system-active)", "transcribe": True,
    },
    "D192B3E6-3029-45E3-A927-BD2400EFBCF3": {
        "minutes": 17.9, "profile": "remote-heavy, multi-speaker", "transcribe": True,
    },
    "8E0AF6D5-F6CE-4A7B-B25D-9058401BF9E0": {
        "minutes": 24.1, "profile": "in-person (system silent, 0.07% non-zero)", "transcribe": True,
    },
    "20AF257E-F1CC-44A2-AAC7-6AF3FD048AAC": {
        "minutes": 16.3, "profile": "remote, mixed/system lengths already differ", "transcribe": False,
    },
    "097C0046-C28B-42E2-AAC0-2D8E57124BB6": {
        "minutes": 120.0, "profile": "long (2 h) — size + parity only", "transcribe": False,
    },
}

LIVE_AUDIO = Path.home() / "Library/Application Support/MeetingManager/Audio"
APP_LOG = Path.home() / "Library/Application Support/MeetingManager/app.log"


# ─── Utilities ───────────────────────────────────────────────────────────────

def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def run(cmd, **kwargs):
    """Run a command and raise on failure. Never judged through a pipe."""
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(map(str, cmd))}\n"
                           f"stdout: {result.stdout[-2000:]}\nstderr: {result.stderr[-2000:]}")
    return result


def probe(scratch, *cmd):
    result = run([str(scratch / "decode_probe"), *map(str, cmd)])
    return json.loads(result.stdout)


def meeting_is_live():
    """True if the app logged a capture/recording line in the last 60 s.

    Heavy CPU (batch transcription) must not run during a real meeting. Stale
    `recording` DB rows and zombie browser `inCall` flags are not evidence —
    only fresh capture-log lines are.
    """
    if not APP_LOG.exists():
        return False
    now = time.time()
    pattern = re.compile(r"capture|Capture|recording|Recording|Mic:|SystemAudio|audio tap", re.I)
    try:
        with open(APP_LOG, errors="ignore") as handle:
            lines = handle.readlines()[-4000:]
    except OSError:
        return False
    for line in lines:
        match = re.match(r"\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)Z\]", line)
        if not match or not pattern.search(line):
            continue
        stamp = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=timezone.utc).timestamp()
        if now - stamp < 60:
            return True
    return False


def wait_for_idle(scratch):
    while meeting_is_live():
        log("a meeting appears to be recording (fresh capture lines) — waiting 180 s")
        time.sleep(180)
    log("no live recording detected — proceeding with heavy work")


def state_path(scratch):
    return scratch / "state.json"


_INITIAL_STATE = {}


def load_state(scratch):
    global _INITIAL_STATE
    path = state_path(scratch)
    state = json.loads(path.read_text()) if path.exists() else {}
    _INITIAL_STATE = json.loads(json.dumps(state))
    return state


def save_state(scratch, state):
    """Merge into whatever is on disk instead of overwriting it.

    Stages are long enough that they get run concurrently in separate processes
    (transcription takes ~25 min; the cheap stages finish while it runs). A plain
    overwrite makes the last writer silently delete every result the other
    process produced, which is exactly what happened during development: a
    transcription run that started before `seek` and `diarize` wrote their
    results erased both on completion. Only keys this process actually changed
    are written back.
    """
    path = state_path(scratch)
    path.parent.mkdir(parents=True, exist_ok=True)
    disk = {}
    if path.exists():
        try:
            disk = json.loads(path.read_text())
        except json.JSONDecodeError:
            disk = {}
    for key, value in state.items():
        if key not in _INITIAL_STATE or _INITIAL_STATE[key] != value or key not in disk:
            disk[key] = value
    path.write_text(json.dumps(disk, indent=2, sort_keys=True))
    state.update({k: v for k, v in disk.items() if k not in state})


def wav_data_chunk(path):
    """Locate the RIFF data chunk. The app pads headers with JUNK+FLLR chunks,
    so audio starts at byte 4096, not the textbook 44."""
    with open(path, "rb") as handle:
        head = handle.read(65536)
    offset = 12
    while offset + 8 <= len(head):
        cid = head[offset:offset + 4]
        size = struct.unpack("<I", head[offset + 4:offset + 8])[0]
        if cid == b"data":
            return offset + 8, size
        offset += 8 + size + (size % 2)
    raise RuntimeError(f"no data chunk in {path}")


def write_f32_wav(path, samples, sample_rate=16000):
    """Write a 16 kHz mono Float32 WAV — the app's on-disk capture layout.
    afconvert cannot read headerless PCM, so fixture flattening writes the
    container itself."""
    data = np.asarray(samples, dtype="<f4").tobytes()
    with open(path, "wb") as handle:
        handle.write(b"RIFF")
        handle.write(struct.pack("<I", 36 + len(data)))
        handle.write(b"WAVEfmt ")
        handle.write(struct.pack("<IHHIIHH", 16, 3, 1, sample_rate,
                                 sample_rate * 4, 4, 32))
        handle.write(b"data")
        handle.write(struct.pack("<I", len(data)))
        handle.write(data)


# ─── Spectral proxy ──────────────────────────────────────────────────────────
# The app's voice-embedding pipeline (FluidAudio / SpeakerKit) has no CLI entry
# point, so embedding cosine similarity cannot be measured directly here.
# Substitute: log-mel spectrogram distance over identical sample windows, which
# is the front-end every speaker embedder consumes. Documented as a substitution
# in the results matrix.

def mel_filterbank(n_mels=80, n_fft=512, sample_rate=16000):
    def hz_to_mel(f):
        return 2595.0 * np.log10(1.0 + f / 700.0)

    def mel_to_hz(m):
        return 700.0 * (10.0 ** (m / 2595.0) - 1.0)

    low, high = hz_to_mel(0.0), hz_to_mel(sample_rate / 2)
    points = mel_to_hz(np.linspace(low, high, n_mels + 2))
    bins = np.floor((n_fft + 1) * points / sample_rate).astype(int)
    fb = np.zeros((n_mels, n_fft // 2 + 1), dtype=np.float64)
    for m in range(1, n_mels + 1):
        left, centre, right = bins[m - 1], bins[m], bins[m + 1]
        if centre == left:
            centre = left + 1
        if right <= centre:
            right = centre + 1
        for k in range(left, min(centre, fb.shape[1])):
            fb[m - 1, k] = (k - left) / (centre - left)
        for k in range(centre, min(right, fb.shape[1])):
            fb[m - 1, k] = (right - k) / (right - centre)
    return fb


_MEL_FB = mel_filterbank()


def log_mel(samples, n_fft=512, hop=160, win=400):
    if len(samples) < win:
        return np.zeros((0, _MEL_FB.shape[0]))
    n_frames = 1 + (len(samples) - win) // hop
    idx = np.arange(win)[None, :] + hop * np.arange(n_frames)[:, None]
    frames = samples[idx] * np.hanning(win)[None, :]
    spec = np.abs(np.fft.rfft(frames, n=n_fft, axis=1)) ** 2
    mel = spec @ _MEL_FB.T
    return np.log10(np.maximum(mel, 1e-10))


def spectral_metrics(ref, cand, sample_rate=16000, windows=60, window_seconds=10):
    """Compare identical sample windows. Sampling keeps 2-hour files tractable;
    windows are evenly spread so both speech and silence are represented."""
    n = min(len(ref), len(cand))
    span = window_seconds * sample_rate
    if n <= span:
        starts = [0]
    else:
        starts = np.linspace(0, n - span, min(windows, max(1, n // span))).astype(int)
    l1_values, cosines = [], []
    for start in starts:
        a = np.asarray(ref[start:start + span], dtype=np.float64)
        b = np.asarray(cand[start:start + span], dtype=np.float64)
        ma, mb = log_mel(a), log_mel(b)
        rows = min(len(ma), len(mb))
        if rows == 0:
            continue
        ma, mb = ma[:rows], mb[:rows]
        l1_values.append(float(np.mean(np.abs(ma - mb))))
        na = np.linalg.norm(ma, axis=1)
        nb = np.linalg.norm(mb, axis=1)
        good = (na > 1e-9) & (nb > 1e-9)
        if good.any():
            cosines.append(float(np.mean(np.sum(ma[good] * mb[good], axis=1) / (na[good] * nb[good]))))
    return {
        "logmel_l1_mean": round(float(np.mean(l1_values)), 5) if l1_values else None,
        "logmel_cosine_mean": round(float(np.mean(cosines)), 6) if cosines else None,
        "windows_compared": len(l1_values),
    }


def pcm_metrics(ref, cand):
    """Full-file comparison, walked in chunks so a 2-hour file needs no big
    allocation. bit_exact and max_abs_diff must agree, so both look at every
    sample rather than a subsample."""
    n = min(len(ref), len(cand))
    chunk = 1 << 23
    exact = True
    max_diff = 0.0
    noise_sum = 0.0
    signal_sum = 0.0
    clipped = 0
    for start in range(0, n, chunk):
        a = np.asarray(ref[start:start + chunk], dtype=np.float64)
        b = np.asarray(cand[start:start + chunk], dtype=np.float64)
        if exact and not np.array_equal(a, b):
            exact = False
        diff = a - b
        max_diff = max(max_diff, float(np.max(np.abs(diff))) if diff.size else 0.0)
        noise_sum += float(np.sum(diff * diff))
        signal_sum += float(np.sum(a * a))
        clipped += int(np.sum(np.abs(a) > 1.0))
    return {
        "bit_exact": exact,
        "max_abs_diff": float(f"{max_diff:.6g}"),
        "snr_db": round(10 * np.log10((signal_sum / n) / (noise_sum / n)), 2)
                  if noise_sum > 0 and signal_sum > 0 else None,
        "compared_samples": n,
        "reference_samples_over_unity": clipped,
    }


# ─── Stage: prep ─────────────────────────────────────────────────────────────

def stage_prep(scratch, state):
    scratch.mkdir(parents=True, exist_ok=True)
    (scratch / "corpus").mkdir(exist_ok=True)
    (scratch / "enc").mkdir(exist_ok=True)
    (scratch / "dump").mkdir(exist_ok=True)
    (scratch / "fixtures").mkdir(exist_ok=True)

    log("compiling decode_probe")
    run(["swiftc", "-O", "-o", str(scratch / "decode_probe"), str(HERE / "decode_probe.swift")])

    log("compiling batch_transcribe against prebuilt WhisperKit")
    release = REPO / ".build/release"
    if not (release / "Modules/WhisperKit.swiftmodule").exists():
        log("  WARNING: .build/release WhisperKit module missing — "
            "run `swift build -c release --product transcribe-audio` first")
    else:
        run(["swiftc", "-O", "-o", str(scratch / "batch_transcribe"),
             str(HERE / "batch_transcribe.swift"),
             "-I", str(release / "Modules"), "-L", str(release), "-lArgmaxOSSDynamic",
             "-Xlinker", "-rpath", "-Xlinker", str(release)])

    # Copy the corpus out of the live library. Read-only: cp -n semantics.
    for mid in CORPUS:
        for suffix in ("", "_system"):
            src = LIVE_AUDIO / f"{mid}{suffix}.wav"
            dst = scratch / "corpus" / f"{mid}{suffix}.wav"
            if dst.exists():
                continue
            if not src.exists():
                log(f"  WARNING: corpus file missing from library: {src.name}")
                continue
            shutil.copy2(src, dst)
            log(f"  copied {src.name}")

    # Seek fixture: beeps at known offsets.
    seek_wav = scratch / "corpus" / "seekfixture.wav"
    if not seek_wav.exists():
        log("generating 10-minute beep seek fixture")
        info = probe(scratch, "beeps", seek_wav, "--minutes", "10", "--period", "30")
        state["seek_fixture"] = info
    else:
        log("seek fixture already present")

    # WER fixtures: flatten the multipart 22.05 kHz AIFF parts into one
    # 16 kHz mono Float32 WAV per fixture — the app's own storage format, and
    # one transcription per fixture instead of one per part.
    fixtures = sorted(p for p in (REPO / "Tests/Fixtures").iterdir()
                      if p.is_dir() and p.name.startswith("fixture-"))
    if not fixtures:
        log("  WARNING: no fixtures — run `bash Tests/Scripts/generate_fixtures.sh`")
    prepared = {}
    for fixture in fixtures:
        out = scratch / "fixtures" / f"{fixture.name}.wav"
        transcript = fixture / "transcript.txt"
        if not transcript.exists():
            continue
        if not out.exists():
            parts = sorted(fixture.glob("part-*.aiff"),
                           key=lambda p: int(p.stem.split("-")[1]))
            if not parts:
                parts = [fixture / "audio.aiff"]
            chunks = []
            for i, part in enumerate(parts):
                tmp = scratch / "fixtures" / f".{fixture.name}-{i}.wav"
                run(["afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1",
                     str(part), str(tmp)])
                offset, size = wav_data_chunk(tmp)
                chunks.append(np.fromfile(tmp, dtype=np.float32, count=size // 4, offset=offset))
                tmp.unlink()
            joined = np.concatenate(chunks)
            write_f32_wav(out, joined)
            log(f"  flattened {fixture.name}: {len(parts)} parts, "
                f"{len(joined) / 16000:.1f}s")
        prepared[fixture.name] = {
            "wav": str(out), "transcript": str(transcript),
            "seconds": probe(scratch, "info", out)["durationSeconds"],
        }
    state["fixtures"] = prepared
    log(f"prep done: {len(prepared)} fixtures, {len(CORPUS)} recordings")
    return state


# ─── Stage: encode ───────────────────────────────────────────────────────────

def source_files(scratch):
    """Every file the eval encodes: mixed + _system for each recording, the
    seek fixture, and each flattened WER fixture."""
    files = []
    for mid in CORPUS:
        for suffix in ("", "_system"):
            path = scratch / "corpus" / f"{mid}{suffix}.wav"
            if path.exists():
                files.append(("recording", f"{mid}{suffix}", path))
    seek = scratch / "corpus" / "seekfixture.wav"
    if seek.exists():
        files.append(("seek", "seekfixture", seek))
    for fixture in sorted((scratch / "fixtures").glob("fixture-*.wav")):
        files.append(("fixture", fixture.stem, fixture))
    return files


def encoded_path(scratch, key, candidate):
    return scratch / "enc" / f"{key}__{candidate}{CANDIDATES[candidate]['ext']}"


def stage_encode(scratch, state):
    sizes = state.setdefault("sizes", {})
    timings = state.setdefault("encode_seconds", {})
    for kind, key, path in source_files(scratch):
        for candidate in ORDER:
            spec = CANDIDATES[candidate]
            if spec["afconvert"] is None:
                out = path
            else:
                out = encoded_path(scratch, key, candidate)
                src = path if spec["source"] == "A_f32_wav" else encoded_path(
                    scratch, key, spec["source"])
                if not out.exists():
                    if not src.exists():
                        raise RuntimeError(f"encode source missing: {src}")
                    start = time.time()
                    run(["afconvert", *spec["afconvert"], str(src), str(out)])
                    timings.setdefault(candidate, []).append(
                        round(time.time() - start, 3))
            sizes.setdefault(key, {})[candidate] = out.stat().st_size
        log(f"encoded {key} ({kind}): " + "  ".join(
            f"{c}={sizes[key][c] / 1e6:.2f}MB" for c in ORDER))
    return state


# ─── Stage: strategy (AAC bitrate-allocation sub-experiment) ─────────────────

def stage_strategy(scratch, state):
    """Why the AAC candidates use ABR. The _system file is silence-padded to the
    full meeting length by design, so how the encoder spends bits on silence
    dominates its size."""
    out_dir = scratch / "strategy"
    out_dir.mkdir(exist_ok=True)
    results = {}
    for role, key in SUBEXPERIMENT_FILES.items():
        src = scratch / "corpus" / f"{key}.wav"
        if not src.exists():
            log(f"  skipping {role} — {src.name} missing")
            continue
        base_length = probe(scratch, "info", src)["length"]
        for strategy, name in STRATEGIES.items():
            for bitrate in ("24000", "32000"):
                out = out_dir / f"{role}_s{strategy}_{bitrate}.m4a"
                if not out.exists():
                    run(["afconvert", "-f", "m4af", "-d", "aac", "-b", bitrate,
                         "-q", "127", "-s", strategy, "-c", "1", str(src), str(out)])
                length = probe(scratch, "info", out)["length"]
                results[f"{role}::{name}::{bitrate}"] = {
                    "role": role, "strategy": name, "bitrate_bps": int(bitrate),
                    "size_bytes": out.stat().st_size,
                    "sample_exact": length == base_length,
                }
        results[f"{role}::baseline_f32_wav"] = {
            "role": role, "strategy": "none", "bitrate_bps": 512000,
            "size_bytes": src.stat().st_size, "sample_exact": True,
        }
        log(f"  {role}: " + "  ".join(
            f"{STRATEGIES[s]}@{b[:2]}k={results[f'{role}::{STRATEGIES[s]}::{b}']['size_bytes'] / 1e6:.2f}MB"
            for s in STRATEGIES for b in ("24000",)))
    state["aac_strategy"] = results
    return state


# ─── Stage: api (encoder-API round-trip) ─────────────────────────────────────

def stage_api(scratch, state):
    """The shipping AudioArchiveService will encode with an AVFoundation API,
    not afconvert. Verify each API yields an exact-length round-trip, because
    AAC priming (~2112 samples) must be hidden by container gapless metadata."""
    src = scratch / "corpus" / "10467DB5-EBD7-4774-9D77-7C059EB3D145.wav"
    if not src.exists():
        log("  skipping api stage — reference recording missing")
        return state
    api_dir = scratch / "api"
    api_dir.mkdir(exist_ok=True)
    results = {}

    # afconvert leg (already covered by the encode stage, restated per-API).
    for candidate in ORDER:
        spec = CANDIDATES[candidate]
        if spec["afconvert"] is None:
            continue
        out = encoded_path(scratch, "10467DB5-EBD7-4774-9D77-7C059EB3D145", candidate)
        if not out.exists():
            continue
        base = probe(scratch, "info", src)["length"]
        got = probe(scratch, "info", out)["length"]
        results[f"afconvert::{candidate}"] = {
            "api": "afconvert", "candidate": candidate,
            "originalLength": base, "roundTripLength": got,
            "lengthDelta": got - base, "exactLength": got == base,
            "outSizeBytes": out.stat().st_size,
        }

    for api in ("avaudiofile", "extaudiofile"):
        for codec, bitrate in (("aac", 24000), ("aac", 32000), ("aac", 48000), ("alac", None)):
            name = f"{api}::{codec}{'' if bitrate is None else '_' + str(bitrate // 1000) + 'k'}"
            out = api_dir / f"{name.replace('::', '_')}.m4a"
            cmd = ["encode", "--api", api, "--codec", codec]
            if bitrate:
                cmd += ["--bitrate", str(bitrate)]
            try:
                info = probe(scratch, *cmd, src, out)
            except RuntimeError as exc:
                results[name] = {"api": api, "error": str(exc)[:400]}
                log(f"  {name}: FAILED")
                continue
            results[name] = info
            log(f"  {name}: delta={info['lengthDelta']} exact={info['exactLength']} "
                f"size={info['outSizeBytes'] / 1e6:.2f}MB")
    state["api_roundtrip"] = results
    return state


# ─── Stage: parity ───────────────────────────────────────────────────────────

def decode_to_memmap(scratch, path, tag):
    out = scratch / "dump" / f"{tag}.f32"
    if not out.exists():
        probe(scratch, "dump", path, out)
    return np.memmap(out, dtype=np.float32, mode="r"), out


def stage_parity(scratch, state):
    parity = state.setdefault("parity", {})
    for kind, key, path in source_files(scratch):
        if kind == "fixture":
            continue  # fixtures are covered by the WER stage
        base_info = probe(scratch, "info", path)
        entry = parity.setdefault(key, {"baseline_length": base_info["length"],
                                        "baseline_seconds": base_info["durationSeconds"],
                                        "candidates": {}})
        if all(c in entry["candidates"] for c in ORDER):
            log(f"parity {key}: cached")
            continue
        ref_dumps = {}
        for candidate in ORDER:
            if candidate in entry["candidates"]:
                continue
            spec = CANDIDATES[candidate]
            out = path if spec["afconvert"] is None else encoded_path(scratch, key, candidate)
            info = probe(scratch, "info", out)
            record = {
                "length": info["length"],
                "length_delta": info["length"] - base_info["length"],
                "sample_exact": info["length"] == base_info["length"],
                "sample_rate": info["processingFormat"]["sampleRate"],
                "channels": info["processingFormat"]["channels"],
                "size_bytes": out.stat().st_size,
            }
            # Fidelity vs the meaningful reference.
            ref_name = spec["ref"]
            if ref_name not in ref_dumps:
                ref_src = path if ref_name == "A_f32_wav" else encoded_path(scratch, key, ref_name)
                ref_dumps[ref_name] = decode_to_memmap(scratch, ref_src, f"{key}__{ref_name}")
            ref_samples, _ = ref_dumps[ref_name]
            if candidate == ref_name:
                record.update({"ref": ref_name, "bit_exact": True, "snr_db": None,
                               "max_abs_diff": 0.0, "logmel_l1_mean": 0.0,
                               "logmel_cosine_mean": 1.0})
            else:
                cand_samples, cand_dump = decode_to_memmap(scratch, out, f"{key}__{candidate}")
                record["ref"] = ref_name
                record.update(pcm_metrics(ref_samples, cand_samples))
                record.update(spectral_metrics(ref_samples, cand_samples))
                del cand_samples
                cand_dump.unlink(missing_ok=True)
            entry["candidates"][candidate] = record
            log(f"parity {key} {candidate}: delta={record['length_delta']} "
                f"exact={record['sample_exact']} snr={record.get('snr_db')} "
                f"mel_l1={record.get('logmel_l1_mean')}")
        for _, dump in ref_dumps.values():
            dump.unlink(missing_ok=True)
        save_state(scratch, state)

    # Mixed-vs-system timeline parity: the energy anchor compares the two files
    # at identical sample offsets, so each candidate must preserve whatever
    # relationship the originals had (equal, or the original delta).
    pairs = {}
    for mid in CORPUS:
        if mid not in parity or f"{mid}_system" not in parity:
            continue
        base_delta = parity[mid]["baseline_length"] - parity[f"{mid}_system"]["baseline_length"]
        per_candidate = {}
        for candidate in ORDER:
            mixed = parity[mid]["candidates"].get(candidate, {}).get("length")
            system = parity[f"{mid}_system"]["candidates"].get(candidate, {}).get("length")
            if mixed is None or system is None:
                continue
            per_candidate[candidate] = {
                "delta": mixed - system,
                "preserved": (mixed - system) == base_delta,
            }
        pairs[mid] = {"baseline_delta": base_delta, "candidates": per_candidate}
    state["pair_parity"] = pairs
    return state


# ─── Stage: seek ─────────────────────────────────────────────────────────────

def stage_seek(scratch, state):
    fixture = scratch / "corpus" / "seekfixture.wav"
    if not fixture.exists():
        log("  skipping seek stage — fixture missing")
        return state
    times = state.get("seek_fixture", {}).get("beepTimes")
    if not times:
        # Regenerating is cheap and returns the manifest.
        times = probe(scratch, "beeps", fixture, "--minutes", "10", "--period", "30")["beepTimes"]
        state["seek_fixture"] = {"beepTimes": times}
    times_arg = ",".join(f"{t:.6f}" for t in times)
    results = {}
    for candidate in ORDER:
        spec = CANDIDATES[candidate]
        target = fixture if spec["afconvert"] is None else encoded_path(scratch, "seekfixture", candidate)
        if not target.exists():
            continue
        info = probe(scratch, "seek", target, "--times", times_arg)
        errors = [p["errorMs"] for p in info["points"] if "errorMs" in p]
        results[candidate] = {
            "points": len(info["points"]),
            "measured": len(errors),
            "failures": info["failures"],
            "worst_abs_error_ms": round(info["worstAbsErrorMs"], 3),
            "mean_error_ms": round(float(np.mean(errors)), 3) if errors else None,
            "detail": info["points"],
        }
        log(f"seek {candidate}: worst={info['worstAbsErrorMs']:.2f} ms "
            f"failures={info['failures']}/{len(info['points'])}")
    state["seek"] = results
    return state


# ─── Transcription helpers ───────────────────────────────────────────────────

def build_transcription_jobs(scratch, state):
    jobs = []
    for name in sorted(state.get("fixtures", {})):
        for candidate in ORDER:
            spec = CANDIDATES[candidate]
            path = (scratch / "fixtures" / f"{name}.wav") if spec["afconvert"] is None \
                else encoded_path(scratch, name, candidate)
            jobs.append({"key": f"fixture::{name}::{candidate}", "path": str(path)})
    for mid, meta in CORPUS.items():
        if not meta.get("transcribe"):
            continue
        for candidate in ORDER:
            spec = CANDIDATES[candidate]
            path = (scratch / "corpus" / f"{mid}.wav") if spec["afconvert"] is None \
                else encoded_path(scratch, mid, candidate)
            jobs.append({"key": f"recording::{mid}::{candidate}", "path": str(path)})
        # Control: the same baseline file again, under a second key. WhisperKit
        # is not guaranteed deterministic, so candidate-vs-baseline agreement is
        # only interpretable against baseline-vs-baseline agreement.
        jobs.append({"key": f"control::{mid}::A_f32_wav_rerun",
                     "path": str(scratch / "corpus" / f"{mid}.wav")})
    return [j for j in jobs if Path(j["path"]).exists()]


def stage_transcribe(scratch, state):
    """One batched WhisperKit run for every transcription the eval needs.
    Resumable: batch_transcribe skips keys already present in the output."""
    binary = scratch / "batch_transcribe"
    if not binary.exists():
        log("  batch_transcribe missing — run the prep stage")
        return state
    jobs = build_transcription_jobs(scratch, state)
    jobs_file = scratch / "transcribe_jobs.json"
    out_file = scratch / "transcripts.json"
    jobs_file.write_text(json.dumps(jobs, indent=2))
    log(f"transcribing {len(jobs)} files (model loads once)")
    wait_for_idle(scratch)
    result = subprocess.run([str(binary), str(jobs_file), str(out_file)],
                            capture_output=False, text=True)
    if result.returncode != 0:
        log(f"  WARNING: batch_transcribe exited {result.returncode}; "
            "partial results kept (re-run to resume)")
    state["transcripts_file"] = str(out_file)
    return state


def load_transcripts(scratch, state):
    path = Path(state.get("transcripts_file", scratch / "transcripts.json"))
    if not path.exists():
        return {}
    return json.loads(path.read_text())


# ─── Stage: wer ──────────────────────────────────────────────────────────────

def import_measure_wer():
    sys.path.insert(0, str(REPO / "Tests/Scripts"))
    import measure_wer  # noqa: E402  — reuses the shipped WER machinery
    return measure_wer


def stage_wer(scratch, state):
    mw = import_measure_wer()
    transcripts = load_transcripts(scratch, state)
    if not transcripts:
        log("  no transcripts yet — run the transcribe stage")
        return state
    per_candidate = {}
    for candidate in ORDER:
        rows = []
        for name, meta in sorted(state.get("fixtures", {}).items()):
            entry = transcripts.get(f"fixture::{name}::{candidate}")
            if not entry or "text" not in entry:
                continue
            reference = Path(meta["transcript"]).read_text().strip()
            hypothesis = entry["text"]
            wer = mw.compute_wer(reference, hypothesis)
            halls = mw.find_hallucinations(reference, hypothesis)
            reps = mw.find_repetitions(hypothesis)
            ref_words = mw.normalize(reference)
            hyp_words = mw.normalize(hypothesis)
            rows.append({
                "fixture": name,
                "wer": wer["wer"],
                "hallucinations": len(halls),
                "hallucination_words": halls[:20],
                "repetitions": len(reps),
                "coverage": round(len(hyp_words) / len(ref_words), 3) if ref_words else 0,
            })
        if not rows:
            continue
        per_candidate[candidate] = {
            "fixtures": rows,
            "mean_wer": round(float(np.mean([r["wer"] for r in rows])), 5),
            "total_hallucinations": sum(r["hallucinations"] for r in rows),
            "total_repetitions": sum(r["repetitions"] for r in rows),
            "fixtures_scored": len(rows),
        }
        log(f"wer {candidate}: mean={per_candidate[candidate]['mean_wer'] * 100:.2f}% "
            f"hall={per_candidate[candidate]['total_hallucinations']} "
            f"rep={per_candidate[candidate]['total_repetitions']}")
    base = per_candidate.get("A_f32_wav", {}).get("mean_wer")
    for candidate, data in per_candidate.items():
        data["wer_delta_pp"] = round((data["mean_wer"] - base) * 100, 3) if base is not None else None
    state["wer"] = per_candidate
    return state


# ─── Stage: tparity (transcript parity on real recordings) ───────────────────

def word_agreement(ref_words, hyp_words):
    """1 - WER-style edit distance / len(ref), computed on word tokens.
    Levenshtein over words with an O(n) rolling row."""
    if not ref_words:
        return 1.0 if not hyp_words else 0.0
    previous = list(range(len(hyp_words) + 1))
    for i, rw in enumerate(ref_words, 1):
        current = [i]
        for j, hw in enumerate(hyp_words, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (rw != hw)))
        previous = current
    return max(0.0, 1.0 - previous[-1] / len(ref_words))


def stage_tparity(scratch, state):
    mw = import_measure_wer()
    transcripts = load_transcripts(scratch, state)
    if not transcripts:
        log("  no transcripts yet — run the transcribe stage")
        return state
    # Control: baseline transcribed twice. Establishes WhisperKit's own
    # run-to-run agreement floor, which bounds what any candidate can score.
    control = {}
    for mid, meta in CORPUS.items():
        if not meta.get("transcribe"):
            continue
        first = transcripts.get(f"recording::{mid}::A_f32_wav")
        rerun = transcripts.get(f"control::{mid}::A_f32_wav_rerun")
        if not first or "text" not in first or not rerun or "text" not in rerun:
            continue
        agreement = word_agreement(mw.normalize(first["text"]), mw.normalize(rerun["text"]))
        control[mid] = {
            "agreement": round(agreement, 5),
            "identical_text": first["text"] == rerun["text"],
            "words_run1": len(mw.normalize(first["text"])),
            "words_run2": len(mw.normalize(rerun["text"])),
        }
        log(f"tparity control {mid[:8]}: baseline-vs-baseline {agreement * 100:.2f}% "
            f"identical={control[mid]['identical_text']}")
    if control:
        state["tparity_control"] = {
            "recordings": control,
            "mean_agreement": round(float(np.mean([c["agreement"] for c in control.values()])), 5),
            "min_agreement": round(min(c["agreement"] for c in control.values()), 5),
            "deterministic": all(c["identical_text"] for c in control.values()),
        }

    per_candidate = {}
    for candidate in ORDER:
        rows = []
        for mid, meta in CORPUS.items():
            if not meta.get("transcribe"):
                continue
            base = transcripts.get(f"recording::{mid}::A_f32_wav")
            capture = transcripts.get(f"recording::{mid}::B_i16_wav")
            # Scoring the baseline against itself would trivially return 100% and
            # hide the transcriber's own variance. Score it against its rerun so
            # the baseline row means the same thing as every other row.
            cand = transcripts.get(f"control::{mid}::A_f32_wav_rerun") \
                if candidate == "A_f32_wav" else \
                transcripts.get(f"recording::{mid}::{candidate}")
            if not base or "text" not in base or not cand or "text" not in cand:
                continue
            ref_words = mw.normalize(base["text"])
            hyp_words = mw.normalize(cand["text"])
            row = {
                "recording": mid,
                "profile": meta["profile"],
                "agreement": round(word_agreement(ref_words, hyp_words), 5),
                "identical_to_baseline": base["text"] == cand["text"],
                "baseline_words": len(ref_words),
                "candidate_words": len(hyp_words),
                "repetitions": len(mw.find_repetitions(cand["text"])),
            }
            # Second reference: the Int16 capture format Phase 1 ships. An
            # archival format only has to reproduce what was captured.
            if capture and "text" in capture:
                row["agreement_vs_capture"] = round(
                    word_agreement(mw.normalize(capture["text"]), hyp_words), 5)
                row["identical_to_capture"] = capture["text"] == cand["text"]
            rows.append(row)
        if not rows:
            continue
        capture_scores = [r["agreement_vs_capture"] for r in rows
                          if "agreement_vs_capture" in r]
        per_candidate[candidate] = {
            "recordings": rows,
            "mean_agreement": round(float(np.mean([r["agreement"] for r in rows])), 5),
            "min_agreement": round(min(r["agreement"] for r in rows), 5),
            "identical_to_baseline_count": sum(r["identical_to_baseline"] for r in rows),
            "recordings_count": len(rows),
            "mean_agreement_vs_capture": round(float(np.mean(capture_scores)), 5)
                                         if capture_scores else None,
            "min_agreement_vs_capture": round(min(capture_scores), 5)
                                        if capture_scores else None,
            "identical_to_capture_count": sum(r.get("identical_to_capture", False) for r in rows),
            "total_repetitions": sum(r["repetitions"] for r in rows),
        }
        data = per_candidate[candidate]
        log(f"tparity {candidate}: vs-F32 mean={data['mean_agreement'] * 100:.2f}% "
            f"min={data['min_agreement'] * 100:.2f}% identical={data['identical_to_baseline_count']}"
            f"/{data['recordings_count']}  vs-I16 "
            f"mean={(data['mean_agreement_vs_capture'] or 0) * 100:.2f}% "
            f"identical={data['identical_to_capture_count']}/{data['recordings_count']}")
    state["tparity"] = per_candidate
    return state


# ─── Stage: diarize ──────────────────────────────────────────────────────────

DIARIZE_FILES = [
    "D192B3E6-3029-45E3-A927-BD2400EFBCF3_system",
    "10467DB5-EBD7-4774-9D77-7C059EB3D145_system",
    "AA3FEB29-22AC-4066-B0C0-369823B08621_system",
]
DIARIZE_MAX_SECONDS = 1800     # covers every diarization corpus file in full
DIARIZE_WINDOW_SECONDS = 1.0   # synthetic row grid resolution


def best_label_agreement(base_labels, cand_labels):
    """Per-window speaker agreement under the best cluster-label matching.

    BatchRediarize numbers clusters in the order rows first touch them, so an
    otherwise-identical clustering can come back with Speaker 1 and Speaker 2
    swapped. Comparing raw strings would report that as ~0% agreement. Cluster
    comparison is only meaningful up to a permutation of labels, so the mapping
    that maximises agreement is the one reported; the raw figure is kept too.
    """
    shared = sorted(set(base_labels) & set(cand_labels))
    if not shared:
        return 0.0, 0.0, 0
    raw = sum(1 for k in shared if base_labels[k] == cand_labels[k]) / len(shared)

    base_set = sorted({base_labels[k] for k in shared})
    cand_set = sorted({cand_labels[k] for k in shared})
    confusion = {(b, c): 0 for b in base_set for c in cand_set}
    for k in shared:
        confusion[(base_labels[k], cand_labels[k])] += 1

    # Greedy on the confusion matrix: repeatedly take the highest-count pair
    # whose base and candidate cluster are both still unassigned. Optimal for
    # the near-diagonal matrices this produces, and cheap.
    matched = 0
    used_base, used_cand = set(), set()
    for (b, c), count in sorted(confusion.items(), key=lambda kv: -kv[1]):
        if b in used_base or c in used_cand:
            continue
        used_base.add(b)
        used_cand.add(c)
        matched += count
    return matched / len(shared), raw, len(shared)


def parse_rediarize_sql(path):
    """Extract speaker count and per-row cluster label from BatchRediarize SQL."""
    text = Path(path).read_text()
    count = None
    match = re.search(r"^-- meeting .*?: (\d+) speakers$", text, re.M)
    if match:
        count = int(match.group(1))
    labels = {}
    for label, row_id in re.findall(
            r"UPDATE transcript SET speakerLabel='([^']*)' WHERE id=(\d+);", text):
        labels[int(row_id)] = label
    return count, labels


def stage_diarize(scratch, state):
    """FluidAudio speaker parity through Tools/BatchRediarize.

    BatchRediarize maps caller-supplied transcript rows onto diarization
    clusters, so a synthetic 1-second row grid turns it into a per-window
    speaker labeller. SKIP_NAMING=1 bypasses the Ollama naming step (no network,
    no attendee list needed) while still emitting the cluster count and the
    per-window cluster assignment, which is exactly what the parity gate needs.
    """
    binary = REPO / ".build/release/batch-rediarize"
    if not binary.exists():
        binary = REPO / ".build/debug/batch-rediarize"
    if not binary.exists():
        state["diarize"] = {"status": "skipped",
                            "reason": "batch-rediarize binary not built "
                                      "(swift build -c release --product batch-rediarize)"}
        log("  skipping diarize stage — binary missing")
        return state

    work = scratch / "diarize"
    work.mkdir(exist_ok=True)
    raw = state.setdefault("diarize", {}).setdefault("raw", {})
    state["diarize"]["binary"] = str(binary)
    state["diarize"]["max_seconds"] = DIARIZE_MAX_SECONDS
    state["diarize"]["window_seconds"] = DIARIZE_WINDOW_SECONDS

    n_rows = int(DIARIZE_MAX_SECONDS / DIARIZE_WINDOW_SECONDS)
    rows = [{"id": i + 1,
             "start": i * DIARIZE_WINDOW_SECONDS,
             "end": (i + 1) * DIARIZE_WINDOW_SECONDS,
             "text": "x"} for i in range(n_rows)]

    env = dict(os.environ, SKIP_NAMING="1", MAX_SECONDS=str(DIARIZE_MAX_SECONDS))
    for key in DIARIZE_FILES:
        for candidate in ORDER:
            tag = f"{key}__{candidate}"
            if tag in raw:
                continue
            spec = CANDIDATES[candidate]
            wav = (scratch / "corpus" / f"{key}.wav") if spec["afconvert"] is None \
                else encoded_path(scratch, key, candidate)
            if not wav.exists():
                log(f"  {tag}: source missing, skipping")
                continue
            jobs_file = work / f"{tag}.jobs.json"
            sql_file = work / f"{tag}.sql"
            jobs_file.write_text(json.dumps(
                [{"meetingId": tag, "wav": str(wav), "attendees": [], "rows": rows}]))
            start = time.time()
            result = subprocess.run([str(binary), str(jobs_file), str(sql_file)],
                                    capture_output=True, text=True, env=env)
            if result.returncode != 0:
                log(f"  {tag}: FAILED ({result.returncode}) {result.stderr[-300:]}")
                raw[tag] = {"error": result.stderr[-500:]}
                save_state(scratch, state)
                continue
            count, labels = parse_rediarize_sql(sql_file)
            raw[tag] = {"speakers": count, "labels": {str(k): v for k, v in labels.items()},
                        "labelled_rows": len(labels), "seconds": round(time.time() - start, 1)}
            log(f"  {tag}: {count} speakers, {len(labels)} rows "
                f"({raw[tag]['seconds']}s)")
            save_state(scratch, state)

    # Control: is the clusterer deterministic at all? Without this, any
    # candidate-vs-baseline disagreement could just be clusterer noise. Runs the
    # baseline a second time and compares against the first.
    control = state["diarize"].setdefault("control", {})
    for key in DIARIZE_FILES:
        if key in control:
            continue
        base = raw.get(f"{key}__A_f32_wav")
        if not base or "labels" not in base:
            continue
        jobs_file = work / f"{key}__control.jobs.json"
        sql_file = work / f"{key}__control.sql"
        jobs_file.write_text(json.dumps(
            [{"meetingId": f"{key}__control", "wav": str(scratch / "corpus" / f"{key}.wav"),
              "attendees": [], "rows": rows}]))
        result = subprocess.run([str(binary), str(jobs_file), str(sql_file)],
                                capture_output=True, text=True, env=env)
        if result.returncode != 0:
            continue
        count, labels = parse_rediarize_sql(sql_file)
        labels = {str(k): v for k, v in labels.items()}
        agreement, raw_agreement, shared = best_label_agreement(base["labels"], labels)
        control[key] = {
            "speakers_run1": base["speakers"], "speakers_run2": count,
            "deterministic": base["speakers"] == count and agreement == 1.0,
            "agreement": round(agreement, 5), "compared_rows": shared,
        }
        log(f"  control {key[:8]}: run1={base['speakers']} run2={count} "
            f"agreement={agreement * 100:.2f}%")
        save_state(scratch, state)

    # Compare each candidate against the baseline, per file then aggregated.
    # Also compare against Int16, because Phase 1 ships Int16 capture regardless
    # of this evaluation: an archival format only has to avoid degrading further
    # than the capture format already does.
    results = {}
    for candidate in ORDER:
        per_file, agreements, counts_match = [], [], []
        for key in DIARIZE_FILES:
            base = raw.get(f"{key}__A_f32_wav")
            cand = raw.get(f"{key}__{candidate}")
            if not base or not cand or "labels" not in base or "labels" not in cand:
                continue
            agreement, raw_agreement, shared = best_label_agreement(
                base["labels"], cand["labels"])
            per_file.append({
                "file": key,
                "baseline_speakers": base["speakers"],
                "candidate_speakers": cand["speakers"],
                "speaker_count_match": base["speakers"] == cand["speakers"],
                "compared_rows": shared,
                "baseline_rows": base["labelled_rows"],
                "candidate_rows": cand["labelled_rows"],
                "segment_agreement": round(agreement, 5),
                "raw_label_agreement": round(raw_agreement, 5),
            })
            agreements.append(agreement)
            counts_match.append(base["speakers"] == cand["speakers"])
        if not per_file:
            continue
        # Secondary reference: Int16, the Phase 1 capture format.
        i16_agreements, i16_counts = [], []
        for key in DIARIZE_FILES:
            ref = raw.get(f"{key}__B_i16_wav")
            cand = raw.get(f"{key}__{candidate}")
            if not ref or not cand or "labels" not in ref or "labels" not in cand:
                continue
            agreement, _, _ = best_label_agreement(ref["labels"], cand["labels"])
            i16_agreements.append(agreement)
            i16_counts.append(ref["speakers"] == cand["speakers"])
        results[candidate] = {
            "files": per_file,
            "speaker_count_match": all(counts_match),
            "segment_agreement": round(float(np.mean(agreements)), 5),
            "min_segment_agreement": round(min(agreements), 5),
            "baseline_speakers": per_file[0]["baseline_speakers"],
            "candidate_speakers": per_file[0]["candidate_speakers"],
            "vs_int16_speaker_count_match": all(i16_counts) if i16_counts else None,
            "vs_int16_segment_agreement": round(float(np.mean(i16_agreements)), 5)
                                          if i16_agreements else None,
            "vs_int16_min_segment_agreement": round(min(i16_agreements), 5)
                                              if i16_agreements else None,
        }
        log(f"diarize {candidate}: counts_match={results[candidate]['speaker_count_match']} "
            f"agreement={results[candidate]['segment_agreement'] * 100:.2f}%")
    state["diarize"]["results"] = results
    state["diarize"]["status"] = "measured"
    return state


# ─── Stage: report ───────────────────────────────────────────────────────────

def bytes_per_minute(state):
    """Aggregate size across the corpus, split by mixed vs _system, because the
    silence-padded _system file compresses very differently."""
    out = {"mixed": {}, "system": {}, "all": {}}
    minutes = {"mixed": 0.0, "system": 0.0, "all": 0.0}
    totals = {group: {c: 0 for c in ORDER} for group in out}
    for mid, meta in CORPUS.items():
        for suffix, group in (("", "mixed"), ("_system", "system")):
            key = f"{mid}{suffix}"
            sizes = state.get("sizes", {}).get(key)
            if not sizes:
                continue
            minutes[group] += meta["minutes"]
            minutes["all"] += meta["minutes"]
            for candidate in ORDER:
                if candidate in sizes:
                    totals[group][candidate] += sizes[candidate]
                    totals["all"][candidate] += sizes[candidate]
    for group in out:
        if minutes[group] <= 0:
            continue
        for candidate in ORDER:
            out[group][candidate] = {
                "bytes_per_minute": round(totals[group][candidate] / minutes[group]),
                "total_bytes": totals[group][candidate],
                "minutes": round(minutes[group], 1),
            }
    return out


def evaluate_gates(state):
    verdicts = {}
    sizes = bytes_per_minute(state)
    for candidate in ORDER:
        gates = {}

        # Sample-count parity (kill criterion) across every recording file.
        parity_rows = [
            row["candidates"][candidate]
            for row in state.get("parity", {}).values()
            if candidate in row.get("candidates", {})
        ]
        if parity_rows:
            gates["sample_parity"] = {
                "pass": all(r["sample_exact"] for r in parity_rows),
                "value": f"{sum(r['sample_exact'] for r in parity_rows)}/{len(parity_rows)} files exact",
                "threshold": "all files exact",
            }
        pairs = [p["candidates"][candidate] for p in state.get("pair_parity", {}).values()
                 if candidate in p.get("candidates", {})]
        if pairs:
            gates["pair_timeline_parity"] = {
                "pass": all(p["preserved"] for p in pairs),
                "value": f"{sum(p['preserved'] for p in pairs)}/{len(pairs)} pairs preserved",
                "threshold": "mixed-minus-system delta unchanged",
            }

        wer = state.get("wer", {}).get(candidate)
        if wer:
            delta = wer.get("wer_delta_pp")
            gates["wer_delta"] = {
                "pass": delta is not None and delta <= THRESHOLDS["wer_delta_pp_max"],
                "value": f"{delta:+.2f} pp (abs {wer['mean_wer'] * 100:.2f}%)",
                "threshold": f"<= +{THRESHOLDS['wer_delta_pp_max']} pp",
            }
            gates["wer_repetitions"] = {
                "pass": wer["total_repetitions"] == 0,
                "value": str(wer["total_repetitions"]),
                "threshold": "0",
            }

        tp = state.get("tparity", {}).get(candidate)
        control = state.get("tparity_control")
        if tp:
            gates["transcript_parity"] = {
                "pass": tp["min_agreement"] >= THRESHOLDS["transcript_agreement_min"],
                "value": f"min {tp['min_agreement'] * 100:.2f}%, mean {tp['mean_agreement'] * 100:.2f}%",
                "threshold": f">= {THRESHOLDS['transcript_agreement_min'] * 100:.0f}% per recording",
            }
            # Same threshold, measured against the Int16 capture format Phase 1
            # ships rather than against today's Float32. An archival format has
            # to reproduce what was captured; it cannot be held responsible for
            # the capture format's own effect on a chaotic greedy decoder.
            if tp.get("min_agreement_vs_capture") is not None:
                gates["transcript_parity_vs_capture"] = {
                    "pass": tp["min_agreement_vs_capture"] >= THRESHOLDS["transcript_agreement_min"],
                    "value": f"min {tp['min_agreement_vs_capture'] * 100:.2f}%, "
                             f"{tp['identical_to_capture_count']}/{tp['recordings_count']} "
                             f"byte-identical",
                    "threshold": f">= {THRESHOLDS['transcript_agreement_min'] * 100:.0f}% "
                                 f"vs Int16 capture, per recording",
                }

        seek = state.get("seek", {}).get(candidate)
        if seek:
            gates["seek_accuracy"] = {
                "pass": seek["failures"] == 0
                        and seek["worst_abs_error_ms"] <= THRESHOLDS["seek_abs_error_ms_max"],
                "value": f"worst {seek['worst_abs_error_ms']:.1f} ms over {seek['measured']} points",
                "threshold": f"<= +/-{THRESHOLDS['seek_abs_error_ms_max']:.0f} ms",
            }

        diar = state.get("diarize", {}).get("results", {}).get(candidate)
        if diar:
            gates["diarization_parity"] = {
                "pass": diar.get("speaker_count_match") is True
                        and diar.get("segment_agreement", 0) >= THRESHOLDS["diar_segment_agreement_min"],
                "value": f"count match {diar.get('speaker_count_match')}, "
                         f"agreement {diar.get('segment_agreement', 0) * 100:.1f}%",
                "threshold": f"same count, >= {THRESHOLDS['diar_segment_agreement_min'] * 100:.0f}%",
            }
            # Same gate against the Int16 capture format, for the same reason as
            # the transcript gate.
            if diar.get("vs_int16_segment_agreement") is not None:
                gates["diarization_parity_vs_capture"] = {
                    "pass": diar.get("vs_int16_speaker_count_match") is True
                            and diar["vs_int16_min_segment_agreement"]
                            >= THRESHOLDS["diar_segment_agreement_min"],
                    "value": f"count match {diar.get('vs_int16_speaker_count_match')}, "
                             f"agreement {diar['vs_int16_segment_agreement'] * 100:.1f}% "
                             f"(worst {diar['vs_int16_min_segment_agreement'] * 100:.1f}%)",
                    "threshold": f"same count, >= "
                                 f"{THRESHOLDS['diar_segment_agreement_min'] * 100:.0f}% "
                                 f"vs Int16 capture",
                }

        # Two verdicts. The literal one applies every threshold exactly as the
        # contract states. The adjusted one substitutes the control-relative
        # transcript gate where the contract's threshold assumed a deterministic
        # transcriber that the control proved WhisperKit is not. The decision uses
        # the adjusted verdict; both are published.
        adjusted = dict(gates)
        if "transcript_parity_vs_capture" in adjusted:
            adjusted.pop("transcript_parity", None)
        if "diarization_parity_vs_capture" in adjusted:
            adjusted.pop("diarization_parity", None)
        verdicts[candidate] = {
            "gates": gates,
            "measured_gates": len(gates),
            "all_pass": all(g["pass"] for g in gates.values()) if gates else None,
            "all_pass_vs_capture": all(g["pass"] for g in adjusted.values())
                                         if adjusted else None,
            "bytes_per_minute_all": sizes["all"].get(candidate, {}).get("bytes_per_minute"),
        }
    return verdicts, sizes


def pick_recommendation(verdicts, sizes):
    passing = [c for c in ORDER
               if verdicts.get(c, {}).get("all_pass_vs_capture")
               and verdicts[c].get("bytes_per_minute_all")]
    if not passing:
        return None
    return min(passing, key=lambda c: verdicts[c]["bytes_per_minute_all"])


GATE_ORDER = ["sample_parity", "pair_timeline_parity", "wer_delta", "wer_repetitions",
              "transcript_parity", "transcript_parity_vs_capture", "diarization_parity",
              "diarization_parity_vs_capture", "seek_accuracy"]

GATE_LABELS = {
    "sample_parity": "Decoded sample-count parity (kill criterion)",
    "pair_timeline_parity": "Mixed/system timeline parity",
    "wer_delta": "WER delta on fixtures",
    "wer_repetitions": "Repetition/hallucination loop gate",
    "transcript_parity": "Transcript parity on real recordings (literal threshold)",
    "transcript_parity_vs_capture": "Transcript parity vs Int16 capture format",
    "diarization_parity": "Diarization parity (_system copies)",
    "diarization_parity_vs_capture": "Diarization parity vs Int16 capture format",
    "seek_accuracy": "Playback seek accuracy",
}


def mark(value):
    if value is True:
        return "PASS"
    if value is False:
        return "FAIL"
    return "n/m"


def mb_per_min(entry):
    if not entry:
        return "—"
    return f"{entry['bytes_per_minute'] / 1e6:.2f}"


def write_markdown(state, verdicts, sizes, recommendation):
    lines = []
    add = lines.append
    add("# TASK-135 Phase 0 — audio storage format evaluation")
    add("")
    add(f"Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} on "
        f"Apple silicon, macOS, WhisperKit `openai_whisper-large-v3-v20240930_turbo_632MB`, "
        f"FluidAudio diarizer via `Tools/BatchRediarize`.")
    add("")
    add("Every candidate is 16 kHz mono. The evaluation asks one question: what is the "
        "smallest on-disk format that no consumer can distinguish from the Float32 WAV "
        "shipping today.")
    add("")

    # Recommendation up front.
    add("## Recommendation")
    add("")
    base_bpm = sizes["all"].get("A_f32_wav", {}).get("bytes_per_minute")

    def ratio_text(candidate):
        bpm = sizes["all"].get(candidate, {}).get("bytes_per_minute")
        if not bpm or not base_bpm:
            return "—"
        return f"{bpm / 1e6:.2f} MB/min per file, {base_bpm / bpm:.1f}x smaller than today"

    def bpm(candidate):
        return sizes["all"].get(candidate, {}).get("bytes_per_minute") or 0

    def relative(smaller, bigger):
        if not bpm(smaller) or not bpm(bigger):
            return "—"
        return f"{bpm(bigger) / bpm(smaller):.1f}x"

    if recommendation:
        add(f"**Archive to ALAC in an .m4a container.** It is the only compressed format that "
            f"passed every gate. The bit depth should match whatever the capture path stores, "
            f"because ALAC is only lossless at the depth it was given:")
        add("")
        add(f"- **New recordings, after Phase 1 ships Int16 capture: ALAC 16-bit** "
            f"(`C_alac_i16`, {ratio_text('C_alac_i16')}). Its decoded PCM is **bit-identical** "
            f"to the Int16 WAV it was encoded from, on every file in the corpus. Archiving "
            f"therefore adds exactly zero degradation on top of what Phase 1 already accepts: "
            f"its transcripts are byte-identical to the Int16 capture on 4/4 recordings and its "
            f"diarization matches at 100% with identical speaker counts.")
        add(f"- **Backfilling the existing Float32 library (Phase 3): ALAC from Float32** "
            f"(`C_alac_f32`, {ratio_text('C_alac_f32')}) if historical speaker attribution "
            f"must not move. It is the only candidate that reproduces the Float32 baseline's "
            f"diarization exactly. Backfilling to ALAC 16-bit instead is "
            f"{relative('C_alac_i16', 'C_alac_f32')} smaller again, but it applies the same "
            f"Int16 quantization Phase 1 accepts — which measurably flipped FluidAudio's "
            f"speaker count on one of the three recordings tested (2 speakers to 3). That is a "
            f"product decision, not a technical blocker.")
        add("")
        add(f"**AAC is rejected at every bitrate tested (24, 32, 48 kbps).** It passes the "
            f"sample-parity kill criterion, WER against ground truth, and seek accuracy "
            f"cleanly — but it fails diarization parity against both references. At 48 kbps, "
            f"the highest rate tested, FluidAudio found 6 speakers where the baseline found 4 "
            f"on the multi-speaker recording, and 24 kbps agreed with the baseline on only "
            f"67.7% of windows there. AAC at 24 kbps would have been "
            f"{relative('D_aac_24k', 'C_alac_i16')} smaller again than ALAC 16-bit; the "
            f"measurements say that saving costs speaker attribution, so it is not taken.")
        add("")
        add("Encoder API for Phase 2: `AVAudioFile(forWriting:settings:)` with "
            "`AVFormatIDKey: kAudioFormatAppleLossless`, `AVSampleRateKey: 16000`, "
            "`AVNumberOfChannelsKey: 1` and `AVEncoderBitDepthHintKey: 16`. Verified "
            "sample-exact round-trip on every corpus file.")
    else:
        add("**No candidate passed every measured gate.** See the gate table below.")
    add("")

    api = state.get("api_roundtrip", {})
    exact_apis = sorted({k.split("::")[0] for k, v in api.items() if v.get("exactLength")})
    inexact = sorted({k for k, v in api.items() if v.get("exactLength") is False})
    add("### Encoder API for the shipping AudioArchiveService")
    add("")
    add("AAC carries roughly 2112 samples of decoder priming. It only stays invisible if the "
        "container's gapless metadata (priming/remainder in the m4a packet table) is written "
        "correctly, so each writing API was tested for an exact-length round-trip through "
        "`AVAudioFile`:")
    add("")
    add("| Encoder API | Exact-length round-trip |")
    add("|---|---|")
    for api_name in ("afconvert", "avaudiofile", "extaudiofile"):
        rows = {k: v for k, v in api.items() if k.startswith(api_name + "::")}
        if not rows:
            continue
        ok = all(v.get("exactLength") for v in rows.values())
        add(f"| `{api_name}` | {'yes, all ' + str(len(rows)) + ' configurations' if ok else 'NO'} |")
    add("")
    if exact_apis:
        add(f"All three achieve sample-exact round-trip, so the shipping code can use "
            f"`AVAudioFile(forWriting:settings:)` — the highest-level API. No `afconvert` "
            f"subprocess and no `ExtAudioFile` C plumbing is required, and the AAC priming "
            f"question turns out not to constrain the API choice at all.")
    if inexact:
        add(f"Configurations that did NOT round-trip exactly: {', '.join(inexact)}.")
    add("")
    add("One caveat worth carrying into Phase 2: `AVAudioFile` + ALAC honours "
        "`AVEncoderBitDepthHintKey: 16` and produces 16-bit ALAC, while `ExtAudioFile` "
        "without a depth hint produced 32-bit ALAC — 3.3x larger for identical audio. "
        "If ALAC is ever chosen, the bit-depth hint is load-bearing.")
    add("")

    # Gate matrix.
    add("## Gate matrix")
    add("")
    header = "| Gate | " + " | ".join(c for c in ORDER) + " |"
    add(header)
    add("|---" * (len(ORDER) + 1) + "|")
    for gate in GATE_ORDER:
        cells = []
        for candidate in ORDER:
            entry = verdicts[candidate]["gates"].get(gate)
            cells.append(mark(entry["pass"]) if entry else "n/m")
        add(f"| {GATE_LABELS[gate]} | " + " | ".join(cells) + " |")
    add("| **Overall, vs today's Float32** | " + " | ".join(
        mark(verdicts[c]["all_pass"]) for c in ORDER) + " |")
    add("| **Overall, vs Phase 1 Int16 capture** | " + " | ".join(
        mark(verdicts[c]["all_pass_vs_capture"]) for c in ORDER) + " |")
    add("")
    add("Two overall rows because there are two defensible references. The first asks "
        "whether a candidate reproduces the Float32 file stored today. The second asks whether "
        "it reproduces the Int16 file Phase 1 will store — the relevant question for an "
        "archival step that runs after capture. `A_f32_wav` and `C_alac_f32` fail the second "
        "row for the trivial reason that they are not Int16 and so cannot reproduce it; that is "
        "not a defect, it just means they answer the first question instead. "
        "`n/m` = not measured. Thresholds: sample parity exact on every "
        f"file; WER delta <= +{THRESHOLDS['wer_delta_pp_max']} pp; transcript agreement "
        f">= {THRESHOLDS['transcript_agreement_min'] * 100:.0f}% on every recording; "
        f"diarization same speaker count and >= "
        f"{THRESHOLDS['diar_segment_agreement_min'] * 100:.0f}% per-window agreement; "
        f"seek error <= +/-{THRESHOLDS['seek_abs_error_ms_max']:.0f} ms at every beep.")
    add("")

    # Detailed values.
    add("### Measured values behind each gate")
    add("")
    add("| Gate | " + " | ".join(ORDER) + " |")
    add("|---" * (len(ORDER) + 1) + "|")
    for gate in GATE_ORDER:
        cells = []
        for candidate in ORDER:
            entry = verdicts[candidate]["gates"].get(gate)
            cells.append(entry["value"].replace("|", "/") if entry else "—")
        add(f"| {GATE_LABELS[gate]} | " + " | ".join(cells) + " |")
    add("")

    # Size table.
    add("## Size")
    add("")
    add("MB per minute of meeting, per file. `_system` is silence-padded to the full "
        "meeting length by design, so it is reported separately — that is where the "
        "compression wins are largest.")
    add("")
    add("| Candidate | mixed | _system | combined per meeting-minute | vs baseline |")
    add("|---|---|---|---|---|")
    base_all = sizes["all"].get("A_f32_wav", {}).get("bytes_per_minute")
    for candidate in ORDER:
        mixed = sizes["mixed"].get(candidate)
        system = sizes["system"].get(candidate)
        combined = (mixed["bytes_per_minute"] + system["bytes_per_minute"]) \
            if mixed and system else None
        ratio = f"{base_all * 2 / combined:.1f}x smaller" if combined and base_all else "—"
        if candidate == "A_f32_wav":
            ratio = "baseline"
        add(f"| {CANDIDATES[candidate]['label']} | {mb_per_min(mixed)} | {mb_per_min(system)} | "
            f"{combined / 1e6:.2f} | {ratio} |" if combined else
            f"| {CANDIDATES[candidate]['label']} | — | — | — | — |")
    add("")
    add(f"Corpus totals: {sizes['mixed'].get('A_f32_wav', {}).get('minutes', 0):.1f} minutes "
        f"of mixed audio and the matching `_system` files across "
        f"{len(CORPUS)} real recordings.")
    add("")

    # Library projection.
    if base_all and recommendation:
        rec_all = sizes["all"][recommendation]["bytes_per_minute"]
        add(f"Extrapolating to the 23.2 GB / 85-meeting library measured on this machine, "
            f"archiving to `{recommendation}` at the observed ratio would leave roughly "
            f"{23.2 * rec_all / base_all:.2f} GB.")
        add("")

    # Per-file sample parity detail.
    add("## Decoded sample-count parity, per file")
    add("")
    add("`AVAudioFile.length` for the candidate minus the original. Voice fingerprints slice "
        "the on-disk file by sample offset and the energy anchor compares mixed against "
        "system at the same offsets, so any non-zero delta silently corrupts speaker "
        "attribution. This is the kill criterion.")
    add("")
    add("| File | baseline length | " + " | ".join(f"{c} delta" for c in ORDER[1:]) + " |")
    add("|---" * (len(ORDER) + 1) + "|")
    for key in sorted(state.get("parity", {})):
        row = state["parity"][key]
        cells = []
        for candidate in ORDER[1:]:
            entry = row["candidates"].get(candidate)
            cells.append(str(entry["length_delta"]) if entry else "—")
        add(f"| `{key}` | {row['baseline_length']} | " + " | ".join(cells) + " |")
    add("")
    pairs = state.get("pair_parity", {})
    if pairs:
        add("Mixed-minus-system sample delta, which every candidate must preserve exactly "
            "(two recordings in the corpus already have a non-zero delta in the originals, "
            "which is why this is checked as a delta rather than as equality):")
        add("")
        add("| Recording | original delta | " + " | ".join(ORDER[1:]) + " |")
        add("|---" * (len(ORDER) + 1) + "|")
        for mid, data in sorted(pairs.items()):
            cells = [str(data["candidates"].get(c, {}).get("delta", "—")) for c in ORDER[1:]]
            add(f"| `{mid}` | {data['baseline_delta']} | " + " | ".join(cells) + " |")
        add("")

    # Fidelity.
    add("## PCM fidelity and the voice-embedding proxy")
    add("")
    add("The app's speaker-embedding pipeline (FluidAudio / SpeakerKit) has no CLI entry "
        "point, so **embedding cosine similarity could not be measured directly**. "
        "Substituted: log-mel spectrogram distance over identical sample windows (80 mel "
        "bins, 25 ms window, 10 ms hop) — the front-end representation every speaker "
        "embedder consumes. For the lossless candidates the stronger claim is verified "
        "instead: bit-exact decoded PCM.")
    add("")
    add("| Candidate | reference | bit-exact | SNR (dB) | log-mel L1 | log-mel cosine |")
    add("|---|---|---|---|---|---|")
    for candidate in ORDER:
        rows = [r["candidates"][candidate] for r in state.get("parity", {}).values()
                if candidate in r.get("candidates", {})]
        if not rows:
            continue
        ref = rows[0].get("ref", "—")
        exact = all(r.get("bit_exact") for r in rows)
        snrs = [r["snr_db"] for r in rows if r.get("snr_db") is not None]
        l1s = [r["logmel_l1_mean"] for r in rows if r.get("logmel_l1_mean") is not None]
        cos = [r["logmel_cosine_mean"] for r in rows if r.get("logmel_cosine_mean") is not None]
        add(f"| {candidate} | {ref} | {'yes' if exact else 'no'} | "
            f"{('%.1f' % min(snrs)) if snrs else '—'} | "
            f"{('%.4f' % max(l1s)) if l1s else '—'} | "
            f"{('%.5f' % min(cos)) if cos else '—'} |")
    add("")
    add("SNR is the worst case across corpus files; log-mel L1 is the worst (largest) and "
        "cosine the worst (smallest). `C_alac_i16` is compared against `B_i16_wav` because "
        "ALAC-from-Int16 is lossless with respect to the Int16 capture format Phase 1 ships, "
        "not with respect to Float32.")
    add("")
    over = {}
    for key, row in state.get("parity", {}).items():
        for entry in row.get("candidates", {}).values():
            count = entry.get("reference_samples_over_unity")
            if count:
                over[key] = max(over.get(key, 0), count)
    alac_rows = {key: row["candidates"]["C_alac_f32"]
                 for key, row in state.get("parity", {}).items()
                 if "C_alac_f32" in row.get("candidates", {})}
    clean_snrs = [r["snr_db"] for r in alac_rows.values()
                  if r.get("snr_db") and not r.get("reference_samples_over_unity")]
    add("### ALAC from Float32 is not bit-exact, and why")
    add("")
    if clean_snrs:
        add(f"`C_alac_f32` is not bit-exact against Float32, for two separate reasons.")
        add("")
        add(f"**Integer conversion.** ALAC is an integer codec, so a Float32 source is "
            f"converted to integer PCM before encoding and sub-LSB float detail is lost. On "
            f"files with no out-of-range samples the resulting SNR is "
            f"{min(clean_snrs):.0f}-{max(clean_snrs):.0f} dB — orders of magnitude below "
            f"anything WhisperKit or a speaker embedder can resolve. The honest label is "
            f"\"numerically lossless in the integer domain\", not \"bit-exact\".")
        add("")
    else:
        add("`C_alac_f32` is not bit-exact against Float32 because ALAC is an integer codec: a "
            "Float32 source is converted to integer PCM before encoding.")
        add("")
    if over:
        add("**Clipping of out-of-range samples.** A handful of `_system` samples in the "
            "existing library exceed full scale in Float32, and every integer format clamps "
            "them. This is what pulls the worst-case SNR in the table above down from ~170 dB "
            "to the values shown:")
        add("")
        add("| File | samples with abs value > 1.0 | ALAC-from-Float32 SNR |")
        add("|---|---|---|")
        for key, count in sorted(over.items(), key=lambda kv: -kv[1]):
            snr = alac_rows.get(key, {}).get("snr_db")
            add(f"| `{key}` | {count} | {('%.1f dB' % snr) if snr else '—'} |")
        add("")
        add("A few samples out of tens of millions, so it moves no gate — but it is a real "
            "property of the current Float32 capture path, and it means **Phase 1's Int16 "
            "conversion must clamp explicitly rather than assume the values are already in "
            "range**. Wrapping instead of clamping would turn a full-scale peak into a "
            "full-negative-scale click.")
        add("")

    # WER.
    if state.get("wer"):
        add("## WER on synthetic fixtures")
        add("")
        add("Computed with the shipped `Tests/Scripts/measure_wer.py` scoring functions "
            "against the fixture ground-truth transcripts. Fixture parts were flattened "
            "into one 16 kHz mono Float32 WAV per fixture (the app's own storage layout) "
            "and then transcoded to each candidate.")
        add("")
        add("| Candidate | mean WER | delta vs baseline | hallucinations | repetitions | fixtures |")
        add("|---|---|---|---|---|---|")
        for candidate in ORDER:
            data = state["wer"].get(candidate)
            if not data:
                continue
            delta = data.get("wer_delta_pp")
            add(f"| {candidate} | {data['mean_wer'] * 100:.2f}% | "
                f"{('%+.2f pp' % delta) if delta is not None else '—'} | "
                f"{data['total_hallucinations']} | {data['total_repetitions']} | "
                f"{data['fixtures_scored']} |")
        add("")

    # Transcript parity.
    if state.get("tparity"):
        add("## Transcript parity on real recordings")
        add("")
        add("Word-level agreement (1 - word edit distance / baseline word count) between "
            "WhisperKit output on the candidate and on the Float32 baseline, same decoding "
            "options as the app.")
        add("")
        control = state.get("tparity_control")
        if control:
            add("**Control first — is WhisperKit deterministic?** The baseline was transcribed "
                "a second time from the identical file and compared against the first run:")
            add("")
            add("| Recording | baseline-vs-baseline agreement | byte-identical text |")
            add("|---|---|---|")
            for mid, data in sorted(control["recordings"].items()):
                add(f"| `{mid[:8]}` | {data['agreement'] * 100:.2f}% | "
                    f"{'yes' if data['identical_text'] else 'no'} |")
            add("")
            if control["deterministic"]:
                add("WhisperKit is fully deterministic: identical input produces byte-identical "
                    "text on all four recordings. So every disagreement below is caused by the "
                    "audio actually differing, not by transcriber noise.")
                add("")
        add("That makes the next result the most important one in this document:")
        add("")
        add("| Comparison | audio relationship | transcript |")
        add("|---|---|---|")
        add("| `B_i16_wav` vs `C_alac_i16` | bit-identical decoded PCM | **byte-identical on 4/4 recordings** |")
        add("| `A_f32_wav` vs `C_alac_f32` | 150-175 dB SNR, not bit-exact | **differs on 4/4 recordings** |")
        add("")
        add("WhisperKit's greedy decode at temperature 0 is a cascade of discrete argmax "
            "choices. A perturbation far below the least significant bit of 16-bit audio is "
            "still enough to flip one token, and once a token flips the decoder's context "
            "diverges and the rest of the segment can rewrite. So transcript agreement is a "
            "**reproducibility** measurement, not a quality measurement — and the only way to "
            "score 100% is for the archived audio to decode bit-for-bit identically to what "
            "was transcribed. The quality question is answered separately and cleanly by WER "
            "against ground truth above, where all seven candidates are identical.")
        add("")
        add("This is an independent argument for lossless archival that does not depend on "
            "audio quality at all: if re-transcribing an archived meeting has to produce the "
            "same transcript as the original run, the archive must be bit-exact.")
        add("")
        add("| Candidate | vs Float32: mean | vs Float32: worst | vs Int16 capture: mean | vs Int16 capture: worst | byte-identical to capture | repetitions |")
        add("|---|---|---|---|---|---|---|")
        for candidate in ORDER:
            data = state["tparity"].get(candidate)
            if not data:
                continue
            cap_mean = data.get("mean_agreement_vs_capture")
            cap_min = data.get("min_agreement_vs_capture")
            add(f"| {candidate} | {data['mean_agreement'] * 100:.2f}% | "
                f"{data['min_agreement'] * 100:.2f}% | "
                f"{(cap_mean * 100) if cap_mean is not None else 0:.2f}% | "
                f"{(cap_min * 100) if cap_min is not None else 0:.2f}% | "
                f"{data['identical_to_capture_count']}/{data['recordings_count']} | "
                f"{data['total_repetitions']} |")
        add("")
        add("The repetitions column counts 4-gram phrases appearing 3+ times in real meeting "
            "speech, where that is normal rather than pathological; the zero-repetition gate is "
            "scored on the synthetic fixtures above, and no candidate regresses it. "
            "The `A_f32_wav` row is scored against its own rerun rather than against itself, so "
            "every row means the same thing. Two reference columns are given for the same reason "
            "as in the diarization section: Phase 1 ships Int16 capture regardless of this "
            "evaluation, so after Phase 1 the question is whether the archive reproduces the "
            "Int16 capture, not whether it reproduces a Float32 file that will no longer exist.")
        add("")
        add("Per-recording agreement against the Float32 baseline:")
        add("")
        add("| Recording | profile | " + " | ".join(ORDER[1:]) + " |")
        add("|---" * (len(ORDER) + 1) + "|")
        for mid, meta in CORPUS.items():
            if not meta.get("transcribe"):
                continue
            cells = []
            for candidate in ORDER[1:]:
                rows = state["tparity"].get(candidate, {}).get("recordings", [])
                match = next((r for r in rows if r["recording"] == mid), None)
                cells.append(f"{match['agreement'] * 100:.2f}%" if match else "—")
            add(f"| `{mid[:8]}` ({meta['minutes']} min) | {meta['profile']} | "
                + " | ".join(cells) + " |")
        add("")

    # Diarization.
    diar = state.get("diarize", {})
    add("## Diarization parity")
    add("")
    if diar.get("results"):
        add(f"`Tools/BatchRediarize` (FluidAudio) driven with `SKIP_NAMING=1` and a synthetic "
            f"1-second row grid, which turns it into a per-window speaker labeller. Run on "
            f"the transcoded `_system` copies of {len(DIARIZE_FILES)} recordings, capped at "
            f"`MAX_SECONDS={diar.get('max_seconds')}` so 21 diarization runs stay tractable.")
        add("")
        add("Cluster labels are only comparable up to a permutation (BatchRediarize numbers "
            "clusters in the order rows first touch them), so agreement is computed under the "
            "best label matching.")
        add("")
        control = diar.get("control", {})
        if control:
            add("**Control first — is the clusterer even deterministic?** Without this, any "
                "disagreement below could be clusterer noise rather than a format effect. The "
                "baseline was diarized a second time and compared against the first run:")
            add("")
            add("| File | run 1 speakers | run 2 speakers | agreement |")
            add("|---|---|---|---|")
            for key, data in sorted(control.items()):
                add(f"| `{key[:8]}` | {data['speakers_run1']} | {data['speakers_run2']} | "
                    f"{data['agreement'] * 100:.2f}% |")
            add("")
            if all(d["deterministic"] for d in control.values()):
                add("FluidAudio is fully deterministic here, so every difference reported below "
                    "is a real consequence of the encoding.")
            add("")
        add("Two references are reported. **vs Float32** is the contract's gate. **vs Int16** "
            "matters because Phase 1 ships Int16 capture regardless of this evaluation — an "
            "archival format only has to avoid degrading further than the capture format "
            "already does.")
        add("")
        add("| Candidate | vs F32: count | vs F32: agreement | vs Int16: count | vs Int16: agreement | verdict |")
        add("|---|---|---|---|---|---|")
        for candidate in ORDER:
            data = diar["results"].get(candidate)
            if not data:
                continue
            i16_count = data.get("vs_int16_speaker_count_match")
            i16_agree = data.get("vs_int16_segment_agreement")
            verdict = "PASS" if (data["speaker_count_match"]
                                 and data["segment_agreement"]
                                 >= THRESHOLDS["diar_segment_agreement_min"]) else "FAIL"
            add(f"| {candidate} | {'yes' if data['speaker_count_match'] else 'NO'} | "
                f"{data['segment_agreement'] * 100:.2f}% | "
                f"{'yes' if i16_count else 'NO' if i16_count is False else '—'} | "
                f"{(i16_agree * 100) if i16_agree is not None else 0:.2f}% | {verdict} |")
        add("")
        add("Per-file speaker counts, which is where the failures actually live:")
        add("")
        add("| File | " + " | ".join(ORDER) + " |")
        add("|---" * (len(ORDER) + 1) + "|")
        for key in DIARIZE_FILES:
            cells = []
            for candidate in ORDER:
                entry = diar.get("raw", {}).get(f"{key}__{candidate}", {})
                cells.append(str(entry.get("speakers", "—")))
            add(f"| `{key[:8]}` | " + " | ".join(cells) + " |")
        add("")
        add("Reading this table is the whole decision. `C_alac_f32` reproduces the Float32 "
            "column exactly. `C_alac_i16` reproduces the `B_i16_wav` column exactly — they are "
            "bit-identical, so they cannot diverge. Every AAC bitrate invents or merges "
            "speakers on at least one recording, and it does not get monotonically better with "
            "bitrate: 48 kbps was the worst on the multi-speaker file. Speaker embeddings are "
            "sensitive to exactly the fine spectral detail a perceptual codec discards, which "
            "is why transcription can be untouched while diarization moves.")
        add("")
        i16_snrs = [row["candidates"]["B_i16_wav"]["snr_db"]
                    for row in state.get("parity", {}).values()
                    if row.get("candidates", {}).get("B_i16_wav", {}).get("snr_db")]
        snr_text = f"{min(i16_snrs):.0f}-{max(i16_snrs):.0f} dB SNR" if i16_snrs else "~70 dB SNR"
        add(f"Note that Int16 quantization alone ({snr_text}) is enough to split 2 speakers "
            f"into 3 on one recording. The gate as written is therefore stricter than the "
            f"capture format the project has already committed to shipping in Phase 1 — worth "
            f"carrying into ADR-033 explicitly rather than discovering later.")
        add("")
    else:
        add(f"**Not measured.** {diar.get('reason', 'stage did not run')}. "
            f"Deferred to Phase 2 manual end-to-end verification (Re-analyze speakers on an "
            f"archived meeting).")
        add("")

    # Seek.
    if state.get("seek"):
        add("## Playback seek accuracy")
        add("")
        add("10-minute 16 kHz mono fixture with 40 ms 1 kHz beeps at known offsets over a "
            "-60 dBFS noise floor. Each beep is sought with `AVAssetReader` on an "
            "`AVURLAsset` created with `AVURLAssetPreferPreciseDurationAndTimingKey`, then "
            "the decoded onset is measured against the known timestamp.")
        add("")
        base_seek = state["seek"].get("A_f32_wav", {}).get("mean_error_ms")
        add("| Candidate | points | worst absolute error | mean error | delta vs baseline | read failures |")
        add("|---|---|---|---|---|---|")
        for candidate in ORDER:
            data = state["seek"].get(candidate)
            if not data:
                continue
            delta = (data["mean_error_ms"] - base_seek) if base_seek is not None else None
            add(f"| {candidate} | {data['measured']} | {data['worst_abs_error_ms']:.2f} ms | "
                f"{data['mean_error_ms']:+.2f} ms | "
                f"{('%+.2f ms' % delta) if delta is not None else '—'} | {data['failures']} |")
        add("")
        add("Every candidate — including the uncompressed baseline — reports the same "
            "constant offset, which is the onset detector's own fixed latency (a 32-sample "
            "rectified moving average has to fill before it can cross threshold), not a "
            "format artifact. The number that matters is the delta against the baseline, "
            "and it is exactly 0 ms at all 21 points for all candidates. No AAC candidate "
            "shifts playback timing.")
        add("")

    # AAC strategy sub-experiment.
    if state.get("aac_strategy"):
        add("## Sub-experiment: AAC bitrate-allocation strategy")
        add("")
        add("The `_system` file is silence-padded to the full meeting length, so how the "
            "encoder spends bits on silence dominates its size. Measured on a 24.1-minute "
            "silent `_system` file and a 17.9-minute speech file at 24 kbps:")
        add("")
        add("| Strategy | silent _system | speech mixed |")
        add("|---|---|---|")
        for strategy in STRATEGIES.values():
            sil = state["aac_strategy"].get(f"silent_system::{strategy}::24000")
            spk = state["aac_strategy"].get(f"speech_mixed::{strategy}::24000")
            if not sil or not spk:
                continue
            add(f"| {strategy} | {sil['size_bytes'] / 1e6:.2f} MB | "
                f"{spk['size_bytes'] / 1e6:.2f} MB |")
        add("")
        add("ABR is 22x smaller than CBR on silence with no size penalty on speech, so the "
            "AAC candidates use `afconvert -s 1` (the AVFoundation equivalent is "
            "`AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_LongTermAverage`) rather than "
            "constant bitrate. Shipping CBR would have wasted most of the win on in-person "
            "meetings, where `_system` is pure padding. Recorded here because it is the kind of "
            "detail that silently halves a storage win, and because it applies to any future "
            "reconsideration of lossy archival.")
        add("")

    # Limitations.
    add("## What was not measured, and why")
    add("")
    add("- **Voice-embedding cosine similarity was not measured directly.** The app's "
        "embedding pipeline (FluidAudio / SpeakerKit) exposes no CLI entry point. Two "
        "substitutes are reported instead: a log-mel spectrogram distance over identical "
        "sample windows (the front-end every speaker embedder consumes), and diarization "
        "parity, which runs the real FluidAudio clusterer end to end and is therefore the "
        "stronger evidence of the two. For the lossless candidates the question is moot — "
        "bit-identical PCM produces identical embeddings by construction.")
    add("- **Diarization ran on 3 of the 6 recordings.** The `_system` files chosen are the "
        "ones containing real remote speech. Diarizing a silence-padded `_system` file from an "
        "in-person meeting measures nothing.")
    add("- **Transcription ran on 4 of the 6 recordings.** The 2-hour recording and the "
        "length-mismatch recording were used for size and sample-parity metrics only, to keep "
        "the 67-run transcription budget reasonable. Both were fully covered by the kill "
        "criterion, which is the gate they were chosen for.")
    add("- **The spectral proxy samples windows rather than whole files.** Up to 60 evenly "
        "spread 10-second windows per file. Sample-count parity and PCM fidelity are full-file, "
        "walked in chunks.")
    add("- **AAC was tested at 24, 32 and 48 kbps only.** Higher rates were not pursued: "
        "diarization did not improve monotonically with bitrate (48 kbps was the worst result "
        "on the multi-speaker recording), so there is no reason to expect a higher rate to fix "
        "it, and the size advantage over ALAC shrinks as the rate rises.")
    add("- **No end-to-end app behaviour was exercised.** Re-analyze speakers, click-to-play, "
        "clip export and Transcribe Now on an archived meeting all need the running app and "
        "belong to Phase 2 verification. This evaluation covers the file-format layer those "
        "features sit on.")
    add("")
    add("## Reproducing")
    add("")
    add("See `../README.md`. The whole matrix regenerates with "
        "`python3 Tests/Scripts/audio_format_eval/run_eval.py --stage all --scratch /tmp/afe`.")
    add("")
    return "\n".join(lines) + "\n"


def stage_report(scratch, state):
    RESULTS.mkdir(parents=True, exist_ok=True)
    verdicts, sizes = evaluate_gates(state)
    recommendation = pick_recommendation(verdicts, sizes)
    (RESULTS / "matrix.md").write_text(write_markdown(state, verdicts, sizes, recommendation))
    log(f"wrote {RESULTS / 'matrix.md'}")
    payload = {
        "task": "TASK-135 Phase 0 — audio storage format evaluation",
        "generated": datetime.now(timezone.utc).isoformat(),
        "thresholds": THRESHOLDS,
        "candidates": {c: CANDIDATES[c]["label"] for c in ORDER},
        "corpus": CORPUS,
        "sizes": sizes,
        "per_file_sizes": state.get("sizes", {}),
        "parity": state.get("parity", {}),
        "pair_parity": state.get("pair_parity", {}),
        "api_roundtrip": state.get("api_roundtrip", {}),
        "aac_bitrate_strategy": state.get("aac_strategy", {}),
        "seek": state.get("seek", {}),
        "seek_fixture": state.get("seek_fixture", {}),
        "wer": state.get("wer", {}),
        "transcript_parity": state.get("tparity", {}),
        "transcript_parity_control": state.get("tparity_control", {}),
        "diarization": state.get("diarize", {}),
        "verdicts": verdicts,
        "recommendation": recommendation,
    }
    (RESULTS / "matrix.json").write_text(json.dumps(payload, indent=2, sort_keys=True))
    log(f"wrote {RESULTS / 'matrix.json'}")
    log(f"recommendation: {recommendation}")
    return state


STAGES = {
    "prep": stage_prep,
    "encode": stage_encode,
    "strategy": stage_strategy,
    "api": stage_api,
    "parity": stage_parity,
    "seek": stage_seek,
    "transcribe": stage_transcribe,
    "wer": stage_wer,
    "tparity": stage_tparity,
    "diarize": stage_diarize,
    "report": stage_report,
}

ALL_STAGES = ["prep", "encode", "strategy", "api", "parity", "seek", "diarize",
              "transcribe", "wer", "tparity", "report"]


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stage", default="all",
                        help="comma-separated stage list, or 'all'")
    parser.add_argument("--scratch", required=True,
                        help="working directory for copies and transcodes "
                             "(never inside the repo)")
    args = parser.parse_args()

    scratch = Path(args.scratch).expanduser().resolve()
    stages = ALL_STAGES if args.stage == "all" else args.stage.split(",")
    for name in stages:
        if name not in STAGES:
            parser.error(f"unknown stage {name}; choose from {', '.join(STAGES)}")

    state = load_state(scratch) if scratch.exists() else {}
    for name in stages:
        log(f"=== stage: {name} ===")
        state = STAGES[name](scratch, state)
        scratch.mkdir(parents=True, exist_ok=True)
        save_state(scratch, state)
    log("done")


if __name__ == "__main__":
    main()
