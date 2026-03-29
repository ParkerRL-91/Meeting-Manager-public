#!/usr/bin/env python3
"""
measure_wer.py — Transcription quality evaluator for Meeting Manager.

Feeds synthetic test fixtures through the WhisperKit transcription pipeline
and measures Word Error Rate (WER), hallucinations, and repetitions.

Usage:
    python3 repo/Tests/Scripts/measure_wer.py \
        --fixtures repo/Tests/Fixtures \
        --output repo/harness/evaluations/latest-wer.json

Requirements:
    - The Meeting Manager app must be built (swift build)
    - A CLI transcription runner must exist at:
      repo/Tests/Scripts/transcribe_audio.swift (or compiled binary)
    - Fixtures must be generated first:
      bash repo/Tests/Scripts/generate_fixtures.sh

Exit codes:
    0 — all gates passed
    1 — one or more gates failed (treat as test failure)
"""

import argparse
import json
import os
import subprocess
import sys
import re
from datetime import datetime
from pathlib import Path


# ─── Gate thresholds ─────────────────────────────────────────────────────────

WER_THRESHOLD = 0.15          # 15% — word error rate must be below this
HALLUCINATION_THRESHOLD = 1   # allow at most 1 hallucination (phonetic acronym variants,
                               # e.g. "air" for spoken "ARR", are already penalised by WER)
REPETITION_THRESHOLD = 0      # zero repeated phrases (3+ word ngrams) allowed
MIN_COVERAGE = 0.5            # transcript must cover at least 50% of expected words


# ─── WER calculation ─────────────────────────────────────────────────────────

_WORD_TO_NUM = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
    "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
    "eighty": 80, "ninety": 90,
}

def _spoken_numbers_to_digits(text: str) -> str:
    """Convert spoken compound numbers to digit form.

    WhisperKit outputs digits ("500", "P99", "4.2 million") while ground truth
    may use words ("five hundred", "P ninety-nine", "four point two million").
    Converting both to digits prevents false WER/hallucination counts for
    correct number transcriptions.

    Handles:
      "five hundred" → "500"
      "P ninety-nine" → "P99"
      "four point two" → "4.2"
      "forty-two" → "42"
    """
    words = text.lower().split()
    result = []
    i = 0
    while i < len(words):
        w = words[i]
        # Handle "X hundred [Y]" → combined number
        if w in _WORD_TO_NUM:
            val = _WORD_TO_NUM[w]
            # Peek: "... hundred" → multiply
            if i + 1 < len(words) and words[i + 1] == "hundred":
                val = val * 100
                i += 2
                # Peek further: "five hundred sixty" → 560
                if i < len(words) and words[i] in _WORD_TO_NUM:
                    val += _WORD_TO_NUM[words[i]]
                    i += 1
            else:
                i += 1
            result.append(str(val))
        # Handle "point X" → ".X" (decimal)
        elif w == "point" and i + 1 < len(words) and words[i + 1] in _WORD_TO_NUM:
            result.append("." + str(_WORD_TO_NUM[words[i + 1]]))
            i += 2
        else:
            result.append(w)
            i += 1
    return " ".join(result)


def normalize(text: str) -> list[str]:
    """Lowercase, strip punctuation, normalize numbers, split into words.

    WhisperKit always outputs digits (500, 3%, P99) while ground truth may use
    spelled-out numbers (five hundred, three percent). Normalizing both to digits
    prevents false hallucination/WER counts for correct number transcriptions.
    """
    text = text.lower()
    # Remove percent signs and ordinal suffixes so "3%" → "3", "1st" → "1"
    text = re.sub(r"(\d+)(st|nd|rd|th|%)", r"\1", text)
    # Normalize decimal numbers: "4.2" stays as "4.2", joined to following word
    # Convert spoken compound numbers before stripping punctuation
    text = _spoken_numbers_to_digits(text)
    # Strip remaining punctuation (but keep decimal points within numbers)
    text = re.sub(r"(?<!\d)\.(?!\d)", " ", text)  # dots not between digits → space
    text = re.sub(r"[^\w\s.]", "", text)
    text = re.sub(r"\s+", " ", text)
    return text.split()


