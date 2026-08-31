#!/bin/bash
set -e
MODEL_DIR="$HOME/.config/voicekey/models"
MODEL="${1:-base.en}"   # tiny.en | base.en | small.en | medium.en | large-v3
mkdir -p "$MODEL_DIR"

command -v whisper-cli >/dev/null || brew install whisper-cpp

DEST="$MODEL_DIR/ggml-$MODEL.bin"
if [ -f "$DEST" ]; then
  echo "Model already present: $DEST"
else
  echo "Downloading ggml-$MODEL.bin ..."
  curl -L --fail -o "$DEST" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
fi
echo "Done. Model: $DEST"
[ "$MODEL" != "base.en" ] && echo "Set \"model\" to this path in ~/.config/voicekey/config.json"
exit 0
