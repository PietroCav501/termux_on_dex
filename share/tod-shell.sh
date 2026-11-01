# shellcheck shell=bash
# tod-shell.sh - caricato dal terminale del desktop (~/.bashrc): un solo apt per tutto.
# apt install sceglie da solo: prima Termux (nativo), poi il container Debian.
if [ -x "${PREFIX:-/data/data/com.termux/files/usr}/bin/tod" ]; then
  apt() { "$PREFIX/bin/tod" apt "$@"; }
  apt-get() { "$PREFIX/bin/tod" apt "$@"; }
  # un solo utente, già amministratore: sudo apt ... funziona come altrove
  sudo() {
    case ${1:-} in
      apt | apt-get) shift; "$PREFIX/bin/tod" apt "$@" ;;
      dpkg) shift; dpkg "$@" ;;
      *) if command -v sudo >/dev/null 2>&1; then command sudo "$@"; else "$@"; fi ;;
    esac
  }
  dpkg() {
    case ${1:-} in
      -i | --install) shift; "$PREFIX/bin/tod" apt install "$@" ;;
      *) command dpkg "$@" ;;
    esac
  }
fi