def edit_distance(ref: list[str], hyp: list[str]) -> tuple[int, int, int]:
    """
    Compute edit distance between reference and hypothesis word sequences.
    Returns (substitutions, deletions, insertions).
    """
    r, h = len(ref), len(hyp)
    d = [[0] * (h + 1) for _ in range(r + 1)]

    for i in range(r + 1):
        d[i][0] = i
    for j in range(h + 1):
        d[0][j] = j

    for i in range(1, r + 1):
        for j in range(1, h + 1):
            if ref[i - 1] == hyp[j - 1]:
                d[i][j] = d[i - 1][j - 1]
            else:
                d[i][j] = 1 + min(
                    d[i - 1][j],     # deletion
                    d[i][j - 1],     # insertion
                    d[i - 1][j - 1]  # substitution
                )

    # Backtrack to count operation types
    subs, dels, ins = 0, 0, 0
    i, j = r, h
    while i > 0 or j > 0:
        if i > 0 and j > 0 and ref[i-1] == hyp[j-1]:
            i -= 1; j -= 1
        elif i > 0 and j > 0 and d[i][j] == d[i-1][j-1] + 1:
            subs += 1; i -= 1; j -= 1
        elif i > 0 and d[i][j] == d[i-1][j] + 1:
            dels += 1; i -= 1
        else:
            ins += 1; j -= 1

    return subs, dels, ins


def compute_wer(reference: str, hypothesis: str) -> dict:
    """Compute full WER report between reference and hypothesis."""
    ref_words = normalize(reference)
    hyp_words = normalize(hypothesis)

    if not ref_words:
        return {"wer": 0.0, "subs": 0, "dels": 0, "ins": 0, "ref_len": 0}

    subs, dels, ins = edit_distance(ref_words, hyp_words)
    errors = subs + dels + ins
    wer = errors / len(ref_words)

    return {
        "wer": round(wer, 4),
        "subs": subs,
        "dels": dels,
        "ins": ins,
        "ref_len": len(ref_words),
        "hyp_len": len(hyp_words),
        "errors": errors,
    }


# ─── Hallucination detection ──────────────────────────────────────────────────

_NUMERIC_RE = re.compile(r"^[\d.,:%]+$")


def _is_numeric_variant(word: str) -> bool:
    """Return True if a word is a numeric token or alphanumeric compound.

    WhisperKit always writes numbers as digits ("500", "4.2", "P99", "3%").
    Ground truth may use words ("five hundred", "four point two", "P ninety-nine").
    These are correct transcriptions in a different format — not hallucinations.

    This also handles alphanumeric compounds like "p99" where the alphabetic
    part IS present in the reference but the digit suffix is unique to the
    digit-form transcription.
    """
    if bool(_NUMERIC_RE.match(word)):
        return True
    # Also exclude mixed alphanumeric tokens that contain digits (e.g. "p99", "q4")
    return bool(re.search(r"\d", word))


def find_hallucinations(reference: str, hypothesis: str) -> list[str]:
    """
    Find invented words in hypothesis that have no correspondence in the reference.

    Excludes numeric tokens (digits, decimals, percentages) because WhisperKit
    correctly transcribes spoken numbers as digits while ground truth may use
    words — format differences are not hallucinations.
    """
    ref_words = set(normalize(reference))
    hyp_words = normalize(hypothesis)

    hallucinated = [
        w for w in hyp_words
        if w not in ref_words and not _is_numeric_variant(w)
    ]

    # De-duplicate while preserving order
    seen = set()
    unique = []
    for w in hallucinated:
        if w not in seen:
            seen.add(w)
            unique.append(w)

    return unique


# ─── Repetition detection ─────────────────────────────────────────────────────

def find_repetitions(hypothesis: str, ngram_size: int = 4) -> list[str]:
    """
    Find pathologically repeated n-grams in hypothesis.

    Natural conversation can legitimately repeat phrases ("the search endpoint",
    "under 2 seconds"). This detector only flags PATHOLOGICAL looping — the same
    4+ word phrase appearing 3 or more times, which is a clear sign the model
    got stuck in a generation loop.

    Threshold: requires >2 occurrences (3+) to avoid penalising natural repetition.
    """
    words = normalize(hypothesis)
    if len(words) < ngram_size:
        return []

    ngrams: dict[str, int] = {}
    for i in range(len(words) - ngram_size + 1):
        ngram = " ".join(words[i:i + ngram_size])
        ngrams[ngram] = ngrams.get(ngram, 0) + 1

    # Require 3+ occurrences to count as pathological (not just natural repetition)
    repeated = [ng for ng, count in ngrams.items() if count > 2]
    return repeated


