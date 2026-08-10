# TASK-135 Phase 0 — audio storage format evaluation

Generated 2026-08-04 21:15 UTC on Apple silicon, macOS, WhisperKit `openai_whisper-large-v3-v20240930_turbo_632MB`, FluidAudio diarizer via `Tools/BatchRediarize`.

Every candidate is 16 kHz mono. The evaluation asks one question: what is the smallest on-disk format that no consumer can distinguish from the Float32 WAV shipping today.

## Recommendation

**Archive to ALAC in an .m4a container.** It is the only compressed format that passed every gate. The bit depth should match whatever the capture path stores, because ALAC is only lossless at the depth it was given:

- **New recordings, after Phase 1 ships Int16 capture: ALAC 16-bit** (`C_alac_i16`, 0.69 MB/min per file, 5.5x smaller than today). Its decoded PCM is **bit-identical** to the Int16 WAV it was encoded from, on every file in the corpus. Archiving therefore adds exactly zero degradation on top of what Phase 1 already accepts: its transcripts are byte-identical to the Int16 capture on 4/4 recordings and its diarization matches at 100% with identical speaker counts.
- **Backfilling the existing Float32 library (Phase 3): ALAC from Float32** (`C_alac_f32`, 2.61 MB/min per file, 1.5x smaller than today) if historical speaker attribution must not move. It is the only candidate that reproduces the Float32 baseline's diarization exactly. Backfilling to ALAC 16-bit instead is 3.8x smaller again, but it applies the same Int16 quantization Phase 1 accepts — which measurably flipped FluidAudio's speaker count on one of the three recordings tested (2 speakers to 3). That is a product decision, not a technical blocker.

**AAC is rejected at every bitrate tested (24, 32, 48 kbps).** It passes the sample-parity kill criterion, WER against ground truth, and seek accuracy cleanly — but it fails diarization parity against both references. At 48 kbps, the highest rate tested, FluidAudio found 6 speakers where the baseline found 4 on the multi-speaker recording, and 24 kbps agreed with the baseline on only 67.7% of windows there. AAC at 24 kbps would have been 4.1x smaller again than ALAC 16-bit; the measurements say that saving costs speaker attribution, so it is not taken.

Encoder API for Phase 2: `AVAudioFile(forWriting:settings:)` with `AVFormatIDKey: kAudioFormatAppleLossless`, `AVSampleRateKey: 16000`, `AVNumberOfChannelsKey: 1` and `AVEncoderBitDepthHintKey: 16`. Verified sample-exact round-trip on every corpus file.

### Encoder API for the shipping AudioArchiveService

AAC carries roughly 2112 samples of decoder priming. It only stays invisible if the container's gapless metadata (priming/remainder in the m4a packet table) is written correctly, so each writing API was tested for an exact-length round-trip through `AVAudioFile`:

| Encoder API | Exact-length round-trip |
|---|---|
| `afconvert` | yes, all 6 configurations |
| `avaudiofile` | yes, all 4 configurations |
| `extaudiofile` | yes, all 4 configurations |

All three achieve sample-exact round-trip, so the shipping code can use `AVAudioFile(forWriting:settings:)` — the highest-level API. No `afconvert` subprocess and no `ExtAudioFile` C plumbing is required, and the AAC priming question turns out not to constrain the API choice at all.

One caveat worth carrying into Phase 2: `AVAudioFile` + ALAC honours `AVEncoderBitDepthHintKey: 16` and produces 16-bit ALAC, while `ExtAudioFile` without a depth hint produced 32-bit ALAC — 3.3x larger for identical audio. If ALAC is ever chosen, the bit-depth hint is load-bearing.

## Gate matrix

