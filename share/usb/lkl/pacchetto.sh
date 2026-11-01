#!/data/data/com.termux/files/usr/bin/bash
# pacchetto.sh [VERSIONE]: l'archivio dei file compilati da costruisci.sh, da caricare nella release
# lkl-VERSIONE del progetto (tod-lkl-aarch64.tar.xz), e lib/usb.sh aggiornato con versione e impronta.
# Il caricamento lo fa una persona (gh release create ...): qui solo l'archivio.
#
# LKL è il kernel Linux (GPL v2): con i file compilati vanno indicati i sorgenti esatti, cioè il commit
# di lkl/linux e le patch di questa cartella (SORGENTI.txt nell'archivio).
set -euo pipefail
QUI=$(cd "$(dirname "$0")" && pwd)
RADICE=$(cd "$QUI/../../.." && pwd)
DATA="${TOD_TERMUX_HOME:-$HOME}/.local/share/tod-usb"
USB="$RADICE/lib/usb.sh"
V=${1:-$(sed -n 's/^LKL_VERSIONE=//p' "$USB")}
FILE=$(sed -n 's/^LKL_FILE="\(.*\)"$/\1/p' "$USB")
COMMIT=$(sed -n 's/^VERSIONE=\([0-9a-f]*\).*/\1/p' "$QUI/costruisci.sh")
OUT="$RADICE/dist/tod-lkl-aarch64.tar.xz"

for f in $FILE; do [[ -s $DATA/$f ]] || { echo "manca $DATA/$f: prima costruisci.sh" >&2; exit 1; }; done
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
for f in $FILE; do cp "$DATA/$f" "$t/"; done
cat >"$t/SORGENTI.txt" <<EOF
Termux On DeX: dischi USB senza root (tod-lkl), versione $V.

liblkl.so è LKL (Linux Kernel Library), cioè il kernel Linux: licenza GPL v2.
Sorgenti esatti: https://github.com/lkl/linux, commit $COMMIT,
con le patch e la configurazione di share/usb/lkl/ del progetto
(android.patch, disco-thread.patch, compat-*.h, costruisci.sh):
https://github.com/PietroCav501/termux_on_dex

tod-lkl, tod-disco.so e tod-fs.so (e le versioni -glibc) sono del progetto, stessa cartella.
EOF
mkdir -p "${OUT%/*}"
tar -cJf "$OUT" -C "$t" $FILE SORGENTI.txt
sha=$(sha256sum "$OUT" | cut -d' ' -f1)
sed -i "s/^LKL_VERSIONE=.*/LKL_VERSIONE=$V/; s/^LKL_SHA256=.*/LKL_SHA256=$sha/" "$USB"
echo "archivio: $OUT ($(du -h "$OUT" | cut -f1)), sha256 $sha"
echo "da caricare nella release lkl-$V (asset tod-lkl-aarch64.tar.xz); lib/usb.sh aggiornato"
