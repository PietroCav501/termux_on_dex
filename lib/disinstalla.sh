# shellcheck shell=bash
# =============================================================================
#  Disinstallazione delle app, "pulita e profonda" (Pietro, 26 ottobre: come l'installer, ma al contrario).
#  share/tod-disinstalla.py è la finestra; qui il lavoro:
#    tod _app_piano dove pacchetto     → cosa si toglierebbe, senza toccare niente
#    tod _app_rimuovi dove pacchetto [dati]   → lo fa (dati=1: anche impostazioni e dati, nel Cestino)
#  dove = termux | debian | home (AppImage & co. nella cartella personale del container, pacchetto = voce).
#  Componenti: solo quelli che restano orfani PER COLPA di quest'app (simulazione di apt prima e dopo):
#  ciò che era già orfano prima non si tocca. I documenti non si toccano mai: solo le cartelle di
#  impostazioni, dati e cache che portano il nome dell'app.
# =============================================================================

# cartelle che non sono di un'app sola, anche se il nome coincide (es. un'app che si chiama "tod")
APP_DATI_MAI="tod xfce4 gtk-2.0 gtk-3.0 gtk-4.0 dconf pulse fontconfig autostart menus applications icons themes
  mime Trash recently-used.xbel systemd user-dirs.dirs mimeapps.list keyrings gvfs-metadata thumbnails fonts
  ibus dbus-1 nautilus Thunar xfce4-session sessions"
# pezzi del desktop: mai, nemmeno come componenti orfani (come PROTECTED in tod-settings.py)
APP_PROTETTE='^(thunar|xfce4-.*|xfwm4|xfdesktop|xfce4|termux-.*|python.*|tod-.*|libxfce.*|exo)$'

app_rx() { # app_rx pacchetto → vero se è un pezzo del desktop
  [[ $1 =~ $APP_PROTETTE ]]
}

app_case() { # app_case dove → le cartelle personali dove l'app tiene impostazioni e dati, una per riga
  # Termux: la home di Termux e quella dell'utente della sessione (files/<utente>), dove le app possono
  # creare cartelle nascoste vere accanto ai collegamenti verso Termux
  local u
  if [[ $1 == termux ]]; then
    files_termux_home
    echo
    u=$(files_user_home) || u=""
    if [[ -n $u && -d $u ]]; then printf '%s\n' "$u"; fi
  else
    printf '%s/home/%s\n' "$(cx_rootfs)" "$(cx_user)"
  fi
}

app_lista() { # app_lista dove pacchetto → il file .list di dpkg
  if [[ $1 == termux ]]; then
    if [[ -f $PREFIX/var/lib/dpkg/info/$2.list ]]; then printf '%s' "$PREFIX/var/lib/dpkg/info/$2.list"; return 0; fi
    return 1
  fi
  cx_dpkg_list_file "$(cx_rootfs)" "$2"
}

app_voci() { # app_voci dove pacchetto → i .desktop dell'app (percorsi veri)
  local l root=""
  if [[ $1 == home ]]; then
    printf '%s/%s.desktop\n' "$(cx_home_apps_dir)" "$2"
    return 0
  fi
  l=$(app_lista "$1" "$2") || return 0
  if [[ $1 == debian ]]; then root=$(cx_rootfs); fi
  grep -E '/share/applications/[^/]+\.desktop$' "$l" | sed "s|^|$root|" || true
}

