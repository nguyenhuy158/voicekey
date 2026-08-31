# Known issues

## 1. Mixed Vietnamese + English in one sentence transcribes badly

Whisper detects a single language per clip. Code-switching mid-sentence
("cái này là a good idea") forces the minority words into the detected
language and produces garbage.

Not an app bug — a model limitation.

**Workarounds today:** one language per hold.

**Planned fixes:**
- Upgrade to `large-v3-turbo`, which handles code-switching much better
  (`./setup.sh large-v3-turbo`, then update `model` in config.json).
- Optional second hotkey that pins the language (fn = en, other key = vi)
  instead of relying on auto-detect.