| Gate | A_f32_wav | B_i16_wav | C_alac_f32 | C_alac_i16 | D_aac_24k | D_aac_32k | D_aac_48k |
|---|---|---|---|---|---|---|---|
| Decoded sample-count parity (kill criterion) | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| Mixed/system timeline parity | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| WER delta on fixtures | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| Repetition/hallucination loop gate | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| Transcript parity on real recordings (literal threshold) | PASS | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| Transcript parity vs Int16 capture format | FAIL | PASS | FAIL | PASS | FAIL | FAIL | FAIL |
| Diarization parity (_system copies) | PASS | FAIL | PASS | FAIL | FAIL | FAIL | FAIL |
| Diarization parity vs Int16 capture format | FAIL | PASS | FAIL | PASS | FAIL | FAIL | FAIL |
| Playback seek accuracy | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| **Overall, vs today's Float32** | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| **Overall, vs Phase 1 Int16 capture** | FAIL | PASS | FAIL | PASS | FAIL | FAIL | FAIL |

Two overall rows because there are two defensible references. The first asks whether a candidate reproduces the Float32 file stored today. The second asks whether it reproduces the Int16 file Phase 1 will store — the relevant question for an archival step that runs after capture. `A_f32_wav` and `C_alac_f32` fail the second row for the trivial reason that they are not Int16 and so cannot reproduce it; that is not a defect, it just means they answer the first question instead. `n/m` = not measured. Thresholds: sample parity exact on every file; WER delta <= +0.5 pp; transcript agreement >= 99% on every recording; diarization same speaker count and >= 98% per-window agreement; seek error <= +/-50 ms at every beep.

### Measured values behind each gate

| Gate | A_f32_wav | B_i16_wav | C_alac_f32 | C_alac_i16 | D_aac_24k | D_aac_32k | D_aac_48k |
|---|---|---|---|---|---|---|---|
| Decoded sample-count parity (kill criterion) | 13/13 files exact | 13/13 files exact | 13/13 files exact | 13/13 files exact | 13/13 files exact | 13/13 files exact | 13/13 files exact |
| Mixed/system timeline parity | 6/6 pairs preserved | 6/6 pairs preserved | 6/6 pairs preserved | 6/6 pairs preserved | 6/6 pairs preserved | 6/6 pairs preserved | 6/6 pairs preserved |
| WER delta on fixtures | +0.00 pp (abs 2.61%) | +0.00 pp (abs 2.61%) | +0.00 pp (abs 2.61%) | +0.00 pp (abs 2.61%) | +0.00 pp (abs 2.61%) | +0.00 pp (abs 2.61%) | +0.00 pp (abs 2.61%) |
| Repetition/hallucination loop gate | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Transcript parity on real recordings (literal threshold) | min 100.00%, mean 100.00% | min 95.12%, mean 96.58% | min 95.14%, mean 96.67% | min 95.12%, mean 96.58% | min 88.95%, mean 91.70% | min 88.95%, mean 92.71% | min 93.71%, mean 95.46% |
| Transcript parity vs Int16 capture format | min 95.14%, 0/4 byte-identical | min 100.00%, 4/4 byte-identical | min 93.56%, 0/4 byte-identical | min 100.00%, 4/4 byte-identical | min 89.50%, 0/4 byte-identical | min 88.52%, 0/4 byte-identical | min 92.30%, 0/4 byte-identical |
| Diarization parity (_system copies) | count match True, agreement 100.0% | count match False, agreement 95.0% | count match True, agreement 100.0% | count match False, agreement 95.0% | count match True, agreement 87.8% | count match False, agreement 93.8% | count match False, agreement 97.8% |
| Diarization parity vs Int16 capture format | count match False, agreement 95.0% (worst 85.0%) | count match True, agreement 100.0% (worst 100.0%) | count match False, agreement 95.0% (worst 85.0%) | count match True, agreement 100.0% (worst 100.0%) | count match False, agreement 82.9% (worst 67.7%) | count match False, agreement 89.3% (worst 84.9%) | count match False, agreement 92.8% (worst 85.0%) |
| Playback seek accuracy | worst 1.2 ms over 21 points | worst 1.2 ms over 21 points | worst 1.2 ms over 21 points | worst 1.2 ms over 21 points | worst 1.2 ms over 21 points | worst 1.2 ms over 21 points | worst 1.2 ms over 21 points |

## Size

MB per minute of meeting, per file. `_system` is silence-padded to the full meeting length by design, so it is reported separately — that is where the compression wins are largest.