app_nomi() { # app_nomi dove pacchetto → i nomi con cui l'app può chiamare le sue cartelle, uno per riga
  local v x
  {
    printf '%s\n' "$2"
    while IFS= read -r v; do
      [[ -f $v ]] || continue
      x=${v##*/}
      printf '%s\n' "${x%.desktop}"
      sed -n 's/^StartupWMClass=//p; s/^Exec=\([^ ]*\).*/\1/p; s/^Icon=\([^/ ]*\)$/\1/p' "$v" | sed 's|.*/||'
    done < <(app_voci "$1" "$2")
  } | awk 'length($0) >= 3 && !seen[tolower($0)]++'
}

app_dati() { # app_dati dove pacchetto → cartelle di impostazioni, dati e cache dell'app (percorsi veri)
  local casa nomi d f n base
  nomi=$(app_nomi "$1" "$2" | tr '[:upper:]' '[:lower:]')
  [[ -n $nomi ]] || return 0
  while IFS= read -r casa; do
    [[ -n $casa ]] || continue
    for d in "$casa/.config" "$casa/.local/share" "$casa/.local/state" "$casa/.cache" "$casa"; do
      [[ -d $d && ! -L $d ]] || continue
      for f in "$d"/* "$d"/.[!.]*; do
        [[ -e $f && ! -L $f ]] || continue
        base=${f##*/}
        # nella cartella personale: solo le cartelle nascoste (.gimp, .inkscape), mai Documenti & co.
        if [[ $d == "$casa" && $base != .* ]]; then continue; fi
        n=${base#.}
        n=${n,,}
        if [[ " ${APP_DATI_MAI,,} " == *" $n "* ]]; then continue; fi
        if grep -qxF "$n" <<<"$nomi"; then printf '%s\n' "$f"; fi
      done
    done
  done < <(app_case "$1")
}

app_orfani() { # app_orfani dove pacchetto → i componenti che resterebbero orfani solo per colpa sua
  local prima dopo p
  if [[ $1 == termux ]]; then
    prima=$(apt-get -s autoremove 2>/dev/null | sed -n 's/^Remv \([^ ]*\).*/\1/p') || prima=""
    dopo=$(apt-get -s purge --autoremove "$2" 2>/dev/null | sed -n 's/^Purg \([^ ]*\).*/\1/p') || dopo=""
  else
    prima=$(cx_root_q apt-get -s autoremove | sed -n 's/^Remv \([^ ]*\).*/\1/p') || prima=""
    dopo=$(cx_root_q apt-get -s purge --autoremove "$2" | sed -n 's/^Purg \([^ ]*\).*/\1/p') || dopo=""
  fi
  for p in $dopo; do
    p=${p%:*}
    if [[ $p == "$2" ]] || grep -qxF "$p" <<<"$prima" || app_rx "$p"; then continue; fi
    printf '%s\n' "$p"
  done
}

cx_root_q() { # cx_root_q comando... → un comando da root nel container, solo il suo output
  proot-distro login --shared-tmp "$(cx_distro)" -- env LANG=C "$@" 2>/dev/null
}

app_kb() { # app_kb dove pacchetto → Installed-Size (kB) dal database di dpkg
  local st
  if [[ $1 == termux ]]; then st=$PREFIX/var/lib/dpkg/status; else st=$(cx_rootfs)/var/lib/dpkg/status; fi
  awk -v p="$2" '/^Package: /{q = ($2 == p)} q && /^Installed-Size: /{print $2; exit}' "$st" 2>/dev/null || true
}

app_piano() { # tod _app_piano dove pacchetto → righe chiave<TAB>valore per la finestra
  local dove=$1 pkg=$2 p f kb exe
  case $dove in termux | debian | home) ;; *) die "tod _app_piano termux|debian|home pacchetto" ;; esac
  if [[ $dove != home ]] && app_rx "$pkg"; then printf 'protetta\t1\n'; return 0; fi
  if [[ $dove == home ]]; then
    exe=$(sed -n 's/^#exe //p' "$TOD_STATE_DIR/cx-exports/home-$pkg.files" 2>/dev/null | sed -n 1p) || exe=""
    kb=0
    if [[ -n $exe && -f $(cx_rootfs)$exe ]]; then kb=$(du -sk "$(cx_rootfs)$exe" | cut -f1); fi
    printf 'programma\t%s\t%s\n' "$pkg" "$kb"
  else
    printf 'programma\t%s\t%s\n' "$pkg" "$(app_kb "$dove" "$pkg")"
    for p in $(app_orfani "$dove" "$pkg"); do printf 'componente\t%s\t%s\n' "$p" "$(app_kb "$dove" "$p")"; done
  fi
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    printf 'dati\t%s\t%s\n' "$f" "$(du -sk "$f" 2>/dev/null | cut -f1)"
  done < <(app_dati "$dove" "$pkg")
  while IFS= read -r f; do
    if [[ -n $f ]]; then printf 'voce\t%s\n' "${f##*/}"; fi
  done < <(app_voci "$dove" "$pkg")
}

