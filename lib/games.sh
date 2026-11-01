# shellcheck shell=bash
# =============================================================================
#  Giochi: ponte verso GameNative
#
#  GameNative è (oggi) il modo più veloce di far girare giochi Windows su
#  Android: è un'app Android che possiede server X, superficie e processi, con
#  Proton ARM64EC + FEX/Box64 + DXVK/VKD3D + Turnip. Invece di rifarlo dentro il
#  desktop Linux (fragile e più lento), lo integriamo: i giochi compaiono nel
#  menu del desktop e partono in GameNative, che in DeX apre la sua finestra.
#
#  Intent documentato (usato anche da ES-DE e altri frontend):
#    am start -n app.gamenative/app.gamenative.MainActivity \
#      -a app.gamenative.LAUNCH_GAME --ei app_id <id Steam>
# =============================================================================

GN_PKG=app.gamenative
GN_ACTIVITY=app.gamenative/app.gamenative.MainActivity

gn_installed() {
  local p=""
  p=$("${TOD_PM:-/system/bin/pm}" path "$GN_PKG" 2>/dev/null) || p=""
  [[ $p == package:* ]]
}

game_entry() { printf '%s/.local/share/applications/tod-game-%s.desktop' "$HOME" "$1"; }

game_add() { # game_add <id Steam> "Nome del gioco"
  local id=${1:-} name=${2:-}
  [[ $id =~ ^[0-9]+$ ]] || die "$(t game_bad_id "$id")"
  if [[ -z $name ]]; then name="Steam $id"; fi
  mkdir -p "$HOME/.local/share/applications"
  cat >"$(game_entry "$id")" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=GameNative
Exec=$PREFIX/bin/tod game run $id
Icon=applications-games
Terminal=false
Categories=Game;
X-TOD-GameNative=$id
EOF
  desktop_refresh_caches
  ok "$(t game_added "$name")"
}

game_remove() {
  local id=${1:-} f
  [[ $id =~ ^[0-9]+$ ]] || die "$(t game_bad_id "$id")"
  f=$(game_entry "$id")
  if [[ -f $f ]]; then rm -f "$f"; desktop_refresh_caches; ok "$(t game_removed "$id")"; else warn "$(t game_none)"; fi
}

game_list() {
  local f id name n=0
  for f in "$HOME"/.local/share/applications/tod-game-*.desktop; do
    [[ -f $f ]] || continue
    id=$(sed -n 's/^X-TOD-GameNative=//p' "$f")
    name=$(sed -n 's/^Name=//p' "$f" | sed -n 1p)
    printf '  %-10s %s\n' "$id" "$name"
    n=$((n + 1))
  done
  if (( n == 0 )); then info "$(t game_none)"; fi
}

game_run() { # avvia il gioco in GameNative
  local id=${1:-}
  [[ $id =~ ^[0-9]+$ ]] || die "$(t game_bad_id "$id")"
  gn_installed || die "$(t gn_missing)"
  log "game: avvio $id in GameNative"
  am start -n "$GN_ACTIVITY" -a app.gamenative.LAUNCH_GAME --ei app_id "$id" >/dev/null 2>&1 ||
    die "$(t game_launch_fail)"
}

game_open() { # apre GameNative (libreria, download, impostazioni)
  gn_installed || die "$(t gn_missing)"
  am start -n "$GN_ACTIVITY" >/dev/null 2>&1 || die "$(t game_launch_fail)"
}

games_entries() { # voce "GameNative" nel menu, se l'app è installata
  local f="$HOME/.local/share/applications/tod-gamenative.desktop"
  if ! gn_installed; then rm -f "$f"; return 0; fi
  mkdir -p "$HOME/.local/share/applications"
  cat >"$f" <<EOF
[Desktop Entry]
Type=Application
Name=GameNative
Comment=Steam, GOG, Epic
Exec=$PREFIX/bin/tod game open
Icon=applications-games
Terminal=false
Categories=Game;
EOF
}

games_cli() { # tod game add|run|list|remove|open
  local sub=${1:-list}
  if (($#)); then shift; fi
  case $sub in
    add) game_add "$@" ;;
    run | start) game_run "$@" ;;
    list | ls) game_list ;;
    remove | rm) game_remove "$@" ;;
    open | "") game_open ;;
    *) die "tod game add <id Steam> \"Nome\" | run <id> | list | remove <id> | open" ;;
  esac
}
