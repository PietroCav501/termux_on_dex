# compila il server di Termux:X11 (libXlorie.so) sul telefono, con il clang di Termux, per Android API 26
set -e
B=$HOME/src/x11-build; C=$HOME/src/termux-x11/lorie/src/main/cpp
. $B/strumenti/env.sh
command -v patch >/dev/null || { echo "manca patch"; exit 1; }
# librerie di sistema Android da collegare (le stesse dell'ufficiale), prima di quelle di Termux
bash $B/stub.sh; rm -rf $B/syslib; ln -sfn $B/stub $B/syslib
# (le vecchie copie delle librerie vere sono sostituite dalle finte)
T="--target=aarch64-linux-android26 -DANDROID -U__TERMUX__ -fPIC -ffunction-sections -fdata-sections"
clang $T -O2 -fPIC -c $B/cxx-minimo.c -o $B/cxx-minimo.o
cmake -S $C -B $B/build -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_ASM_COMPILER=clang \
  -DCMAKE_C_FLAGS="$T -include unistd.h -DSHMLBA=4096" -DCMAKE_ASM_FLAGS="$T" \
  -DCMAKE_CXX_FLAGS="$T -DEGL_NO_PLATFORM_SPECIFIC_TYPES -include stdlib.h -include unistd.h -fno-exceptions -fno-rtti -fno-threadsafe-statics" \
  -DCMAKE_SHARED_LINKER_FLAGS="-L$B/syslib -nostdlib++ -Wl,--gc-sections -Wl,--build-id=sha1 $B/cxx-minimo.o" \
  -DTOD_EPOXY_DIR=$B/epoxy -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a > $B/configura.log 2>&1 || { grep -n -B2 -A8 "CMake Error" $B/configura.log | head -60; exit 1; }
rm -f $B/build/libXlorie.so
ninja -k 0 -C $B/build Xlorie > $B/ninja.log 2>&1 || { grep -n -A12 "FAILED" $B/ninja.log | grep -v "clang " | head -${RIGHE:-60}; exit 1; }
tail -3 $B/ninja.log
