# shellcheck shell=bash
# =============================================================================
#  Installazione guidata — ogni passo è ripetibile e riprende da dove si era fermato
# =============================================================================

installer_usage() {
  cat <<'EOF'
tod install [opzioni]
  -y, --yes               nessuna domanda (valori predefiniti)
  --container | --no-container    container Debian per le app extra (predefinito: sì)
  --distro debian|ubuntu  distribuzione del container
  --no-experimental       niente driver Freedreno-KGSL sperimentali
  --bench                 sceglie il driver GPU con un benchmark glmark2 (più lento)
  --reset                 ricomincia da zero (ignora i passi già completati)
  -v, --verbose           mostra tutto l'output
EOF
}

installer_main() {
  local bench=""
  while (($#)); do
    case $1 in
      -y | --yes) TOD_YES=1 ;;
      --container) conf_set CX_ENABLE yes ;;
      --no-container) conf_set CX_ENABLE no ;;
      --distro) conf_set CX_DISTRO "${2:-debian}"; if (($# > 1)); then shift; fi ;;
      --no-experimental) conf_set GPU_EXPERIMENTAL no ;;
      --bench) bench=--bench ;;
      --reset) step_reset ;;
      -v | --verbose) TOD_VERBOSE=1 ;;
      -h | --help) installer_usage; return 0 ;;
      *) warn "$(t unknown_opt "$1")" ;;
    esac
    shift
  done

  if have termux-wake-lock; then termux-wake-lock || true; fi
  # quando è cominciato tutto: al disinstallatore serve sapere cosa abbiamo installato noi
  if [[ -z $(conf_get INSTALL_START) ]]; then conf_set INSTALL_START "$(date '+%F %T')"; fi
  detect_device
  detect_termux
  if ! have dialog && [[ $TOD_YES != 1 ]]; then
    run_step "dialog" bash -c 'apt-get update -q && apt-get install -y -q dialog' || true
  fi

  if tui_init; then
    # interfaccia grafica: benvenuto, controlli iniziali in una finestra
    if ! tui_welcome; then tui_end; clear; die "$(t aborted)"; fi
    local pf_out pf_rc=0
    pf_out=$(preflight 2>&1) || pf_rc=$?
    pf_out=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$pf_out")
    if [[ -n $pf_out ]]; then ui_msg "$(t pf_title)" "$pf_out"; fi
    if (( pf_rc )); then tui_end; clear; die "$(t pf_fatal)"; fi
  else
    header "Termux On DeX $TOD_VERSION"
    device_summary
    preflight || die "$(t pf_fatal)"
  fi

  installer_questions
  installer_samsung_autoblocker
  installer_steps "$bench"

  conf_set INSTALLED 1
  conf_set INSTALLED_VERSION "$TOD_VERSION"
  if have termux-wake-unlock; then termux-wake-unlock || true; fi
  installer_done
}

installer_questions() {
  [[ $TOD_YES == 1 ]] && return 0
  # già installato: si riprende/completa senza rifare le domande
  if [[ $(conf_get INSTALLED 0) == 1 ]]; then return 0; fi
  # con la schermata di benvenuto qui si chiede solo ADB (serve prima di Termux:X11): il resto lo
  # chiede lei, mentre l'installazione va avanti con i valori predefiniti (xfce, Debian, windows11)
  if ! bv_wanted; then installer_questions_main; fi
  installer_question_phantom
}

installer_question_phantom() {
  if ui_yesno "$(t q_ph_title)" "$(t q_ph_text)" y; then conf_set PHANTOM_NOW yes; else conf_set PHANTOM_NOW no; fi
}

installer_questions_main() { # nome utente, container, GPU, app (nel terminale)
  local v apps
  if (( ! TUI_ON )); then ui_msg "$(t welcome_title)" "$(t welcome_text "${DEV_NAME:-$DEV_MODEL}" "$GPU_LABEL" "$ANDROID_REL")"; fi
  while true; do
    v=$(ui_input "$(t q_user_title)" "$(t q_user_text)" "$(conf_get USER_NAME utente)") || die "$(t aborted)"
    v=${v,,}
    if files_user_valid "$v"; then conf_set USER_NAME "$v"; break; fi
    ui_msg "$(t q_user_title)" "$(t q_user_bad "$v")"
  done
  conf_set DE xfce   # XFCE con DeX OS: l'unico desktop
  conf_set ASPETTO windows11
  if ui_yesno "$(t q_cx_title)" "$(t q_cx_text)" "$( [[ $(conf_get CX_ENABLE yes) == yes ]] && echo y || echo n)"; then
    conf_set CX_ENABLE yes
  else
    conf_set CX_ENABLE no
  fi
  if [[ $GPU_FAMILY == adreno ]]; then
    if ui_yesno "$(t q_gpu_title)" "$(t q_gpu_text "$GPU_LABEL")" y; then
      conf_set GPU_EXPERIMENTAL yes
    else
      conf_set GPU_EXPERIMENTAL no
    fi
  fi
  local -a cat=()
  mapfile -t cat < <(apps_catalog_args)
  if apps=$(ui_checklist "$(t q_apps_title)" "$(t q_apps_text)" "${cat[@]}"); then
    conf_set APPS "$(tr '\n' ' ' <<<"$apps")"
  fi
}