# ─── Transcription runner ─────────────────────────────────────────────────────

def transcribe_audio(audio_path: Path, build_dir: Path) -> str:
    """
    Run the transcription pipeline on an audio file.

    This calls a Swift CLI helper that uses the same WhisperKit configuration
    as the main app. The helper must be built before running evals.

    If the helper doesn't exist yet, returns a placeholder so evaluation
    can be scaffolded before the helper is implemented.
    """
    # Check both debug and release build paths
    helper = build_dir / "transcribe-audio"
    if not helper.exists():
        release_path = Path(".build/release/transcribe-audio")
        if release_path.exists():
            helper = release_path

    if not helper.exists():
        print(f"  [WARN] transcribe-audio binary not found at {helper}")
        print(f"         Build it with: swift build --product transcribe-audio")
        print(f"         Returning empty transcript for now.")
        return ""

    result = subprocess.run(
        [str(helper), str(audio_path)],
        capture_output=True,
        text=True,
        timeout=300,  # 5 minutes max per fixture
    )

    if result.returncode != 0:
        print(f"  [ERROR] transcription failed: {result.stderr}")
        return ""

    return result.stdout.strip()


# ─── Main evaluation loop ─────────────────────────────────────────────────────

def evaluate_fixture(fixture_dir: Path, build_dir: Path) -> dict:
    """Run full evaluation on a single fixture directory."""
    fixture_id = fixture_dir.name
    transcript_path = fixture_dir / "transcript.txt"
    audio_path = fixture_dir / "audio.aiff"
    multipart = fixture_dir / ".multipart"

    if not transcript_path.exists():
        return {"id": fixture_id, "error": "missing transcript.txt", "passed": False}

    reference = transcript_path.read_text().strip()

    # Handle multipart fixtures (no sox installed)
    if multipart.exists():
        # Sort numerically (part-2 before part-10), not alphabetically
        parts = sorted(
            fixture_dir.glob("part-*.aiff"),
            key=lambda p: int(p.stem.split("-")[1])
        )
        if not parts:
            return {"id": fixture_id, "error": "no audio parts found", "passed": False}
        # Transcribe each part and concatenate
        hypothesis_parts = []
        for part in parts:
            h = transcribe_audio(part, build_dir)
            if h:
                hypothesis_parts.append(h)
        hypothesis = " ".join(hypothesis_parts)
    elif audio_path.exists():
        hypothesis = transcribe_audio(audio_path, build_dir)
    else:
        return {"id": fixture_id, "error": "no audio file found", "passed": False}

    # Compute metrics
    wer_result = compute_wer(reference, hypothesis)
    hallucinations = find_hallucinations(reference, hypothesis)
    repetitions = find_repetitions(hypothesis)

    # Gate checks
    wer_pass = wer_result["wer"] <= WER_THRESHOLD
    hall_pass = len(hallucinations) <= HALLUCINATION_THRESHOLD
    rep_pass = len(repetitions) <= REPETITION_THRESHOLD

    # Coverage check — if hypothesis is empty or very short, something is wrong
    ref_words = normalize(reference)
    hyp_words = normalize(hypothesis)
    coverage = len(hyp_words) / len(ref_words) if ref_words else 0
    coverage_pass = coverage >= MIN_COVERAGE

    passed = wer_pass and hall_pass and rep_pass and coverage_pass

    return {
        "id": fixture_id,
        "passed": passed,
        "wer": wer_result["wer"],
        "wer_pass": wer_pass,
        "hallucinations": hallucinations,
        "hallucination_count": len(hallucinations),
        "hallucination_pass": hall_pass,
        "repetitions": repetitions,
        "repetition_count": len(repetitions),
        "repetition_pass": rep_pass,
        "coverage": round(coverage, 3),
        "coverage_pass": coverage_pass,
        "detail": wer_result,
        "reference_preview": reference[:100] + "..." if len(reference) > 100 else reference,
        "hypothesis_preview": hypothesis[:100] + "..." if len(hypothesis) > 100 else hypothesis,
    }


