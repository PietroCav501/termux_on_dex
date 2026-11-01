set -e
W=$HOME/src/x11-patch; N=$W/nightly-20261027; mkdir -p $N; cd $N
[ -f originale.apk ] || curl -fsSL -o originale.apk https://github.com/termux/termux-x11/releases/download/nightly/termux-x11-universal-sharedUid-debug.apk
ls -la originale.apk
AS="java -jar $W/strumenti/apksigner/data/data/com.termux/files/usr/share/java/apksigner.jar"
$AS verify --print-certs originale.apk 2>&1 | grep "SHA-256" | head -1
rm -rf dex smali-out; mkdir dex
unzip -q -o originale.apk 'classes*.dex' -d dex && ls dex
for d in dex/classes*.dex; do java -jar $W/strumenti/baksmali.jar d $d -o smali-out/$(basename $d .dex); done
f=$(grep -rl "^.class.*Lcom/termux/x11/MainActivity;" smali-out | head -1); echo "file: $f"
grep -n "requestUnbufferedDispatch\|setOnGenericMotionListener\|setOnCapturedPointerListener\|\"lorieParent\"" "$f" | head -12
