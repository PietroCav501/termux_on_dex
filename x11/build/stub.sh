# librerie "finte" senza versioni dei simboli (come quelle dell'NDK) per collegare libXlorie.so
set -e
B=$HOME/src/x11-build; mkdir -p $B/stub; cd $B/stub
for l in android mediandk log EGL GLESv2 z; do
  llvm-nm -D --defined-only /system/lib64/lib$l.so | awk '{print $3}' | sed 's/@.*//' | sort -u | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
    | awk '{print "void " $1 "(void) {}"}' > lib$l.c
  clang --target=aarch64-linux-android26 -shared -nostdlib -fPIC -fno-builtin -w -Wl,-soname,lib$l.so -o lib$l.so lib$l.c
  echo "lib$l.so: $(wc -l < lib$l.c) simboli"
done
for l in m dl; do ln -sf /system/lib64/lib$l.so lib$l.so; done
