#!/bin/bash
# Runs inside the Sailfish Platform SDK image. Builds tg_owt (Telegram's WebRTC) for one target.
# Writes logs and a summary to /out. Does not fail early: the point is to learn how far it gets.
set -u
ARCH=$1
OUT=/out
log() { echo "$*" | tee -a $OUT/summary.txt; }

target=$(ls /srv/mer/targets | grep -E "^SailfishOS-[0-9.]+-${ARCH}\$" | sort -V | tail -1)
log "target: $target"
sb() { sb2 -t "$target" "$@"; }
sbroot() { sb2 -t "$target" -m sdk-install -R "$@"; }

# 1. What the target gives us.
{
  echo "== gcc";   sb gcc --version
  echo "== g++";   sb g++ --version
  echo "== cmake"; sb cmake --version
  echo "== ninja"; sb ninja --version
  echo "== os-release"; cat /srv/mer/targets/$target/etc/os-release
} > $OUT/toolchain.txt 2>&1
log "gcc: $(sb gcc -dumpfullversion 2>/dev/null || echo none)"
log "cmake: $(sb cmake --version 2>/dev/null | head -1 || echo none)"

# 2. Dependencies, one at a time so one missing name doesn't block the rest.
# tg_owt bundles most of WebRTC's third-party code; these are the system ones it looks for on Linux.
for pkg in cmake ninja make pkgconfig openssl-devel libjpeg-turbo-devel opus-devel \
           libvpx-devel ffmpeg-devel libavcodec-devel pulseaudio-devel alsa-lib-devel \
           glib2-devel libdrm-devel mesa-llvmpipe-libgbm-devel protobuf-devel yasm nasm; do
  if sbroot zypper --non-interactive in "$pkg" >> $OUT/deps.txt 2>&1; then
    log "dep ok:      $pkg"
  else
    log "dep missing: $pkg"
  fi
done

# 3. Build. X11 and PipeWire capture are desktop-only; Sailfish needs its own camera path later.
mkdir -p $HOME/build && cp -r /src/tg_owt $HOME/tg_owt
cd $HOME/build
if sb cmake ../tg_owt -G Ninja \
     -DCMAKE_BUILD_TYPE=Release \
     -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
     -DTG_OWT_USE_X11=OFF -DTG_OWT_USE_PIPEWIRE=OFF -DTG_OWT_USE_PROTOBUF=OFF \
     -DTG_OWT_BUILD_AUDIO_BACKENDS=ON \
     > $OUT/configure.txt 2>&1; then
  log "configure: ok"
else
  log "configure: FAILED (see configure.txt)"
  tail -40 $OUT/configure.txt >> $OUT/summary.txt
  exit 0
fi

start=$(date +%s)
if sb ninja -k 0 -j"$(nproc)" > $OUT/build.txt 2>&1; then
  log "build: ok in $(( ($(date +%s) - start) / 60 )) min"
  ls -l $HOME/build/*.a >> $OUT/summary.txt 2>&1
  touch $OUT/SUCCESS
else
  log "build: FAILED after $(( ($(date +%s) - start) / 60 )) min"
  log "failed objects: $(grep -c '^FAILED:' $OUT/build.txt)"
  # The first distinct compiler errors are what matters.
  grep -E 'error:' $OUT/build.txt | sort | uniq -c | sort -rn | head -40 >> $OUT/summary.txt
fi
exit 0