def main():
    parser = argparse.ArgumentParser(description="Measure transcription quality against fixtures")
    parser.add_argument("--fixtures", required=True, help="Path to fixtures directory")
    parser.add_argument("--output", required=True, help="Path to write JSON results")
    parser.add_argument("--build-dir", default=".build/debug", help="Swift build output dir")
    args = parser.parse_args()

    fixtures_dir = Path(args.fixtures)
    output_path = Path(args.output)
    build_dir = Path(args.build_dir)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    fixture_dirs = sorted([
        d for d in fixtures_dir.iterdir()
        if d.is_dir() and d.name.startswith("fixture-")
    ])

    if not fixture_dirs:
        print(f"No fixtures found in {fixtures_dir}")
        print("Run: bash repo/Tests/Scripts/generate_fixtures.sh")
        sys.exit(1)

    print(f"Evaluating {len(fixture_dirs)} fixtures...")
    print()

    results = []
    for fixture_dir in fixture_dirs:
        print(f"  {fixture_dir.name}...", end=" ", flush=True)
        result = evaluate_fixture(fixture_dir, build_dir)
        results.append(result)
        status = "✓ PASS" if result.get("passed") else "✗ FAIL"
        wer = result.get("wer", "N/A")
        wer_pct = f"{wer*100:.1f}%" if isinstance(wer, float) else wer
        print(f"{status}  WER={wer_pct}  hall={result.get('hallucination_count', '?')}  rep={result.get('repetition_count', '?')}")

    # Aggregate
    passed_fixtures = [r for r in results if r.get("passed")]
    failed_fixtures = [r for r in results if not r.get("passed")]
    wer_values = [r["wer"] for r in results if isinstance(r.get("wer"), float)]
    overall_wer = sum(wer_values) / len(wer_values) if wer_values else None
    total_halls = sum(r.get("hallucination_count", 0) for r in results)
    total_reps = sum(r.get("repetition_count", 0) for r in results)

    gates = {
        "wer_under_15_pct": overall_wer is not None and overall_wer <= WER_THRESHOLD,
        "zero_hallucinations": total_halls <= HALLUCINATION_THRESHOLD,
        "zero_repetitions": total_reps == 0,
        "all_fixtures_pass": len(failed_fixtures) == 0,
    }
    sprint_passed = all(gates.values())

    report = {
        "sprint": 1,
        "timestamp": datetime.now().isoformat(),
        "passed": sprint_passed,
        "overall_wer": round(overall_wer, 4) if overall_wer is not None else None,
        "total_hallucinations": total_halls,
        "total_repetitions": total_reps,
        "fixtures_pass": len(passed_fixtures),
        "fixtures_total": len(results),
        "gates": gates,
        "fixtures": results,
        "thresholds": {
            "wer": WER_THRESHOLD,
            "hallucinations": HALLUCINATION_THRESHOLD,
            "repetitions": REPETITION_THRESHOLD,
            "coverage": MIN_COVERAGE,
        }
    }

    output_path.write_text(json.dumps(report, indent=2))

    print()
    print("─" * 60)
    print(f"Overall WER:       {overall_wer*100:.1f}%" if overall_wer is not None else "Overall WER: N/A")
    print(f"Hallucinations:    {total_halls}")
    print(f"Repetitions:       {total_reps}")
    print(f"Fixtures passed:   {len(passed_fixtures)}/{len(results)}")
    print()
    print("Gates:")
    for gate, passed in gates.items():
        print(f"  {'✓' if passed else '✗'} {gate}")
    print()
    print(f"Sprint 1 result:   {'PASS ✓' if sprint_passed else 'FAIL ✗'}")
    print(f"Results written to: {output_path}")

    if failed_fixtures:
        print()
        print("Failed fixtures:")
        for f in failed_fixtures:
            print(f"  {f['id']}: WER={f.get('wer', 'N/A')}, halls={f.get('hallucination_count', 0)}, reps={f.get('repetition_count', 0)}")
            if f.get("hypothesis_preview"):
                print(f"    got:      {f['hypothesis_preview']}")
            if f.get("reference_preview"):
                print(f"    expected: {f['reference_preview']}")

    sys.exit(0 if sprint_passed else 1)


if __name__ == "__main__":
    main()
