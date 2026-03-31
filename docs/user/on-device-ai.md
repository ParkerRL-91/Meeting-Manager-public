# On-Device AI

Meeting Manager supports fully local AI summarization using [Ollama](https://ollama.com) — an open-source runtime that runs language models on your Mac. When enabled, no meeting data ever leaves your device.

---

## Enabling On-Device Summarization

1. Open **Settings → On-Device**
2. Toggle **Use On-Device Summarization**

That's it. Meeting Manager handles everything automatically:

| Step | What happens |
|------|-------------|
| **Download Ollama** | ~60 MB, downloaded from GitHub |
| **Install** | Installed to `~/Applications/Ollama.app` |
| **Launch** | Ollama starts in the background |
| **Download model** | `llama3.2:3b` pulled (~2 GB) |

You'll see a live progress bar for each step. The first-time setup takes a few minutes depending on your internet speed.

---

## After Setup

Once the model is ready, the On-Device tab shows:

- **Ollama status** — running / not running
- **Available models** — models currently installed in Ollama
- **Model picker** — select which model to use for summaries

Summaries now generate entirely on your Mac. No API key required, no data sent anywhere.

---

## Switching Between Claude and On-Device

The toggle in **Settings → On-Device** controls which AI is used:

- **Toggle on** → summaries use Ollama (local)
- **Toggle off** → summaries use Claude (cloud, requires API key)

You can switch at any time. Existing summaries are not affected.

---

## Choosing a Model

The default model is `llama3.2:3b` — a good balance of speed and quality on Apple Silicon. You can pull additional models from Ollama and select them in the model picker:

```bash
# In Terminal (Ollama must be running)
ollama pull llama3.2:8b     # higher quality, slower
ollama pull mistral          # alternative model
```

Larger models produce better summaries but take longer to generate and use more RAM.

| Model | RAM | Speed | Quality |
|-------|-----|-------|---------|
| llama3.2:3b | ~3 GB | Fast | Good |
| llama3.2:8b | ~6 GB | Medium | Better |
| llama3.1:70b | ~40 GB | Slow | Best |

---

## If Ollama Stops Running

Ollama runs as a background process. If you restart your Mac, Ollama won't start automatically unless you configure it to. If Meeting Manager shows "Ollama not running":

1. Toggle the **Use On-Device Summarization** switch off, then back on — this restarts Ollama
2. Or open `~/Applications/Ollama.app` manually

---

## Privacy

When on-device mode is enabled:
- Transcripts are processed entirely on your Mac
- No data is sent to Anthropic or any external service
- Ollama communicates only with `localhost:11434`
- The Ollama server has no internet access during inference

Transcription via WhisperKit is always on-device regardless of this setting.
