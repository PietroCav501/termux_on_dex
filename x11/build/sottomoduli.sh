# scarica i sottomoduli di Termux:X11 ospitati su gitlab.freedesktop.org come archivi alla versione fissata
# (git fetch --depth 1 per commit si blocca su quel server)
set -e
C=$HOME/src/termux-x11/lorie/src/main/cpp; B=$HOME/src/x11-build
progetto() {
  case $1 in
    pixman) echo pixman/pixman ;; xkbcomp) echo xorg/app/xkbcomp ;; xserver) echo xorg/xserver ;;
    xorgproto) echo xorg/proto/xorgproto ;;
    *) echo "xorg/lib/$1" ;;
  esac
}
while read -r nome sha; do
  p=$(progetto $nome); base=${p##*/}
  echo "== $nome ($sha)"
  timeout 300 curl -fsSL -o $B/$nome.tar.gz "https://gitlab.freedesktop.org/$p/-/archive/$sha/$base-$sha.tar.gz"
  rm -rf "$C/$nome"; mkdir -p "$C/$nome"
  tar -xzf $B/$nome.tar.gz -C "$C/$nome" --strip-components=1
  echo "   $(ls $C/$nome | wc -l) voci"
done < "${1:-$B/sottomoduli.txt}"
