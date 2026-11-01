# prova-apk.sh libXlorie.so uscita.apk: APK di prova (codice della nightly con il messaggio all'app disattivato)
# con la libreria del server indicata. Non va installato: si carica da file con app_process
set -e
B=$HOME/src/x11-build; P=$B/prova; W=$HOME/src/x11-patch
lib=$(realpath "$1"); out=$(realpath -m "$2")
[ -f $P/classes.dex ] && [ $P/classes.dex -nt $P/smali/com/termux/x11/CmdEntryPoint.smali ] || \
  java -jar $W/strumenti/smali.jar a $P/smali -o $P/classes.dex --api 26
python3 - "$W/nightly-20261027/originale.apk" "$P/classes.dex" "$lib" "$out.tmp" <<'PY'
import sys, zipfile
src, dex, lib, out = sys.argv[1:]
z = zipfile.ZipFile(src); o = zipfile.ZipFile(out, "w")
for i in z.infolist():
    if i.filename.startswith("META-INF/"):
        continue
    if i.filename == "classes.dex":
        data = open(dex, "rb").read()
    elif i.filename == "lib/arm64-v8a/libXlorie.so":
        data = open(lib, "rb").read()
    else:
        data = z.read(i)
    zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
    zi.compress_type = zipfile.ZIP_STORED if i.filename.endswith(".so") else i.compress_type
    zi.external_attr = i.external_attr
    o.writestr(zi, data)
o.close()
PY
rm -f "$out"; zipalign -f -p 4 "$out.tmp" "$out" && rm -f "$out.tmp"
echo "pronto: $out ($(stat -c %s "$out") byte)"
