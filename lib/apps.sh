# shellcheck shell=bash
# =============================================================================
#  App: prima Termux nativo (più veloce), poi il container
# =============================================================================

# id catalogo → pacchetto Termux nativo | pacchetti del container
declare -gA APP_NATIVE=(
  [firefox]=firefox [chromium]=chromium [code-oss]=code-oss [gimp]=gimp
  [inkscape]=inkscape [vlc]=vlc-qt [thunderbird]=thunderbird [libreoffice]=libreoffice
  [blender]=blender [obs]=obs-studio
)
declare -gA APP_CX=(
  [firefox]=firefox-esr [chromium]=chromium [code-oss]="" [gimp]=gimp
  [inkscape]=inkscape [vlc]=vlc [thunderbird]=thunderbird [libreoffice]="libreoffice libreoffice-gtk3"
  [blender]=blender [obs]=obs-studio
)

apps_catalog_args() { # argomenti per ui_checklist
  printf '%s\n' \
    firefox Firefox on chromium Chromium off code-oss "VS Code (Code-OSS)" off \
    libreoffice LibreOffice on gimp GIMP off inkscape Inkscape off vlc VLC off \
    thunderbird Thunderbird off blender Blender off obs "OBS Studio" off
}

apps_install_selected() {
  local id n c
  local -a ids=() native=() cx=() miss=() _cxp=()
  read -ra ids <<<"$(conf_get APPS)"
  ((${#ids[@]})) || return 0
  for id in "${ids[@]}"; do
    n=${APP_NATIVE[$id]:-$id}
    c=${APP_CX[$id]-$id}
    if pkg_has "$n"; then
      native+=("$n")
    elif [[ -n $c ]] && cx_installed; then
      read -ra _cxp <<<"$c"
      cx+=("${_cxp[@]}")
    else
      miss+=("$id")
    fi
  done
  if ((${#native[@]})); then pkg_install "${native[@]}" || return 1; fi
  if ((${#cx[@]})); then cx_pkg_install "${cx[@]}" || return 1; fi
  if ((${#miss[@]})); then warn "$(t apps_missing "${miss[*]}")"; fi
  return 0
}

apps_add() { # tod add pacchetto...  → nativo se esiste, altrimenti nel container
  (($#)) || die "tod add <pacchetto>..."
  local p
  local -a native=() cx=() miss=()
  for p in "$@"; do
    if [[ $p == *.deb ]]; then deb_add "$p" || return 1; continue; fi
    if pkg_has "$p"; then native+=("$p")
    elif cx_installed; then cx+=("$p")
    else miss+=("$p"); fi
  done
  if ((${#native[@]})); then
    run_step "$(t apps_native "${native[*]}")" pkg_install "${native[@]}" || return 1
  fi
  if ((${#cx[@]})); then
    detect_gpu
    run_step "$(t apps_cx "${cx[*]}" "$(cx_distro)")" cx_pkg_install "${cx[@]}" || return 1
  fi
  if ((${#miss[@]})); then warn "$(t apps_missing "${miss[*]}")"; fi
  return 0
}

# ----------------------------------------------------------------------------
#  Pacchetti .deb: da terminale (tod add file.deb) o con doppio clic (tod installa)
#  I .deb di Termux dichiarano "aarch64", quelli Debian/Ubuntu "arm64": così si sa
#  dove vanno, senza chiedere.
# ----------------------------------------------------------------------------
deb_resolve() { # deb_resolve nome|percorso → percorso assoluto (cerca anche nei Download)
  local f=$1 d found
  if [[ -f $f ]]; then readlink -f "$f"; return 0; fi
  for d in "$HOME/Downloads" "$HOME/storage/downloads" /storage/emulated/0/Download; do
    [[ -d $d ]] || continue
    found=$(find "$d/" -maxdepth 3 -type f -name "${f##*/}" 2>/dev/null | sed -n 1p) || found=""
    if [[ -n $found ]]; then readlink -f "$found"; return 0; fi
  done
  return 1
}

deb_field() { dpkg-deb -f "$1" "$2" 2>/dev/null || true; }

deb_target() { # → termux | container | non-arm (stampato), dal campo Architecture
  local arch files
  arch=$(deb_field "$1" Architecture)
  case $arch in
    aarch64) echo termux ;;
    arm64) echo container ;;
    all)
      files=$(dpkg-deb -c "$1" 2>/dev/null) || files=""
      if grep -q '\./data/data/com\.termux/' <<<"$files"; then echo termux; else echo container; fi
      ;;
    *) echo "non-arm:${arch:-?}" ;;
  esac
}

deb_install() { # deb_install file.deb  (per run_step: niente domande)
  local f=$1 target name tmp
  target=$(deb_target "$f")
  name=$(deb_field "$f" Package)
  case $target in
    termux) pkg_install "$f" ;;
    container)
      cx_installed || { err "$(t cx_missing)"; return 1; }
      # nella /tmp condivisa: dentro il container si vede come /tmp/...
      tmp="$TMPDIR/tod-deb-$$-${f##*/}"
      cp -f "$f" "$tmp" || return 1
      CX_EXPORT_NAMES=$name cx_pkg_install "/tmp/${tmp##*/}" || { rm -f "$tmp"; return 1; }
      rm -f "$tmp"
      ;;
    *) err "$(t deb_not_arm "${f##*/}" "${target#non-arm:}")"; return 1 ;;
  esac
}

deb_add() { # tod add file.deb
  local f target
  f=$(deb_resolve "$1") || die "$(t deb_not_found "$1")"
  target=$(deb_target "$f")
  if [[ $target == non-arm:* ]]; then die "$(t deb_not_arm "${f##*/}" "${target#non-arm:}")"; fi
  detect_gpu
  run_step "$(t deb_installing "$(deb_field "$f" Package)" "$(t "deb_where_$target")")" deb_install "$f"
}

deb_check() { # tod _deb_check file.deb → righe chiave=valore per l'installer grafico
  local f=$1 target name ver have="" cmp=none owner=""
  target=$(deb_target "$f")
  name=$(deb_field "$f" Package)
  ver=$(deb_field "$f" Version)
  if pkg_installed "$name"; then
    have=$(pkg_version "$name")
  elif cx_installed && cx_pkg_installed "$name"; then
    have=$(awk -v p="$name" '/^Package: /{f = ($2 == p)} f && /^Version: /{print $2; exit}' "$(cx_rootfs)/var/lib/dpkg/status")
  fi
  if [[ -n $have ]]; then
    if dpkg --compare-versions "$ver" gt "$have"; then cmp=newer
    elif dpkg --compare-versions "$ver" eq "$have"; then cmp=same
    else cmp=older; fi
  else
    owner=$(app_owner "$name") || owner=""   # la stessa app già installata in un altro sistema
  fi
  printf 'target=%s\nname=%s\nversion=%s\ninstalled=%s\ncmp=%s\nowner=%s\n' \
    "$target" "$name" "$ver" "$have" "$cmp" "$owner"
}

deb_gui() { # tod installa file.deb — doppio clic dal file manager
  # l'installer grafico (share/tod-installer.py, come i .pkg di macOS); zenity se manca PyGObject
  if [[ -n ${DISPLAY:-} ]] && python3 -c 'import gi' 2>/dev/null; then
    local f
    f=$(deb_resolve "${1:-}") || f=${1:-}
    exec python3 "$TOD_ROOT/share/tod-installer.py" "$f"
  fi
  deb_gui_zenity "$@"
}

deb_gui_zenity() {
  local f target name ver desc rc_file rc=0
  local -a z=(zenity --width=460)
  if ! have zenity || [[ -z ${DISPLAY:-} ]]; then deb_add "$@"; return; fi
  if ! f=$(deb_resolve "${1:-}"); then "${z[@]}" --error --text="$(t deb_not_found "${1:-}")"; return 1; fi
  target=$(deb_target "$f")
  if [[ $target == non-arm:* ]]; then
    "${z[@]}" --error --text="$(t deb_not_arm "${f##*/}" "${target#non-arm:}")"
    return 1
  fi
  name=$(deb_field "$f" Package)
  ver=$(deb_field "$f" Version)
  desc=$(deb_field "$f" Description | sed -n 1p)
  "${z[@]}" --question --title="$(t deb_title)" --ok-label="$(t deb_ok)" --cancel-label="$(t deb_cancel)" \
    --text="$(t deb_confirm "$name" "$ver" "$desc" "$(t "deb_where_$target")")" || return 0
  rc_file=$(mktemp "$TMPDIR/tod-deb-rc-XXXXXX")
  detect_gpu
  ( deb_install "$f" >>"$TOD_LOG" 2>&1 </dev/null; echo $? >"$rc_file" ) |
    "${z[@]}" --progress --pulsate --auto-close --no-cancel --title="$(t deb_title)" \
      --text="$(t deb_installing "$name" "$(t "deb_where_$target")")" || true
  rc=$(cat "$rc_file" 2>/dev/null) || rc=1
  rm -f "$rc_file"
  conf_load
  if [[ $rc == 0 ]]; then
    log "deb installato: $name ($target)"
    "${z[@]}" --info --title="$(t deb_title)" --text="$(t deb_done "$name")"
  else
    log "deb non installato: $name ($target) rc=$rc"
    "${z[@]}" --error --title="$(t deb_title)" --text="$(t deb_failed "$name")

$(tail -n 8 "$TOD_LOG" | cut -c1-120)"
    return 1
  fi
}

# --- app del telefono nel desktop ------------------------------------------------------
# share/tod-android-apps.py: una voce di menu con la sua icona vera per ogni app Android,
# che la apre in una finestra di DeX (am start). Solo in Termux (usa cmd/pm di Android).
ANDROID_APPS_PKGS="aapt2 librsvg libwebp"

android_apps_ready() { have aapt2 && have rsvg-convert && have dwebp && have cmd; }

android_apps_sync() { # in sottofondo: solo le app nuove o aggiornate (cache per versione)
  if [[ $(conf_get ANDROID_APPS 1) != 1 ]] || ! android_apps_ready; then return 0; fi
  (low_prio setsid python3 "$TOD_ROOT/share/tod-android-apps.py" </dev/null >>"$TOD_STATE_DIR/android-apps.log" 2>&1 &)
}

android_apps_cli() { # tod telefono [aggiorna|rifai|spento|acceso|notifiche accese|spente]
  case ${1:-aggiorna} in
    aggiorna | sync)
      if [[ $(conf_get ANDROID_APPS 1) != 1 ]]; then return 0; fi   # spente: restano spente
      if ! android_apps_ready; then pkg_install_avail $ANDROID_APPS_PKGS || true; fi
      python3 "$TOD_ROOT/share/tod-android-apps.py"
      ;;
    rifai | rebuild) python3 "$TOD_ROOT/share/tod-android-apps.py" --force ;;
    spento | off)
      conf_set ANDROID_APPS 0
      # il generatore, se sta lavorando in sottofondo, legge l'interruttore a ogni app e si ferma da sé
      # togliendo le voci; qui le si toglie subito
      rm -f "$(files_termux_home)"/.local/share/applications/tod-android-*.desktop
      desktop_refresh_caches || true
      ;;
    acceso | on) conf_set ANDROID_APPS 1; android_apps_sync ;;
    notifiche | notifications)
      local off="$HOME/.config/tod/notifiche-telefono-spente"
      case ${2:-} in
        spente | off) mkdir -p "${off%/*}" && : >"$off" ;;
        accese | on) rm -f "$off" ;;
        *) die "tod telefono notifiche [accese|spente]" ;;
      esac
      ;;
    *) die "tod telefono [aggiorna|rifai|spento|acceso|notifiche accese|spente]" ;;
  esac
}

# --- il telefono nel desktop: batteria, rete e notifiche (Termux:API) --------------------
# share/tod-phone-status.py: un demone legge lo stato ogni 20 s, due plugin "genmon"
# della barra lo mostrano (icona + suggerimento), come la batteria e il Wi-Fi di Windows;
# ogni 5 s porta le notifiche nuove del telefono nel centro notifiche (clic = apri l'app).
# Serve l'"Accesso alle notifiche" per Termux:API nelle impostazioni di Android.
phone_status_ready() { have termux-battery-status && pm list packages com.termux.api 2>/dev/null | grep -q termux.api; }

phone_status_start() {
  if ! phone_status_ready; then return 0; fi
  (low_prio setsid python3 "$TOD_ROOT/share/tod-phone-status.py" demone </dev/null >>"$TOD_STATE_DIR/phone-status.log" 2>&1 &)
}
