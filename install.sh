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

repo_errore() { # nessun server dei pacchetti di Termux raggiungibile: perché, e cosa fare
  local ip=""
  ip=$(curl -s -o /dev/null -w '%{remote_ip}' --connect-timeout 8 https://packages-cf.termux.dev/ 2>/dev/null) || ip=""
  echo "✘ I server dei pacchetti di Termux non rispondono, neanche gli altri mirror." >&2
  echo "  Termux package servers are unreachable, other mirrors included." >&2
  if [[ $ip == 127.* || $ip == 0.0.0.0 || $ip == ::1 ]]; then
    echo "  Il telefono li manda a $ip: li blocca il DNS privato (Impostazioni → Connessioni → Altre impostazioni" >&2
    echo "  di connessione → DNS privato: Automatico) o un'app che blocca pubblicità o fa da VPN. Sbloccali e rilancia." >&2
    echo "  The phone sends them to $ip: Private DNS or an ad-blocking/VPN app is blocking them. Unblock and rerun." >&2
  else
    echo "  Controlla la connessione e rilancia il comando (oppure scegli un mirror con termux-change-repo)." >&2
    echo "  Check the connection and run the command again (or pick a mirror with termux-change-repo)." >&2
  fi
}

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
  # Gli elenchi dei pacchetti con pkg di Termux: prova i mirror e ne sceglie uno che risponde. apt-get update
  # restava sul server predefinito anche irraggiungibile, finiva "senza errori" e poi "Unable to locate package
  # git" (1° novembre, S20+: packages-cf.termux.dev mandato a 127.0.0.1 dal DNS del telefono)
  if command -v pkg >/dev/null 2>&1; then pkg update || true; else apt-get "${apt_flags[@]}" update || true; fi
  if ! apt-cache show git >/dev/null 2>&1; then
    repo_errore
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
