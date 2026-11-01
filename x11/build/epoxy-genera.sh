# genera i sorgenti di libepoxy (gl ed egl) con lo script originale (la modifica di termux-x11 annullata su una copia)
set -e
C=$HOME/src/termux-x11/lorie/src/main/cpp; E=$HOME/src/x11-build/epoxy
cp $C/libepoxy/src/gen_dispatch.py $E/gen/src/
cd $E/gen && patch -p1 -R -i $C/patches/libepoxy.patch
cd $E
for x in gl egl; do python3 gen/src/gen_dispatch.py --source --header --srcdir=$E --includedir=$E/inc/epoxy $C/libepoxy/registry/$x.xml; done
ls -la $E $E/inc/epoxy
