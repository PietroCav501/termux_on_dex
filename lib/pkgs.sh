# shellcheck shell=bash
# =============================================================================
#  Pacchetti Termux: wrapper apt non interattivi, ritentativi, pin dei driver
# =============================================================================

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

apt_run() { # apt-get con avanzamento reale per l'interfaccia grafica (APT::Status-Fd)
  if [[ -n ${TOD_PROGRESS_FILE:-} ]]; then
    apt-get -o APT::Status-Fd=3 "$@" 3>>"$TOD_PROGRESS_FILE"
  else
    apt-get "$@"
  fi
}

pkg_has() { apt-cache show "$1" >/dev/null 2>&1; }
pkg_installed() { [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]; }
pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
pkg_repo_version() { apt-cache madison "$1" 2>/dev/null | awk 'NR==1{print $3}'; }

pkg_refresh() { # elenchi dei pacchetti; se un server non risponde, pkg di Termux sceglie un mirror che risponde
  # (e riscrive anche x11.list e root.list): apt-get update resta sul server di prima anche se è irraggiungibile
  if apt_run "${APT_FLAGS[@]}" --error-on=any update; then return 0; fi
  if have pkg; then
    log "pacchetti: un server non risponde, pkg update sceglie un altro mirror"
    pkg update >>"$TOD_LOG" 2>&1 || true
  fi
  # alla fine come prima: un repository di terzi giù (tur) non deve fermare tutto
  retry 3 5 apt_run "${APT_FLAGS[@]}" update
}

pkg_upgrade() {
  pkg_refresh || return 1
  retry 2 5 apt_run "${APT_FLAGS[@]}" full-upgrade
}

pkg_fix() {
  apt_run "${APT_FLAGS[@]}" -f install || true
  dpkg --configure -a || true
}

pkg_install() { # pkg_install pacchetto...
  (($#)) || return 0
  log "pkg_install: $*"
  if retry 2 5 apt_run "${APT_FLAGS[@]}" install "$@"; then return 0; fi
  pkg_fix
  apt_run "${APT_FLAGS[@]}" install "$@"
}

pkg_install_avail() { # installa solo ciò che esiste nei repository abilitati
  local p
  local -a found=()
  for p in "$@"; do
    if pkg_has "$p"; then found+=("$p"); else log "non disponibile, salto: $p"; fi
  done
  ((${#found[@]})) || return 0
  if pkg_install "${found[@]}"; then return 0; fi
  # un pacchetto rotto non deve bloccare tutti gli altri
  local rc=0
  for p in "${found[@]}"; do pkg_install "$p" || { log "installazione fallita: $p"; rc=1; }; done
  return "$rc"
}

pkg_hold() { apt-mark hold "$@" >/dev/null 2>&1 || true; }
pkg_unhold() { apt-mark unhold "$@" >/dev/null 2>&1 || true; }
pkg_held_list() { apt-mark showhold 2>/dev/null || true; }

pkg_enable_repos() { # x11-repo (Termux:X11, desktop, mesa) + tur-repo (chromium, code-oss…)
  local r changed=0
  for r in x11-repo tur-repo; do
    if ! pkg_installed "$r"; then
      pkg_install "$r" || return 1
      changed=1
    fi
  done
  if (( changed )); then pkg_refresh; fi
}