installer_samsung_autoblocker() { # Blocco automatico blocca APK esterni e debug wireless
  [[ ${DEV_BRAND,,} == samsung ]] || return 0
  if step_done x11app && step_done phantom; then return 0; fi
  am start -a android.settings.SECURITY_SETTINGS >/dev/null 2>&1 || true
  ui_msg "$(t ab_title)" "$(t ab_text)"
}

_step() { # _step id "titolo" comando...   (con possibilità di riprovare)
  local id=$1 title=$2
  shift 2
  if step_done "$id"; then
    if (( ! TUI_ON )); then printf ' %s↷ %s (%s)%s\n' "$C_DIM" "$title" "$(t already_done)" "$C_0"; fi
    return 0
  fi
  if (( TUI_ON )); then tui_run "$id" "$@"; return; fi
  local attempt=1 max=3
  if [[ $TOD_YES == 1 ]]; then max=2; fi
  while true; do
    if run_step "$title" "$@"; then
      step_mark "$id"
      return 0
    fi
    if (( attempt >= max )) || ! ui_yesno "$(t step_retry_title)" "$(t step_retry_text "$title" "$TOD_LOG")" y; then
      die "$(t step_failed "$title" "$TOD_LOG")"
    fi
    attempt=$((attempt + 1))
  done
}

installer_base() {
  pkg_upgrade || return 1
  pkg_install_avail dialog jq curl wget git procps ncurses-utils termux-am util-linux || return 1
  pkg_enable_repos || return 1
  pkg_install termux-x11-nightly pulseaudio dbus xorg-xrandr || return 1
  pkg_install_avail xorg-xdpyinfo xorg-xhost || true
}

installer_steps() {
  local bench=${1:-} de
  de=$(conf_get DE xfce)
  if [[ -z $(conf_get APPS) && $TOD_YES == 1 ]]; then
    if [[ $(conf_get CX_ENABLE yes) == yes ]]; then conf_set APPS "firefox libreoffice"; else conf_set APPS "firefox"; fi
  fi
  local cx_on=0 look_on=0 lang_on=0
  if [[ $(conf_get CX_ENABLE yes) == yes ]]; then cx_on=1; fi
  if [[ $de == xfce ]]; then look_on=1; fi
  if [[ $(lingua_code) != en ]]; then lang_on=1; fi
  if (( TUI_ON )); then # elenco completo dei passi, con il loro peso sulla barra totale
    tui_register base "$(t s_base)" 14
    if [[ $(conf_get PHANTOM_NOW no) == yes ]]; then tui_register phantom "$(t s_phantom)" 2; fi
    tui_register x11app "$(t s_x11app)" 3
    tui_register apiapp "$(t s_apiapp)" 2
    if bv_wanted; then tui_register benvenuto "$(t s_bv)" 3; fi
    tui_register desktop "$(t s_desktop "$de")" 16
    tui_register gpu "$(t s_gpu)" 12
    if (( cx_on )); then
      tui_register cx "$(t s_cx "$(cx_distro)")" 25
      tui_register cxgpu "$(t s_cxgpu)" 5
    fi
    tui_register apps "$(t s_apps)" 18
    if ((look_on)); then tui_register look "$(t s_look)" 4; fi
    if ((lang_on)) || bv_wanted; then tui_register lingua "$(t s_lingua "$(lingua_code)")" 8; fi
    if usb_on; then tui_register usb "$(t s_usb)" 3; fi
    tui_register integrate "$(t s_integrate)" 3
    if [[ $de == xfce ]]; then tui_register preseed "$(t s_preseed)" 2; fi
  fi
  _step base "$(t s_base)" installer_base
  # subito dopo la base: apt dentro proot crea decine di processi e il Phantom
  # Process Killer potrebbe uccidere l'installazione a metà
  if [[ $(conf_get PHANTOM_NOW no) == yes ]] && ! step_done phantom; then
    # segnato come fatto solo se è riuscito: rilanciando "tod install" si riprova
    if (( TUI_ON )); then
      tui_interactive phantom phantom_fix
    elif phantom_fix; then
      step_mark phantom
    else
      warn "$(t ph_retry_later)"
    fi
  fi
  if ! step_done x11app; then
    if (( TUI_ON )); then
      tui_interactive x11app x11_app_ensure
      if ! step_done x11app; then tui_end; clear; die "$(t x11app_missing)"; fi
    else
      x11_app_ensure || die "$(t x11app_missing)"
      step_mark x11app
    fi
  fi
  # Termux:API (batteria, rete e notifiche del telefono nel desktop): non indispensabile, quindi se
  # non va l'installazione prosegue; rilanciando "tod install" si riprova
  if ! step_done apiapp; then
    if (( TUI_ON )); then
      tui_interactive apiapp api_app_ensure
    elif api_app_ensure; then
      step_mark apiapp
    fi
  fi
  # da qui l'installazione si vede (e si sceglie) nella schermata di benvenuto, in Termux:X11
  if bv_wanted && (( ! BV_ON )); then
    # shellcheck disable=SC2086
    _step benvenuto "$(t s_bv)" pkg_install $BV_PKGS
    if ! bv_start; then
      warn "$(t bv_fail)"
      tui_gauge_close
      installer_questions_main
      de=$(conf_get DE xfce)
    fi
  fi
  _step desktop "$(t s_desktop "$de")" desktop_install "$de"
  _step gpu "$(t s_gpu)" gpu_setup "$bench"
  if (( cx_on )); then
    _step cx "$(t s_cx "$(cx_distro)")" cx_install
    _step cxgpu "$(t s_cxgpu)" cx_gpu_setup
  fi
  bv_answers   # nome, lingua, aspetto e app: servono da qui in poi
  # con la schermata di benvenuto il nome utente arriva dopo desktop e Debian, che senza non avevano
  # potuto fare cartella personale, Download/Immagini/... nella barra di Esplora file e le stesse
  # cartelle nel container (S20+, 17 ottobre)
  if (( BV_ON )) || [[ $(conf_get BV_RISPOSTE 0) == 1 ]]; then installer_user_folders; fi
  _step apps "$(t s_apps)" apps_install_selected
  if ((look_on)); then _step look "$(t s_look)" look_apply_current; fi
  if ((lang_on)) || [[ $(lingua_code) != en ]]; then _step lingua "$(t s_lingua "$(lingua_code)")" lingua_setup; fi
  # dischi USB: tod-lkl e le sue librerie (scaricati, o compilati se non si può), ntfs-3g nel container
  if usb_on; then _step usb "$(t s_usb)" usb_install; fi
  _step integrate "$(t s_integrate)" installer_integrate
  # tema, icone, cartelle e barra già nei file: il desktop parte la prima volta già sistemato
  if [[ $de == xfce ]]; then _step preseed "$(t s_preseed)" session_preseed; fi
}

