#!/bin/bash
# Runs inside the Sailfish Platform SDK image with the workspace mounted at $W (under /home).
# Builds openh264 -> tg_owt -> Fernschreiber with calls (PR #583), aarch64, and drops the RPM in $W/out.
# Sources are fetched by the workflow into $W/src/{openh264,tg_owt,tgcalls,fernschreiber}.
set -euo pipefail
ARCH=${1:-aarch64}
W=${W:-/work}  # must be under /home: the scratchbox2 build view only maps the host paths it knows
OUT=$W/out
mkdir -p $OUT
log() { echo "== $*" | tee -a $OUT/summary.txt; }

target=$(ls /srv/mer/targets | grep -E "^SailfishOS-[0-9.]+-${ARCH}\$" | sort -V | tail -1)
log "target $target"
sb()     { sb2 -t "$target" "$@"; }
sbroot() { sb2 -t "$target" -m sdk-install -R "$@"; }
log "user $(whoami), HOME $HOME, workspace $W"
if ! (cd $W/src/openh264 && sb test -f Makefile); then
  log "scratchbox2 cannot see $W"; exit 1
fi

# --- Target dependencies (the ones Fernschreiber's spec doesn't already pull in) ---
log "installing target build dependencies"
sbroot zypper --non-interactive in \
  openssl-devel libjpeg-turbo-devel opus-devel libvpx-devel ffmpeg-devel \
  pulseaudio-devel alsa-lib-devel glib2-devel libdrm-devel nasm \
  qt5-qtmultimedia-devel qt5-qtsensors-devel > $OUT/deps.txt 2>&1 \
  || { log "dependency install failed"; tail -30 $OUT/deps.txt | tee -a $OUT/summary.txt; exit 1; }

# --- 1. openh264, installed into the target so pkg-config and the linker find it ---
log "building openh264"
cd $W/src/openh264
sb make -j"$(nproc)" OS=linux ARCH=arm64 USE_ASM=Yes PREFIX=/usr LIBDIR_NAME=lib64 > $OUT/openh264.txt 2>&1 \
  || { log "openh264 build failed"; tail -40 $OUT/openh264.txt | tee -a $OUT/summary.txt; exit 1; }
# make isn't available in the target's root mode, so stage the install as the build user and copy
# it into the target with cp.
sb make OS=linux ARCH=arm64 PREFIX=/usr LIBDIR_NAME=lib64 DESTDIR=$W/deps/stage install-shared >> $OUT/openh264.txt 2>&1 \
  || { log "openh264 install failed"; tail -20 $OUT/openh264.txt | tee -a $OUT/summary.txt; exit 1; }
# install-shared puts the libraries in lib/ whatever LIBDIR_NAME says; the target's are in lib64/.
if [ -d $W/deps/stage/usr/lib ]; then
  mv $W/deps/stage/usr/lib/libopenh264* $W/deps/stage/usr/lib64/ && rmdir $W/deps/stage/usr/lib
fi
sed -i 's|^libdir=.*|libdir=/usr/lib64|' $W/deps/stage/usr/lib64/pkgconfig/openh264.pc
cat $W/deps/stage/usr/lib64/pkgconfig/openh264.pc >> $OUT/openh264.txt
sbroot cp -a $W/deps/stage/usr/. /usr/ >> $OUT/openh264.txt 2>&1 \
  || { log "copying openh264 into the target failed"; tail -10 $OUT/openh264.txt | tee -a $OUT/summary.txt; exit 1; }
mkdir -p $W/deps/openh264
cp -L $W/deps/stage/usr/lib64/libopenh264.so.8 $W/deps/openh264/
sb pkg-config --modversion openh264 >> $OUT/summary.txt 2>&1 \
  || { log "pkg-config can't find openh264 in the target"; exit 1; }
log "openh264 ok: $(ls $W/deps/openh264)"

# --- 2. tg_owt (static), restored from cache when its revision hasn't changed ---
if [ -f $W/src/tg_owt/out/libtg_owt.a ]; then
  log "tg_owt from cache"