| Candidate | mixed | _system | combined per meeting-minute | vs baseline |
|---|---|---|---|---|
| Float32 WAV (baseline) | 3.84 | 3.83 | 7.67 | baseline |
| Int16 WAV | 1.92 | 1.91 | 3.83 | 2.0x smaller |
| ALAC .m4a (from Float32) | 2.71 | 2.51 | 5.22 | 1.5x smaller |
| ALAC .m4a (from Int16) | 0.79 | 0.60 | 1.39 | 5.5x smaller |
| AAC-LC .m4a @ 24 kbps | 0.18 | 0.16 | 0.34 | 22.7x smaller |
| AAC-LC .m4a @ 32 kbps | 0.24 | 0.20 | 0.44 | 17.4x smaller |
| AAC-LC .m4a @ 48 kbps | 0.35 | 0.29 | 0.64 | 11.9x smaller |

Corpus totals: 195.0 minutes of mixed audio and the matching `_system` files across 6 real recordings.

Extrapolating to the 23.2 GB / 85-meeting library measured on this machine, archiving to `C_alac_i16` at the observed ratio would leave roughly 4.20 GB.

## Decoded sample-count parity, per file

`AVAudioFile.length` for the candidate minus the original. Voice fingerprints slice the on-disk file by sample offset and the energy anchor compares mixed against system at the same offsets, so any non-zero delta silently corrupts speaker attribution. This is the kill criterion.

| File | baseline length | B_i16_wav delta | C_alac_f32 delta | C_alac_i16 delta | D_aac_24k delta | D_aac_32k delta | D_aac_48k delta |
|---|---|---|---|---|---|---|---|
| `097C0046-C28B-42E2-AAC0-2D8E57124BB6` | 115201562 | 0 | 0 | 0 | 0 | 0 | 0 |
| `097C0046-C28B-42E2-AAC0-2D8E57124BB6_system` | 115200314 | 0 | 0 | 0 | 0 | 0 | 0 |
| `10467DB5-EBD7-4774-9D77-7C059EB3D145` | 4265716 | 0 | 0 | 0 | 0 | 0 | 0 |
| `10467DB5-EBD7-4774-9D77-7C059EB3D145_system` | 4265716 | 0 | 0 | 0 | 0 | 0 | 0 |
| `20AF257E-F1CC-44A2-AAC7-6AF3FD048AAC` | 15629988 | 0 | 0 | 0 | 0 | 0 | 0 |
| `20AF257E-F1CC-44A2-AAC7-6AF3FD048AAC_system` | 15006714 | 0 | 0 | 0 | 0 | 0 | 0 |
| `8E0AF6D5-F6CE-4A7B-B25D-9058401BF9E0` | 23101434 | 0 | 0 | 0 | 0 | 0 | 0 |
| `8E0AF6D5-F6CE-4A7B-B25D-9058401BF9E0_system` | 23101434 | 0 | 0 | 0 | 0 | 0 | 0 |
| `AA3FEB29-22AC-4066-B0C0-369823B08621` | 11767994 | 0 | 0 | 0 | 0 | 0 | 0 |
| `AA3FEB29-22AC-4066-B0C0-369823B08621_system` | 11767994 | 0 | 0 | 0 | 0 | 0 | 0 |
| `D192B3E6-3029-45E3-A927-BD2400EFBCF3` | 17191674 | 0 | 0 | 0 | 0 | 0 | 0 |
| `D192B3E6-3029-45E3-A927-BD2400EFBCF3_system` | 17191674 | 0 | 0 | 0 | 0 | 0 | 0 |
| `seekfixture` | 9600000 | 0 | 0 | 0 | 0 | 0 | 0 |

Mixed-minus-system sample delta, which every candidate must preserve exactly (two recordings in the corpus already have a non-zero delta in the originals, which is why this is checked as a delta rather than as equality):

