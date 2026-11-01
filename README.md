# sailfish-tgcalls

An experiment toward Telegram voice and video calls on Sailfish OS.

Native Sailfish Telegram clients (Fernschreiber, Yottagram, YAST) use TDLib, which handles call
setup but not the media. The media part is Telegram's
[tgcalls](https://github.com/TelegramMessenger/tgcalls) library on top of WebRTC, in Telegram's
CMake-buildable fork [tg_owt](https://github.com/desktop-app/tg_owt).

## Plan

1. **Build test (now):** compile tg_owt with the Sailfish Platform SDK for aarch64 in CI.
2. Build tgcalls against it.
3. A command-line test: an outgoing voice call through TDLib + tgcalls, audio via PulseAudio.
4. Incoming calls, ringing, call UI, then integration into an existing client.
5. Video: camera frames from the Sailfish camera stack (gst-droid) and rendering in QML.

## Status

Step 1 is running in [Actions](../../actions). Logs and a summary are uploaded as an artifact.

## License

The CI scripts here are MIT. tg_owt and tgcalls keep their own licenses (BSD-style and LGPL-3.0).
