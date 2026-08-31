#!/bin/bash
set -e
MODEL_DIR="$HOME/.config/voicekey/models"
MODEL="${1:-large-v3-turbo-q5_0}"   # tiny.en | base.en | small | medium | large-v3-turbo-q5_0
# large-v3-turbo is multilingual — base.en/small.en are English-only and mangle Vietnamese.
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
[ "$MODEL" != "large-v3-turbo-q5_0" ] && echo "Set \"model\" to this path in ~/.config/voicekey/config.json"
exit 0