else
  log "building tg_owt"
  start=$(date +%s)
  mkdir -p $W/src/tg_owt/out && cd $W/src/tg_owt/out
  sb cmake .. \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DTG_OWT_PACKAGED_BUILD=ON \
      -DTG_OWT_BUILD_AUDIO_BACKENDS=ON -DTG_OWT_USE_X11=OFF -DTG_OWT_USE_PIPEWIRE=OFF \
      -DTG_OWT_USE_PROTOBUF=OFF \
      -DCMAKE_CXX_FLAGS="-include cstdint" > $OUT/tg_owt-configure.txt 2>&1 \
    || { log "tg_owt configure failed"; tail -40 $OUT/tg_owt-configure.txt | tee -a $OUT/summary.txt; exit 1; }
  # -k: keep going, so one run shows every file that doesn't compile, not just the first.
  # -include cstdint above: GCC 13 no longer pulls in <cstdint> transitively, and this WebRTC
  # snapshot predates that (first hit: rtc_base/third_party/base64/base64.h).
  if ! sb make -k -j"$(nproc)" > $OUT/tg_owt-build.txt 2>&1; then
    log "tg_owt build failed after $(( ($(date +%s) - start) / 60 )) min"
    log "files with errors: $(grep -oE '^[^ :]+\.(cc|cpp|c|h|S):[0-9]+:[0-9]+: error' $OUT/tg_owt-build.txt | cut -d: -f1 | sort -u | wc -l)"
    grep -E ': (fatal )?error:' $OUT/tg_owt-build.txt | sed -E 's|^/home/mersdk/work/src/tg_owt/||' | sort -u | head -60 | tee -a $OUT/summary.txt
    exit 1
  fi
  log "tg_owt ok in $(( ($(date +%s) - start) / 60 )) min"
fi

# --- 3. Fernschreiber with calls ---
cd $W/src/fernschreiber

# TDLib, prebuilt for Sailfish by Fernschreiber's maintainer.
unzip -qo $W/src/tdlib.zip -d tdlib
ls tdlib/$ARCH/lib >> $OUT/summary.txt

# Telegram API credentials (my.telegram.org). This repository and its RPMs are public, so none are
# compiled in: the app reads them at startup from a file in its own Sailjail config directory,
#   ~/.config/de.ygriega/fernschreiber/api.conf   with lines  api_id=...  and  api_hash=...
# tdlibwrapper.cpp only uses TDLIB_API_ID / TDLIB_API_HASH as values for a QVariantMap, so macros
# returning QString work there unchanged.
cat > src/tdlibsecrets.h <<'EOF'
#ifndef TDLIBSECRETS_H
#define TDLIBSECRETS_H
#include <QDir>
#include <QSettings>
#include <QString>
static inline QString fernschreiberApiValue(const char *key)
{
    QSettings conf(QDir::homePath() + "/.config/de.ygriega/fernschreiber/api.conf", QSettings::IniFormat);
    return conf.value(QString::fromLatin1(key)).toString().trimmed();
}
#define TDLIB_API_ID fernschreiberApiValue("api_id")
#define TDLIB_API_HASH fernschreiberApiValue("api_hash")
#endif // TDLIBSECRETS_H
EOF
log "API credentials: read at runtime from ~/.config/de.ygriega/fernschreiber/api.conf"

# voip.pri bundles the multimedia libraries by SONAME, as found on 4.6/5.0 targets. Newer targets
# moved some (5.1+ ships libvpx.so.12), so swap each missing one for what this target has.
sysroot=/srv/mer/targets/$target
for soname in $(sed -n '/^BUNDLED_SONAMES/,/^$/p' voip.pri | tr -s ' \\' '\n' | grep '\.so\.'); do
  [ -e $sysroot/usr/lib64/$soname ] && continue
  base=${soname%.so.*}
  found=$(cd $sysroot/usr/lib64 && ls $base.so.[0-9]* 2>/dev/null | grep -E "^$base\.so\.[0-9]+\$" | sort -V | tail -1 || true)
  if [ -n "$found" ]; then
    log "SONAME $soname -> $found on this target"
    sed -i "s/\b$soname\b/$found/" voip.pri
  else
    log "SONAME $soname not found on this target"
  fi
done

# A test-build release number: above the branch's 0.19-1 (and any installed 0.18), below a real 0.19-2.
sed -i "s/^Release:.*/Release:    1.calls.${GITHUB_RUN_NUMBER:-0}/" rpm/harbour-fernschreiber.spec

log "building Fernschreiber with calls"
start=$(date +%s)
if ! mb2 -t $target build -- --with voicecalls \
       --define "tg_owt_root $W/src/tg_owt" \
       --define "tgcalls_root $W/src/tgcalls" \
       --define "openh264_root $W/deps/openh264" > $OUT/fernschreiber.txt 2>&1; then
  log "Fernschreiber build failed after $(( ($(date +%s) - start) / 60 )) min"
  { grep -E 'error|Error' $OUT/fernschreiber.txt | head -40; tail -30 $OUT/fernschreiber.txt; } | tee -a $OUT/summary.txt
  exit 1
fi
log "Fernschreiber ok in $(( ($(date +%s) - start) / 60 )) min"

cp RPMS/*.rpm $OUT/
for r in $OUT/*.rpm; do
  echo "--- $(basename $r)" >> $OUT/summary.txt
  rpm -qp --requires $r 2>/dev/null >> $OUT/summary.txt || true
  rpm -qlp $r 2>/dev/null | grep -E 'lib/|pulse' >> $OUT/summary.txt || true
done
log "done"