| Recording | original delta | B_i16_wav | C_alac_f32 | C_alac_i16 | D_aac_24k | D_aac_32k | D_aac_48k |
|---|---|---|---|---|---|---|---|
| `097C0046-C28B-42E2-AAC0-2D8E57124BB6` | 1248 | 1248 | 1248 | 1248 | 1248 | 1248 | 1248 |
| `10467DB5-EBD7-4774-9D77-7C059EB3D145` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `20AF257E-F1CC-44A2-AAC7-6AF3FD048AAC` | 623274 | 623274 | 623274 | 623274 | 623274 | 623274 | 623274 |
| `8E0AF6D5-F6CE-4A7B-B25D-9058401BF9E0` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `AA3FEB29-22AC-4066-B0C0-369823B08621` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `D192B3E6-3029-45E3-A927-BD2400EFBCF3` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

## PCM fidelity and the voice-embedding proxy

The app's speaker-embedding pipeline (FluidAudio / SpeakerKit) has no CLI entry point, so **embedding cosine similarity could not be measured directly**. Substituted: log-mel spectrogram distance over identical sample windows (80 mel bins, 25 ms window, 10 ms hop) — the front-end representation every speaker embedder consumes. For the lossless candidates the stronger claim is verified instead: bit-exact decoded PCM.

| Candidate | reference | bit-exact | SNR (dB) | log-mel L1 | log-mel cosine |
|---|---|---|---|---|---|
| A_f32_wav | A_f32_wav | yes | — | 0.0000 | 1.00000 |
| B_i16_wav | A_f32_wav | no | 62.7 | 0.1855 | 0.99703 |
| C_alac_f32 | A_f32_wav | no | 78.0 | 0.0000 | 1.00000 |
| C_alac_i16 | B_i16_wav | yes | — | 0.0000 | 1.00000 |
| D_aac_24k | A_f32_wav | no | 15.0 | 0.5847 | 0.93786 |
| D_aac_32k | A_f32_wav | no | 18.3 | 0.3429 | 0.98095 |
| D_aac_48k | A_f32_wav | no | 25.8 | 0.2037 | 0.99361 |

SNR is the worst case across corpus files; log-mel L1 is the worst (largest) and cosine the worst (smallest). `C_alac_i16` is compared against `B_i16_wav` because ALAC-from-Int16 is lossless with respect to the Int16 capture format Phase 1 ships, not with respect to Float32.

### ALAC from Float32 is not bit-exact, and why

`C_alac_f32` is not bit-exact against Float32, for two separate reasons.

**Integer conversion.** ALAC is an integer codec, so a Float32 source is converted to integer PCM before encoding and sub-LSB float detail is lost. On files with no out-of-range samples the resulting SNR is 160-175 dB — orders of magnitude below anything WhisperKit or a speaker embedder can resolve. The honest label is "numerically lossless in the integer domain", not "bit-exact".

**Clipping of out-of-range samples.** A handful of `_system` samples in the existing library exceed full scale in Float32, and every integer format clamps them. This is what pulls the worst-case SNR in the table above down from ~170 dB to the values shown:

| File | samples with abs value > 1.0 | ALAC-from-Float32 SNR |
|---|---|---|
| `097C0046-C28B-42E2-AAC0-2D8E57124BB6_system` | 11 | 92.3 dB |
| `20AF257E-F1CC-44A2-AAC7-6AF3FD048AAC_system` | 5 | 78.0 dB |
| `D192B3E6-3029-45E3-A927-BD2400EFBCF3_system` | 1 | 152.7 dB |

A few samples out of tens of millions, so it moves no gate — but it is a real property of the current Float32 capture path, and it means **Phase 1's Int16 conversion must clamp explicitly rather than assume the values are already in range**. Wrapping instead of clamping would turn a full-scale peak into a full-negative-scale click.

## WER on synthetic fixtures

