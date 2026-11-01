# apk-glamor.sh: APK da installare = nightly 20261027 con la correzione del mouse (classes-nuovo.dex) + il nostro
# server (libXlorie.so con glamor, spento se manca TERMUX_X11_GLAMOR=1), firmata con la stessa chiave di prova.
set -e
B=$HOME/src/x11-build; W=$HOME/src/x11-patch; N=$W/nightly-20261027
lib=$B/build/libXlorie-strip.so
python3 - "$N/originale.apk" "$N/classes-nuovo.dex" "$lib" "$B/glamor-senza-firma.apk" <<'PY'
import sys, zipfile
src, dex, lib, out = sys.argv[1:]
z = zipfile.ZipFile(src); o = zipfile.ZipFile(out, "w")
for i in z.infolist():
    if i.filename.startswith("META-INF/") and i.filename.split(".")[-1] in ("SF", "RSA", "EC", "DSA", "MF"):
        continue
    if i.filename == "classes.dex":
        data = open(dex, "rb").read()
    elif i.filename == "lib/arm64-v8a/libXlorie.so":
        data = open(lib, "rb").read()
    else:
        data = z.read(i)
    zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
    zi.compress_type = i.compress_type; zi.external_attr = i.external_attr
    o.writestr(zi, data)
o.close()
PY
rm -f $B/glamor-allineata.apk
zipalign -f -p 4 $B/glamor-senza-firma.apk $B/glamor-allineata.apk
AS="java -jar $W/strumenti/apksigner/data/data/com.termux/files/usr/share/java/apksigner.jar"
$AS sign --ks $W/strumenti/testkey_untrusted.jks --ks-key-alias alias --ks-pass pass:xrj45yWGLbsO7W0v --key-pass pass:xrj45yWGLbsO7W0v --out $B/termux-x11-glamor-prova.apk $B/glamor-allineata.apk
$AS verify --print-certs $B/termux-x11-glamor-prova.apk 2>&1 | grep "SHA-256" | head -1
$AS verify --print-certs $N/termux-x11-nightly-mouse-immediato.apk 2>&1 | grep "SHA-256" | head -1
cp $B/termux-x11-glamor-prova.apk /storage/emulated/0/Download/
ls -la /storage/emulated/0/Download/termux-x11-glamor-prova.apk
