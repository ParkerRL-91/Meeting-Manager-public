# Audio format evaluation harness (TASK-135 Phase 0)

Answers one question empirically: **what is the smallest on-disk format that no
Meeting Manager audio consumer can distinguish from the Float32 WAV shipping
today?**

Results live in `results/matrix.md` (human) and `results/matrix.json`
(machine). The recommendation feeds ADR-033 and Phase 2's
`AudioArchiveService`.

## Why this needs to be measured rather than reasoned about

Audio is stored as two files per meeting — `<id>.wav` (mixed) and
`<id>_system.wav` (system audio, silence-padded to the full meeting length).
Four consumer behaviours make format choice non-obvious:

1. **Voice fingerprints slice the on-disk file by sample offset.** A format
   that decodes to even one extra or missing sample silently shifts every
   fingerprint window and corrupts speaker attribution. AAC carries ~2112
   samples of decoder priming, which only stays invisible if the container's
   gapless metadata is written correctly. This is the kill criterion.
2. **The energy anchor compares mixed against system at identical offsets.**
   Timeline parity between the two files must survive encoding.
3. **Clips and click-to-play are time ranges into the mixed file via
   AVPlayer.** Seek accuracy has to hold at arbitrary offsets, not just at
   packet boundaries.
4. **`_system` is mostly silence by design.** How an encoder spends bits on
   silence dominates its size, so bitrate *strategy* matters as much as
   bitrate.

Consumers read through `AVAudioFile`, which vends Float32 regardless of on-disk
encoding and gates only on 16 kHz mono — which is why compressed containers are
viable at all, and why every measurement here goes through `AVAudioFile` rather
than through raw byte inspection.

## Layout

| Path | Role |
|---|---|
| `run_eval.py` | Driver. Stages, thresholds, candidate + corpus definitions, report generation. |
| `decode_probe.swift` | AVFoundation ground truth: decoded length, PCM dump, encoder-API round-trip, beep fixture generation, seek measurement. Compiled with `swiftc`, deliberately **not** an SPM target. |
| `batch_transcribe.swift` | Loads WhisperKit once and transcribes a job list. `Tools/TranscribeAudio` reloads the 632 MB model per invocation (~3 min), which the 63 transcriptions here cannot absorb. Decoding options are copied verbatim from that tool so numbers stay comparable. |
| `results/matrix.md` | Full results matrix, gate table, recommendation. |
| `results/matrix.json` | Same data, machine-readable. |

Nothing in the harness writes to the repo outside `results/`. All working
copies, transcodes and PCM dumps go to the scratch directory.

## Prerequisites

```bash
# The batch transcriber links against the prebuilt WhisperKit artifacts.
swift build -c release --product transcribe-audio
# Diarization parity needs the offline diarizer CLI.
swift build -c release --product batch-rediarize
# Synthetic WER fixtures, if Tests/Fixtures/ is empty.
bash Tests/Scripts/generate_fixtures.sh
```

## Running

```bash
python3 Tests/Scripts/audio_format_eval/run_eval.py --stage all --scratch /tmp/afe
```

State accumulates in `<scratch>/state.json` and every stage is resumable, so
individual stages can be re-run without redoing the rest:

```bash
python3 Tests/Scripts/audio_format_eval/run_eval.py --stage parity,report --scratch /tmp/afe
```

| Stage | Cost | What it produces |
|---|---|---|
| `prep` | seconds | Compiles both probes, copies the corpus out of the live library, generates the beep seek fixture, flattens the multipart WER fixtures into one 16 kHz mono Float32 WAV each. |
| `encode` | ~4 min | Every candidate for every corpus file via `afconvert`. |
| `strategy` | ~1 min | AAC bitrate-allocation sub-experiment (CBR vs ABR vs VBR on silence). |
| `api` | seconds | Exact-length round-trip for `afconvert`, `AVAudioFile`, `ExtAudioFile`. |
| `parity` | ~10 min | Decoded sample-count parity, full-file PCM fidelity, log-mel spectral proxy. |
| `seek` | ~1 min | Beep onset error at every known timestamp for every candidate. |
| `diarize` | ~20 min | FluidAudio speaker parity on transcoded `_system` copies. |
| `transcribe` | ~30 min | All 63 WhisperKit runs, one model load. |
| `wer` | seconds | WER against fixture ground truth, using `Tests/Scripts/measure_wer.py`. |
| `tparity` | seconds | Word-level agreement candidate-vs-baseline on real recordings. |
| `report` | seconds | Writes `results/matrix.md` and `results/matrix.json`. |