app_rimuovi() { # tod _app_rimuovi dove pacchetto [dati] → FASE <nome> per la finestra, poi il lavoro
  local dove=$1 pkg=$2 dati=${3:-0} f voci comp
  case $dove in termux | debian | home) ;; *) die "tod _app_rimuovi termux|debian|home pacchetto [1]" ;; esac
  if [[ $dove != home ]] && app_rx "$pkg"; then die "$pkg: $(t un_protected)"; fi
  # prima di togliere il programma: dopo non si saprebbe più come si chiamano voci e cartelle
  voci=$(app_voci "$dove" "$pkg" | sed 's|.*/||')
  local -a cartelle=()
  if [[ $dati == 1 ]]; then mapfile -t cartelle < <(app_dati "$dove" "$pkg"); fi
  echo "FASE programma"
  case $dove in
    home) cx_remove_home_app "$pkg" ;;
    termux)
      comp=$(app_orfani termux "$pkg")
      # shellcheck disable=SC2086
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" $comp
      ;;
    debian)
      comp=$(app_orfani debian "$pkg")
      echo "FASE componenti"
      # shellcheck disable=SC2086
      cx_root "$pkg" $comp <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive TOD_MENU_SYNC=0
apt-get purge -y -q "$@"
EOF
      cx_prune_exports
      ;;
  esac
  log "disinstallata: $pkg ($dove) ${comp:+con: $(tr '\n' ' ' <<<"$comp")}"
  if ((${#cartelle[@]})); then
    echo "FASE dati"
    for f in "${cartelle[@]}"; do
      # nel Cestino, non cancellate: un errore si recupera
      if [[ -e $f ]] && gio trash -- "$f" 2>/dev/null; then log "nel Cestino: $f"; else warn "$(t un_trash_fail "$f")"; fi
    done
  fi
  echo "FASE pulizia"
  app_pulisci_riferimenti "$voci"
  desktop_refresh_caches
}

app_pulisci_riferimenti() { # app_pulisci_riferimenti "voci" → via da Start, barra, associazioni dei file
  local voci=$1 v f conf=${TOD_TERMUX_HOME:-$HOME}/.config
  [[ -n $voci ]] || return 0
  for v in $voci; do
    f=$conf/tod/start-aggiunte
    if [[ -f $f ]]; then sed -i "/^\(tod-cx-\)\?${v//./\\.}$/d" "$f"; fi
    for f in "$conf/mimeapps.list" "$HOME/.config/mimeapps.list" "${TOD_TERMUX_HOME:-$HOME}/.local/share/applications/mimeapps.list"; do
      [[ -f $f ]] || continue
      sed -i -e "s/\(=\|;\)\(tod-cx-\)\?${v//./\\.};\?/\1/g" -e '/^[^=]*=$/d' "$f"
    done
  done
  f=$conf/tod/barra.json
  if [[ -f $f ]] && have python3; then
    python3 - "$f" $voci <<'PY' || true
import json, sys
f, voci = sys.argv[1], set(sys.argv[2:])
c = json.load(open(f))
prima = list(c.get("fissate", []))
c["fissate"] = [x for x in prima if x not in voci and x.removeprefix("tod-cx-") not in voci]
if c["fissate"] != prima:
    json.dump(c, open(f, "w"), indent=2)
PY
    # la barra rilegge le impostazioni (SIGUSR1)
    if [[ -f $TMPDIR/tod-barra.pid ]]; then kill -USR1 "$(cat "$TMPDIR/tod-barra.pid")" 2>/dev/null || true; fi
  fi
}

app_gui() { # tod disinstalla dove pacchetto [nome]: la finestra
  python3 "$TOD_ROOT/share/tod-disinstalla.py" "$@"
}
