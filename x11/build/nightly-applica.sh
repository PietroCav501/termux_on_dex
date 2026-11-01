set -e
W=$HOME/src/x11-patch; N=$W/nightly-20261027; cd $N
java -jar $W/strumenti/smali.jar a smali-out/classes -o classes-nuovo.dex --api 26
python3 - <<'PY'
import zipfile
src = zipfile.ZipFile("originale.apk")
out = zipfile.ZipFile("senza-firma.apk", "w")
for i in src.infolist():
    if i.filename.startswith("META-INF/") and i.filename.split(".")[-1] in ("SF", "RSA", "EC", "DSA", "MF"):
        continue
    data = open("classes-nuovo.dex", "rb").read() if i.filename == "classes.dex" else src.read(i)
    zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
    zi.compress_type = i.compress_type; zi.external_attr = i.external_attr
    out.writestr(zi, data)
out.close()
PY
zipalign -f -p 4 senza-firma.apk allineata.apk
AS="java -jar $W/strumenti/apksigner/data/data/com.termux/files/usr/share/java/apksigner.jar"
$AS sign --ks $W/strumenti/testkey_untrusted.jks --ks-key-alias alias --ks-pass pass:xrj45yWGLbsO7W0v --key-pass pass:xrj45yWGLbsO7W0v --out termux-x11-nightly-mouse-immediato.apk allineata.apk
$AS verify --print-certs termux-x11-nightly-mouse-immediato.apk 2>&1 | grep "SHA-256" | head -1
cp termux-x11-nightly-mouse-immediato.apk /storage/emulated/0/Download/
ls -la /storage/emulated/0/Download/termux-x11-*.apk
