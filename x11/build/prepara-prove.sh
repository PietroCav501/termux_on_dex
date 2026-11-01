# due APK di prova: con la libreria ufficiale e con la nostra (senza debug)
set -e
B=$HOME/src/x11-build; cd $B
llvm-strip --strip-debug -o build/libXlorie-strip.so build/libXlorie.so
python3 togli-runpath.py build/libXlorie-strip.so
bash prova-apk.sh uff/lib/arm64-v8a/libXlorie.so prova/uff.apk
bash prova-apk.sh build/libXlorie-strip.so prova/nostra.apk
ls -la prova/*.apk build/libXlorie-strip.so
