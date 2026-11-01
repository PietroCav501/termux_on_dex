#!/data/data/com.termux/files/usr/bin/bash
# costruisci.sh [CARTELLA_SORGENTI]: compila LKL (il codice di Linux come libreria) per Android, tod-lkl e
# il disco finto dei comandi da terminale, in Termux, a bassa priorità. Risultato in ~/.local/share/tod-usb:
# liblkl.so, tod-lkl, tod-disco.so e tod-fs.so (più le versioni -glibc per il container), che il servizio
# dei dischi, share/bin/tod-disco e la sessione (/media/usb come cartelle vere) usano.
# La prima volta scarica i sorgenti (~2 GB) e compila ~8-10 minuti
# (S26); le volte dopo solo ciò che è cambiato.
#
# Correzioni per Android (bionic + clang di Termux), tutte qui:
#   android.patch    LLVM per aarch64 nel Makefile di LKL; bcmp → memcmp negli strumenti del kernel
#   disco-thread.patch  le letture del disco in un thread per disco, non in quello del kernel (un hard
#                    disk lento fermava tutto LKL, anche le letture già in memoria)
#   compat-host.h    ELF64_ST_* e R_ARM_* che bionic non ha (strumenti del kernel: HOSTCFLAGS)
#   compat-lkl.h     _GNU_SOURCE (preadv) e le macro st_*_nsec di bionic tolte (libreria: CFLAGS)
#   configurazione   exFAT e NTFS3 accesi (il defconfig di LKL non li ha)
set -euo pipefail
QUI=$(cd "$(dirname "$0")" && pwd)
TH="${TOD_TERMUX_HOME:-$HOME}"
DATA="$TH/.local/share/tod-usb"
SRC=${1:-$DATA/lkl-sorgenti}
VERSIONE=d0f76a77e8c2ca68bd7d96190b8da09040eab072   # lkl/linux, 28 settembre 2026: quella provata
mkdir -p "$DATA"

cur=$(awk '{print $19}' /proc/$$/stat)   # bassa priorità vera (nice assoluto 19), anche dal desktop (-10)
renice -n $((19 - cur)) -p $$ >/dev/null 2>&1 || true
ionice -c3 -p $$ 2>/dev/null || true

for p in clang lld make git bison flex bc libusb argp fdisk dosfstools exfatprogs e2fsprogs; do
  dpkg -s "$p" >/dev/null 2>&1 || apt-get install -y "$p"
done

if [[ ! -d $SRC/.git ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/lkl/linux "$SRC"
fi
cd "$SRC"
if [[ $(git rev-parse HEAD 2>/dev/null) != "$VERSIONE" ]]; then
  git fetch --depth 1 origin "$VERSIONE"
  git checkout -q --force "$VERSIONE"
fi
for p in android disco-thread; do
  git apply --check "$QUI/$p.patch" 2>/dev/null && git apply "$QUI/$p.patch"
done

M=(make -C tools/lkl -j"$(nproc)" LLVM=1 CROSS_COMPILE=aarch64-unknown-linux-android24
   HOSTCFLAGS="-include $QUI/compat-host.h")
# la configurazione nasce al primo make: poi exFAT e NTFS3
if [[ ! -f .config ]]; then CFLAGS="-include $QUI/compat-lkl.h" "${M[@]}" "$PWD/tools/lkl/../../.config" || true; fi
./scripts/config --file .config -e EXFAT_FS -e NTFS3_FS -e NTFS3_LZX_XPRESS -e NLS_UTF8
# basta la libreria (gli strumenti di LKL, cptofs e lklfuse, non servono)
CFLAGS="-include $QUI/compat-lkl.h" "${M[@]}" "$PWD/tools/lkl/lib/liblkl.so"

install -m 0755 tools/lkl/lib/liblkl.so "$DATA/liblkl.so.nuovo"
llvm-strip --strip-debug "$DATA/liblkl.so.nuovo" 2>/dev/null || true
mv -f "$DATA/liblkl.so.nuovo" "$DATA/liblkl.so"
clang -O2 -Wall -include "$QUI/compat-lkl.h" -I tools/lkl/include -o "$DATA/tod-lkl.nuovo" "$QUI/tod-lkl.c" \
  -L "$DATA" -llkl -lusb-1.0 -lpthread -Wl,-rpath,"$DATA"
mv -f "$DATA/tod-lkl.nuovo" "$DATA/tod-lkl"
clang -shared -fPIC -O2 -U_FORTIFY_SOURCE -o "$DATA/tod-disco.so.nuovo" "$QUI/tod-disco.c" -ldl
mv -f "$DATA/tod-disco.so.nuovo" "$DATA/tod-disco.so"
clang -shared -fPIC -O2 -U_FORTIFY_SOURCE -o "$DATA/tod-fs.so.nuovo" "$QUI/tod-fs.c" -ldl
mv -f "$DATA/tod-fs.so.nuovo" "$DATA/tod-fs.so"
# il disco finto anche per i programmi del container Debian (ntfs-3g): compilato da qui con le
# intestazioni di glibc scaricate (libc6-dev, linux-libc-dev: estratte, non installate)
R=""
for r in "$PREFIX/var/lib/proot-distro/containers/debian/rootfs" "$PREFIX/var/lib/proot-distro/installed-rootfs/debian"; do
  [[ -d $r/etc ]] && R=$r
done
if [[ -n $R ]]; then
  S="$DATA/glibc-sysroot"
  if [[ ! -f $S/usr/include/stdio.h ]]; then
    d=$(mktemp -d "$PREFIX/tmp/tod-glibc.XXXXXX")
    proot-distro login --shared-tmp debian -- sh -c "cd /tmp/${d##*/} && apt-get download libc6-dev linux-libc-dev" >/dev/null
    rm -rf "$S"; mkdir -p "$S"
    for f in "$d"/*.deb; do dpkg-deb -x "$f" "$S"; done
    rm -rf "$d"
  fi
  for x in tod-disco tod-fs; do
    clang --target=aarch64-unknown-linux-gnu --sysroot="$S" -fuse-ld=lld -shared -fPIC -O2 -nostdlib -U_FORTIFY_SOURCE \
      -o "$DATA/$x-glibc.so.nuovo" "$QUI/$x.c"
    mv -f "$DATA/$x-glibc.so.nuovo" "$DATA/$x-glibc.so"
  done
fi
echo "pronto: $DATA/tod-lkl"