installer_user_folders() {
  files_setup || true
  if cx_installed; then files_cx_user_dirs || true; fi
}

installer_integrate() {
  # il comando 'tod' e quello della v1 ('termux_on_dex')
  chmod 755 "$TOD_ROOT/tod" || return 1
  ln -sfn "$TOD_ROOT/tod" "$PREFIX/bin/tod" || return 1
  printf '#!%s/bin/bash\nexec "%s/bin/tod" start "$@"\n' "$PREFIX" "$PREFIX" >"$PREFIX/bin/termux_on_dex" || return 1
  chmod 755 "$PREFIX/bin/termux_on_dex"
  # scorciatoie per Termux:Widget (schermata home / barra DeX)
  mkdir -p "$HOME/.shortcuts"
  printf '#!%s/bin/bash\nexec "%s/bin/tod" start\n' "$PREFIX" "$PREFIX" >"$HOME/.shortcuts/Linux DeX"
  printf '#!%s/bin/bash\nexec "%s/bin/tod" stop\n' "$PREFIX" "$PREFIX" >"$HOME/.shortcuts/Linux DeX - stop"
  chmod 700 "$HOME/.shortcuts/Linux DeX" "$HOME/.shortcuts/Linux DeX - stop"
  desktop_install_entries
}

installer_done() {
  if (( BV_ON )) && bv_finish; then   # "Inizia" nella schermata di benvenuto: subito il desktop
    tui_end
    clear
    printf '\n%s\n' "$(t done_cli)"
    if [[ ${DEV_BRAND,,} == samsung ]]; then info "$(t ab_end)"; fi
    session_adopt   # sullo schermo della schermata di benvenuto, che resta davanti finché è pronto
    return 0
  fi
  if (( TUI_ON )); then
    local start=0
    if tui_finish; then start=1; fi
    tui_end
    clear
    printf '\n%s\n' "$(t done_cli)"
    if [[ ${DEV_BRAND,,} == samsung ]]; then info "$(t ab_end)"; fi
    if (( start )); then session_start; fi
    return 0
  fi
  local gpu cx=""
  gpu=$(conf_get GPU_PROFILE llvmpipe)
  if cx_installed; then cx="$(cx_distro) (GPU: $(conf_get CX_GPU_PROFILE llvmpipe))"; fi
  ui_msg "$(t done_title)" "$(t done_text "$(conf_get DE xfce)" "$gpu" "${cx:-—}")"
  printf '\n%s\n' "$(t done_cli)"
  if [[ ${DEV_BRAND,,} == samsung ]]; then info "$(t ab_end)"; fi
}
