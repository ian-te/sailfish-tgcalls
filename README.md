# sailfish-tgcalls

CI builds of Fernschreiber with Telegram voice and video calls for Sailfish OS.

## What this builds

The call support itself is someone else's work: [Fernschreiber PR #583](https://github.com/Wunderfitz/harbour-fernschreiber/pull/583)
by JimKnopfIoT adds 1:1 voice and video calls, tested on a Jolla Phone with Sailfish OS 5.2. It isn't
merged yet and has no published builds. The [workflow](.github/workflows/build.yml) here builds it in CI,
following the branch's `doc/voicecalls.md`:

1. openh264 v2.6.0 from source (Sailfish doesn't package it), bundled in the RPM
2. tg_owt (Michal-Szczepaniak fork, `3215153`), static, cached between runs
3. tgcalls (Michal-Szczepaniak fork, `8a5b4eb`), compiled into the app
4. Fernschreiber `voice-calls` with `--with voicecalls`, TDLib 1.8.67 from Wunderfitz/td

Target: the newest aarch64 target in the community SDK image (currently 5.2). The bundled library
SONAMEs are adjusted to that target's.

## Telegram API credentials

Telegram clients need an `api_id` and `api_hash` from [my.telegram.org](https://my.telegram.org).
Because this repository and its builds are public, none are compiled in. The app reads them at
startup from its own config directory:

```
~/.config/de.ygriega/fernschreiber/api.conf
```
```ini
api_id=1234567
api_hash=0123456789abcdef0123456789abcdef
```

## Installing

Download the RPM from the workflow run's artifact, then on the phone:

```sh
devel-su rpm -Uvh harbour-fernschreiber-*.aarch64.rpm
```

The RPM also installs a PulseAudio policy rule (`/etc/pulse/xpolicy.conf.d/harbour-fernschreiber.conf`);
without it you can't hear the other side. See the PR for why.

## License

The CI scripts here are MIT. Fernschreiber is GPL-3.0; tg_owt, tgcalls and openh264 keep their own licenses.