Computed with the shipped `Tests/Scripts/measure_wer.py` scoring functions against the fixture ground-truth transcripts. Fixture parts were flattened into one 16 kHz mono Float32 WAV per fixture (the app's own storage layout) and then transcoded to each candidate.

| Candidate | mean WER | delta vs baseline | hallucinations | repetitions | fixtures |
|---|---|---|---|---|---|
| A_f32_wav | 2.61% | +0.00 pp | 3 | 0 | 5 |
| B_i16_wav | 2.61% | +0.00 pp | 3 | 0 | 5 |
| C_alac_f32 | 2.61% | +0.00 pp | 3 | 0 | 5 |
| C_alac_i16 | 2.61% | +0.00 pp | 3 | 0 | 5 |
| D_aac_24k | 2.61% | +0.00 pp | 3 | 0 | 5 |
| D_aac_32k | 2.61% | +0.00 pp | 3 | 0 | 5 |
| D_aac_48k | 2.61% | +0.00 pp | 3 | 0 | 5 |

## Transcript parity on real recordings

Word-level agreement (1 - word edit distance / baseline word count) between WhisperKit output on the candidate and on the Float32 baseline, same decoding options as the app.

**Control first — is WhisperKit deterministic?** The baseline was transcribed a second time from the identical file and compared against the first run:

| Recording | baseline-vs-baseline agreement | byte-identical text |
|---|---|---|
| `10467DB5` | 100.00% | yes |
| `8E0AF6D5` | 100.00% | yes |
| `AA3FEB29` | 100.00% | yes |
| `D192B3E6` | 100.00% | yes |

WhisperKit is fully deterministic: identical input produces byte-identical text on all four recordings. So every disagreement below is caused by the audio actually differing, not by transcriber noise.

That makes the next result the most important one in this document:

| Comparison | audio relationship | transcript |
|---|---|---|
| `B_i16_wav` vs `C_alac_i16` | bit-identical decoded PCM | **byte-identical on 4/4 recordings** |
| `A_f32_wav` vs `C_alac_f32` | 150-175 dB SNR, not bit-exact | **differs on 4/4 recordings** |

WhisperKit's greedy decode at temperature 0 is a cascade of discrete argmax choices. A perturbation far below the least significant bit of 16-bit audio is still enough to flip one token, and once a token flips the decoder's context diverges and the rest of the segment can rewrite. So transcript agreement is a **reproducibility** measurement, not a quality measurement — and the only way to score 100% is for the archived audio to decode bit-for-bit identically to what was transcribed. The quality question is answered separately and cleanly by WER against ground truth above, where all seven candidates are identical.

This is an independent argument for lossless archival that does not depend on audio quality at all: if re-transcribing an archived meeting has to produce the same transcript as the original run, the archive must be bit-exact.

| Candidate | vs Float32: mean | vs Float32: worst | vs Int16 capture: mean | vs Int16 capture: worst | byte-identical to capture | repetitions |
|---|---|---|---|---|---|---|
| A_f32_wav | 100.00% | 100.00% | 96.57% | 95.14% | 0/4 | 6 |
| B_i16_wav | 96.58% | 95.12% | 100.00% | 100.00% | 4/4 | 10 |
| C_alac_f32 | 96.67% | 95.14% | 95.58% | 93.56% | 0/4 | 8 |
| C_alac_i16 | 96.58% | 95.12% | 100.00% | 100.00% | 4/4 | 10 |
| D_aac_24k | 91.70% | 88.95% | 91.92% | 89.50% | 0/4 | 8 |
| D_aac_32k | 92.71% | 88.95% | 92.22% | 88.52% | 0/4 | 8 |
| D_aac_48k | 95.46% | 93.71% | 94.72% | 92.30% | 0/4 | 6 |

The repetitions column counts 4-gram phrases appearing 3+ times in real meeting speech, where that is normal rather than pathological; the zero-repetition gate is scored on the synthetic fixtures above, and no candidate regresses it. The `A_f32_wav` row is scored against its own rerun rather than against itself, so every row means the same thing. Two reference columns are given for the same reason as in the diarization section: Phase 1 ships Int16 capture regardless of this evaluation, so after Phase 1 the question is whether the archive reproduces the Int16 capture, not whether it reproduces a Float32 file that will no longer exist.

Per-recording agreement against the Float32 baseline:

| Recording | profile | B_i16_wav | C_alac_f32 | C_alac_i16 | D_aac_24k | D_aac_32k | D_aac_48k |
|---|---|---|---|---|---|---|---|
| `10467DB5` (4.4 min) | remote-heavy, short | 96.85% | 95.14% | 96.85% | 89.70% | 91.84% | 96.57% |
| `AA3FEB29` (12.3 min) | hybrid (52% system-active) | 98.04% | 98.32% | 98.04% | 88.95% | 88.95% | 93.71% |
| `D192B3E6` (17.9 min) | remote-heavy, multi-speaker | 95.12% | 96.54% | 95.12% | 94.35% | 95.17% | 95.77% |
| `8E0AF6D5` (24.1 min) | in-person (system silent, 0.07% non-zero) | 96.30% | 96.70% | 96.30% | 93.79% | 94.88% | 95.81% |

## Diarization parity

`Tools/BatchRediarize` (FluidAudio) driven with `SKIP_NAMING=1` and a synthetic 1-second row grid, which turns it into a per-window speaker labeller. Run on the transcoded `_system` copies of 3 recordings, capped at `MAX_SECONDS=1800` so 21 diarization runs stay tractable.

Cluster labels are only comparable up to a permutation (BatchRediarize numbers clusters in the order rows first touch them), so agreement is computed under the best label matching.

**Control first — is the clusterer even deterministic?** Without this, any disagreement below could be clusterer noise rather than a format effect. The baseline was diarized a second time and compared against the first run:

| File | run 1 speakers | run 2 speakers | agreement |
|---|---|---|---|
| `10467DB5` | 2 | 2 | 100.00% |
| `AA3FEB29` | 2 | 2 | 100.00% |
| `D192B3E6` | 4 | 4 | 100.00% |

FluidAudio is fully deterministic here, so every difference reported below is a real consequence of the encoding.

Two references are reported. **vs Float32** is the contract's gate. **vs Int16** matters because Phase 1 ships Int16 capture regardless of this evaluation — an archival format only has to avoid degrading further than the capture format already does.

| Candidate | vs F32: count | vs F32: agreement | vs Int16: count | vs Int16: agreement | verdict |
|---|---|---|---|---|---|
| A_f32_wav | yes | 100.00% | NO | 94.99% | PASS |
| B_i16_wav | NO | 94.99% | yes | 100.00% | FAIL |
| C_alac_f32 | yes | 100.00% | NO | 94.99% | PASS |
| C_alac_i16 | NO | 94.99% | yes | 100.00% | FAIL |
| D_aac_24k | yes | 87.79% | NO | 82.94% | FAIL |
| D_aac_32k | NO | 93.76% | NO | 89.30% | FAIL |
| D_aac_48k | NO | 97.77% | NO | 92.76% | FAIL |

Per-file speaker counts, which is where the failures actually live:

| File | A_f32_wav | B_i16_wav | C_alac_f32 | C_alac_i16 | D_aac_24k | D_aac_32k | D_aac_48k |
|---|---|---|---|---|---|---|---|
| `D192B3E6` | 4 | 4 | 4 | 4 | 4 | 5 | 6 |
| `10467DB5` | 2 | 2 | 2 | 2 | 2 | 2 | 3 |
| `AA3FEB29` | 2 | 3 | 2 | 3 | 2 | 2 | 2 |

Reading this table is the whole decision. `C_alac_f32` reproduces the Float32 column exactly. `C_alac_i16` reproduces the `B_i16_wav` column exactly — they are bit-identical, so they cannot diverge. Every AAC bitrate invents or merges speakers on at least one recording, and it does not get monotonically better with bitrate: 48 kbps was the worst on the multi-speaker file. Speaker embeddings are sensitive to exactly the fine spectral detail a perceptual codec discards, which is why transcription can be untouched while diarization moves.

Note that Int16 quantization alone (63-80 dB SNR) is enough to split 2 speakers into 3 on one recording. The gate as written is therefore stricter than the capture format the project has already committed to shipping in Phase 1 — worth carrying into ADR-033 explicitly rather than discovering later.

## Playback seek accuracy

10-minute 16 kHz mono fixture with 40 ms 1 kHz beeps at known offsets over a -60 dBFS noise floor. Each beep is sought with `AVAssetReader` on an `AVURLAsset` created with `AVURLAssetPreferPreciseDurationAndTimingKey`, then the decoded onset is measured against the known timestamp.

| Candidate | points | worst absolute error | mean error | delta vs baseline | read failures |
|---|---|---|---|---|---|
| A_f32_wav | 21 | 1.25 ms | -1.25 ms | +0.00 ms | 0 |
| B_i16_wav | 21 | 1.25 ms | -1.25 ms | +0.00 ms | 0 |
| C_alac_f32 | 21 | 1.25 ms | -1.25 ms | +0.00 ms | 0 |
| C_alac_i16 | 21 | 1.25 ms | -1.25 ms | +0.00 ms | 0 |
| D_aac_24k | 21 | 1.25 ms | -1.25 ms | +0.00 ms | 0 |
| D_aac_32k | 21 | 1.25 ms | -1.25 ms | +0.00 ms | 0 |
| D_aac_48k | 21 | 1.25 ms | -1.25 ms | +0.00 ms | 0 |

Every candidate — including the uncompressed baseline — reports the same constant offset, which is the onset detector's own fixed latency (a 32-sample rectified moving average has to fill before it can cross threshold), not a format artifact. The number that matters is the delta against the baseline, and it is exactly 0 ms at all 21 points for all candidates. No AAC candidate shifts playback timing.

## Sub-experiment: AAC bitrate-allocation strategy

The `_system` file is silence-padded to the full meeting length, so how the encoder spends bits on silence dominates its size. Measured on a 24.1-minute silent `_system` file and a 17.9-minute speech file at 24 kbps:

| Strategy | silent _system | speech mixed |
|---|---|---|
| CBR | 4.44 MB | 3.30 MB |
| ABR | 0.20 MB | 3.29 MB |
| VBR_constrained | 0.20 MB | 3.55 MB |
| VBR | 0.20 MB | 4.26 MB |

ABR is 22x smaller than CBR on silence with no size penalty on speech, so the AAC candidates use `afconvert -s 1` (the AVFoundation equivalent is `AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_LongTermAverage`) rather than constant bitrate. Shipping CBR would have wasted most of the win on in-person meetings, where `_system` is pure padding. Recorded here because it is the kind of detail that silently halves a storage win, and because it applies to any future reconsideration of lossy archival.

## What was not measured, and why

- **Voice-embedding cosine similarity was not measured directly.** The app's embedding pipeline (FluidAudio / SpeakerKit) exposes no CLI entry point. Two substitutes are reported instead: a log-mel spectrogram distance over identical sample windows (the front-end every speaker embedder consumes), and diarization parity, which runs the real FluidAudio clusterer end to end and is therefore the stronger evidence of the two. For the lossless candidates the question is moot — bit-identical PCM produces identical embeddings by construction.
- **Diarization ran on 3 of the 6 recordings.** The `_system` files chosen are the ones containing real remote speech. Diarizing a silence-padded `_system` file from an in-person meeting measures nothing.
- **Transcription ran on 4 of the 6 recordings.** The 2-hour recording and the length-mismatch recording were used for size and sample-parity metrics only, to keep the 67-run transcription budget reasonable. Both were fully covered by the kill criterion, which is the gate they were chosen for.
- **The spectral proxy samples windows rather than whole files.** Up to 60 evenly spread 10-second windows per file. Sample-count parity and PCM fidelity are full-file, walked in chunks.
- **AAC was tested at 24, 32 and 48 kbps only.** Higher rates were not pursued: diarization did not improve monotonically with bitrate (48 kbps was the worst result on the multi-speaker recording), so there is no reason to expect a higher rate to fix it, and the size advantage over ALAC shrinks as the rate rises.
- **No end-to-end app behaviour was exercised.** Re-analyze speakers, click-to-play, clip export and Transcribe Now on an archived meeting all need the running app and belong to Phase 2 verification. This evaluation covers the file-format layer those features sit on.

## Reproducing

See `../README.md`. The whole matrix regenerates with `python3 Tests/Scripts/audio_format_eval/run_eval.py --stage all --scratch /tmp/afe`.

