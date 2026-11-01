#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  Termux On DeX 2 — bootstrap
#
#  bash <(curl -fsSL https://raw.githubusercontent.com/PietroCav501/termux_on_dex/v2/install.sh)
#
#  Prepara Termux (git, dialog, jq), scarica il progetto in ~/.local/share/tod
#  e passa la palla a "tod install". Rilanciarlo è sicuro: aggiorna e riprende.
# =============================================================================
set -Eeuo pipefail

main() {
  local repo=${TOD_REPO_URL:-https://github.com/PietroCav501/termux_on_dex}
  local branch=${TOD_BRANCH:-v2}   # la v2 sta nel ramo v2 (main è ancora la v1)
  local dest=${TOD_HOME:-$HOME/.local/share/tod}
  local here=""

  # se lanciato con "curl ... | bash" lo stdin è la pipe: i menu vogliono il terminale
  # (solo se /dev/tty si apre davvero: nei task in background non c'è un terminale)
  if [[ ! -t 0 ]] && (exec </dev/tty) 2>/dev/null; then exec </dev/tty; fi

  if [[ ${PREFIX:-} != */com.termux/files/usr ]]; then
    echo "✘ Questo installer va eseguito dentro Termux (F-Droid o GitHub)." >&2
    exit 1
  fi

  # dall'interno di una copia locale del repository (sviluppo): usa quella
  if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
  fi

  echo "• Preparazione di Termux…"
  if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock || true; fi
  export DEBIAN_FRONTEND=noninteractive
  local -a apt_flags=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  # un'installazione interrotta (Termux chiuso o andato in crash a metà di apt) lascia dpkg a metà:
  # senza questo ogni apt-get dopo si ferma con "dpkg was interrupted"
  dpkg --configure -a --force-confdef --force-confold >/dev/null 2>&1 || true
  if ! apt-get "${apt_flags[@]}" update; then
    echo "✘ Repository non raggiungibili. Prova: termux-change-repo  (poi rilancia l'installer)" >&2
    exit 1
  fi
  # Termux regge solo aggiornamenti completi: su un Termux appena installato "install git" porta
  # librerie nuove e i programmi vecchi si fermano con "CANNOT LINK EXECUTABLE" (31 ottobre)
  apt-get "${apt_flags[@]}" full-upgrade
  apt-get "${apt_flags[@]}" install git dialog jq curl ca-certificates

  if [[ -n $here && -f $here/tod && -d $here/lib ]]; then
    dest=$here
    echo "• Uso la copia locale: $dest"
  elif [[ -d $dest/.git ]]; then
    echo "• Aggiorno $dest"
    git -C "$dest" fetch --depth 1 origin "$branch"
    git -C "$dest" reset --hard FETCH_HEAD
  else
    echo "• Scarico Termux On DeX in $dest"
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    git clone --depth 1 -b "$branch" "$repo" "$dest"
  fi

  chmod 755 "$dest/tod"
  ln -sfn "$dest/tod" "$PREFIX/bin/tod"
  echo "✔ Comando installato: tod"
  exec "$PREFIX/bin/tod" install "$@"
}

main "$@"; exit $?
