# On-Device AI (Ollama)

Meeting Manager can run summarization, attribution, and chat entirely on your Mac via Ollama. Free, private, offline.

## Why Ollama?

- **Privacy** — no transcript or attendee data leaves your Mac
- **Free** — no per-request costs
- **Offline** — works on a plane, in a SCIF, behind a strict proxy
- **Fast iteration** — change models freely without API quota

Tradeoffs vs Claude:
- Slower (30s–3min per summary depending on model + hardware)
- Lower quality on long-context summaries (smaller models drift; larger models slow)
- Manual model selection — no "best for everything" choice

---

## Setup

### 1. Install Ollama

Download from [ollama.com](https://ollama.com) → run the installer → Ollama starts as a background service on `http://localhost:11434`.

Verify in Terminal:
```bash
curl http://localhost:11434/api/tags
```
Should return a JSON list (probably empty on first install).

### 2. Pull a model

```bash
ollama pull llama3.2:8b
```

Recommended starter models by Mac type:

| Mac | Model | RAM needed | Quality |
|---|---|---|---|
| M1/M2/M3, 16GB | `llama3.2:8b` | ~5GB | Good |
| M-series, 32GB | `llama3.1:70b-instruct-q4_K_M` | ~22GB | Excellent |
| M3 Ultra / Mac Studio, 64GB+ | `llama3.1:70b-instruct-q8_0` | ~38GB | Excellent + faster |
| Intel Mac | `phi3:mini` or `qwen2.5:3b` | ~2GB | Acceptable |

Meeting Manager auto-detects whatever models you have installed.

### 3. Connect Meeting Manager

Settings → **AI (Local)** →
- Status row shows whether Ollama is reachable
- Model picker lists every model you've pulled
- Pick one and set **Use local LLM** to **On**

You can switch back and forth between Claude and Local at any time.

---

## Auto Mode

Meeting Manager has an "auto" model selection that picks the best installed model per task:

- Short prompts (attribution, action items) → smaller / faster model
- Long prompts (summary, follow-up email) → larger / smarter model

Enable in Settings → AI (Local) → **Auto-pick model**.

---

## Performance Tips

- **Quantization matters.** `q4_K_M` is ~4× faster than `f16` and barely worse for summaries.
- **Avoid `llama3.1:70b` on 32GB.** It pages to swap and slows to a crawl.
- **Keep Ollama running.** Cold-start of a 70B model takes 60+ seconds.
- **Use multiple models.** Ollama can hold 2–3 small models in RAM simultaneously, useful for auto mode.

---

## Confidence Indicator

When using Ollama for speaker attribution, you'll see a small amber dot next to attributed speaker labels. This is by design — Ollama attributions are scored at 0.62 confidence (vs 0.72 for Claude haiku, 0.78 for Sonnet). The dot flags labels worth a glance, not errors.

If the labels are correct, ignore the dots — they disappear as soon as you confirm or rename. If you want the dots gone entirely, switch attribution to Claude in Settings → AI (Claude).

---

## Common Issues

### "Ollama unreachable"
The Ollama service isn't running. Either click the Ollama menu bar icon, or in Terminal: `ollama serve`.

### "No models installed"
Pull at least one: `ollama pull llama3.2:8b`. The picker populates within ~5 seconds.

### Generation hangs / takes forever
- Model loading from disk after a pull or eviction → wait 30–60s
- Wrong model for hardware → try a smaller one
- macOS swap pressure → quit other apps

### Quality is noticeably worse than Claude
This is expected for smaller / older models. Try:
- A bigger model (q4_K_M variant, 70B if you have RAM)
- Tweak the prompt template (Settings → Prompts) to be more directive
- Use Claude for the summary and Ollama for cheaper tasks

---

## Why Not MLX or llama.cpp?

Meeting Manager intentionally uses Ollama's HTTP API rather than embedding MLX or llama.cpp directly:

1. **SPM conflict** — WhisperKit (used for transcription) depends on a specific MLX revision that conflicts with the latest llama.cpp Swift bindings. Embedding either would force WhisperKit to fall back to CPU, slowing transcription 3–5×.
2. **Model management** — Ollama already handles CLI, model registry, GPU acceleration, and quantization. Reproducing all that in-app would duplicate work.

The HTTP boundary is a clean separation: Meeting Manager doesn't know how the model runs, just that there's a `localhost:11434` to talk to.
