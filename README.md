# VoiceKey

Hold a key, talk, release — the transcript is typed into whatever app is focused.
Local whisper.cpp, nothing leaves the machine.

## Download

Grab the latest `VoiceKey-vX.Y.Z.zip` from
[Releases](https://github.com/nguyenhuy158/voicekey/releases), unzip it into
`/Applications`, and clear the quarantine flag once (the build is ad-hoc signed):

    xattr -dr com.apple.quarantine /Applications/VoiceKey.app

Then `./setup.sh` (or `brew install whisper-cpp` plus a model) for the engine.

## Build from source

    ./setup.sh          # brew install whisper-cpp + download ggml-base.en (141MB)
    ./build.sh          # produces VoiceKey.app
    open VoiceKey.app

First launch asks for **Microphone** and **Accessibility** permission.
Accessibility must be granted in System Settings → Privacy & Security, then relaunch the app.

## Use

Menu-bar mic icon. Hold **fn**, speak, release. Icon shows state:
mic (idle) → waveform (recording) → hourglass (transcribing).

**Change key…** in the menu — press any key or modifier. Escape cancels.

## Config

`~/.config/voicekey/config.json` — model path, language, whisper-cli path.
Bigger model = better accuracy, slower:

    ./setup.sh small.en     # then point "model" at it in config.json

## Sau khi rebuild

`./build.sh` ký lại ad-hoc nên chữ ký đổi → macOS coi là app khác và quyền
Accessibility cũ không còn khớp. Nếu giữ phím mà không ăn:

    tccutil reset Accessibility local.voicekey
    killall VoiceKey; open VoiceKey.app

Rồi bấm Allow ở hộp thoại hệ thống. App tự bắt lại phím sau 2s, không cần
khởi động lại.

## Debug phím

    killall VoiceKey; ./VoiceKey.app/Contents/MacOS/VoiceKey --debug 2>&1 | grep "code=61"

In ra mọi sự kiện phím mà tap nhận được, kèm keycode đang chờ.