Scratch settles around 3.9 GB of corpus copies and transcodes, peaking roughly
1 GB higher while `parity` holds two decoded PCM dumps of the 2-hour file.
`parity` deletes each dump as soon as it has been compared.

### Do not run the heavy stages during a meeting

`transcribe` calls `wait_for_idle()` first, which blocks while the app's log
shows a **fresh** (< 60 s old) capture or recording line. Stale `recording` rows
in `db.sqlite` and a zombie browser `inCall` flag are not evidence of a live
meeting and are deliberately ignored. Light stages (`encode`, `api`, `parity`,
`seek`) are safe at any time.

### The live library is read-only

`prep` copies both the mixed and `_system` file for each corpus recording out of
`~/Library/Application Support/MeetingManager/Audio/` and never touches the
originals again. Copies are skipped if already present in scratch.

## Corpus

Real recordings were chosen by measuring mixed and system activity across all
85 meeting pairs in the library, then picking a spread:

| Recording | Length | Why |
|---|---|---|
| `10467DB5` | 4.4 min | Remote-heavy, short — fast iteration. |
| `AA3FEB29` | 12.3 min | Hybrid: system audio active about half the time. |
| `D192B3E6` | 17.9 min | Remote-heavy, multi-speaker — the diarization stress case. |
| `8E0AF6D5` | 24.1 min | In-person: `_system` is 99.9% silence padding. The compression best case. |
| `20AF257E` | 16.3 min | Mixed and `_system` lengths already differ in the originals (623,274 samples), so pair parity has to be checked as a preserved delta, not as equality. |
| `097C0046` | 120 min | Long-file size and parity only; not transcribed. |

Synthetic fixtures from `Tests/Fixtures/` supply ground-truth WER. Their parts
are 22.05 kHz AIFF, so `prep` flattens each fixture into a single 16 kHz mono
Float32 WAV — the app's own storage layout — before transcoding to candidates.

## Gates and thresholds

| Gate | Threshold |
|---|---|
| Decoded sample-count parity | Exact on every file, both mixed and `_system`. Kill criterion. |
| Mixed/system timeline parity | The original mixed-minus-system sample delta is preserved. |
| WER delta on fixtures | <= +0.5 pp absolute vs baseline; repetition loops stay at zero. |
| Transcript parity on real recordings | >= 99% word agreement vs baseline, per recording. |
| Diarization parity | Same speaker count and >= 98% per-window speaker agreement. |
| Playback seek accuracy | <= +/-50 ms at every beep. |
| Size | Reported as bytes per minute, split mixed vs `_system`. |

Decision rule: the smallest candidate passing every gate, with the same format
used for both files.

## Known substitutions and limits

- **Voice-embedding similarity is a proxy.** The app's speaker-embedding
  pipeline (FluidAudio / SpeakerKit) has no CLI entry point, so embedding cosine
  similarity is not measured directly. Substituted: log-mel spectrogram distance
  over identical sample windows — the front-end every speaker embedder consumes.
  For lossless candidates the stronger claim is verified instead (bit-exact
  decoded PCM). Diarization parity, which does run the real FluidAudio
  clusterer, covers the end of that pipeline.
- **The spectral proxy samples windows.** Up to 60 evenly spread 10-second
  windows per file, so a 2-hour file stays tractable. Sample-count parity and
  PCM fidelity are full-file.
- **Diarization parity uses a synthetic row grid.** `Tools/BatchRediarize` maps
  caller-supplied transcript rows onto clusters, so a 1-second row grid turns it
  into a per-window speaker labeller. `SKIP_NAMING=1` bypasses the Ollama naming
  step. Runs are capped with `MAX_SECONDS` so 21 diarizations finish in
  reasonable time.
- **`AVAudioFile` is the parity oracle.** It is what every consumer uses. A
  format that round-trips exactly through `AVAudioFile` but not through some
  other decoder is still correct for this app.
- **AAC file sizes vary slightly between runs.** Two independent runs over the
  same corpus produced AAC files differing by a few bytes up to ~200 bytes out
  of 40 MB (under 0.001%) — ABR encoding is not byte-deterministic. The lossless
  candidates are byte-identical across runs, and every gate result reproduced
  exactly. Expect the AAC size column to wobble in the last digits.
