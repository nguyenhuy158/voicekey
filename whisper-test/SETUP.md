# Whisper Vietnamese-Accent Test

Quick test script to verify Whisper handles Vietnamese-accented English on macOS.

## Setup (one-time)

### 1. Install whisper.cpp

```bash
# Option A: Homebrew (easiest)
brew install whisper-cpp

# Option B: Build from source (more control, has Metal support)
git clone https://github.com/ggerganov/whisper.cpp ~/whisper.cpp
cd ~/whisper.cpp
make
```

### 2. Download a model

```bash
# Option A: homebrew
brew install whisper-cpp  # auto-downloads base.en on first run, or:
whisper-cli --download-models base.en  # if supported

# Option B: from source
cd ~/whisper.cpp
bash ./models/download-ggml-model.sh base.en
```

**Recommended models for Vietnamese-accented English:**
- `base.en` (142 MB) — fast, good for testing
- `small.en` (466 MB) — better accuracy
- `medium.en` (1.5 GB) — best accuracy, slower on M1

Start with `base.en`. If accuracy is bad, upgrade to `small.en` or `medium.en`.

## Run the test

```bash
cd /Users/huyntq/Documents/macos-app/whisper-test
./test_whisper.swift          # 5 second recording (default)
./test_whisper.swift 10       # 10 second recording
```

The script will:
1. Ask mic permission (first run only)
2. Record for N seconds
3. Run whisper.cpp
4. Print the English transcript

## Test phrases to try

Say these (Vietnamese-accented English):

1. "Hello, my name is [your name]"
2. "I would like to order a coffee"
3. "The weather is very hot today"
4. "Could you please help me with this"
5. "I am working on a software application"

## What to evaluate

- ✅ Correct words despite accent
- ✅ Grammar preserved
- ⚠️ Common errors: "th" → "z/s", "v" → "w", dropped articles ("a", "the")
- ⚠️ Vietnamese-style word stress

If `base.en` struggles, upgrade to `small.en` or `medium.en`.
If even `medium.en` struggles with technical terms, you may need to fine-tune.

## Troubleshooting

**"Model not found"** → Run the download step above, or move the model to one of these paths:
- `~/whisper.cpp/models/`
- `~/Documents/macos-app/whisper-test/`
- Same dir as the script

**"Whisper binary not found"** → Run `brew install whisper-cpp` or `make` in whisper.cpp dir.

**"Failed to start recording"** → System Settings → Privacy & Security → Microphone → enable Terminal (or iTerm).