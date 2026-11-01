# shellcheck shell=bash
# =============================================================================
#  Manutenzione: diagnostica, aggiornamento sicuro, disinstallazione, aiuto
# =============================================================================

tod_doctor() { # report da allegare alle issue
  detect_device
  detect_termux
  local held mesa_v x11_v x11_app cx="—" p st r
  held=$(pkg_held_list | tr '\n' ' ')
  mesa_v=$(pkg_version mesa)
  x11_v=$(pkg_version termux-x11-nightly)
  if cx_installed; then cx="$(cx_distro) [$(cx_os || true)] · mesa=$(conf_get CX_MESA_TAG '-') · GPU=$(conf_get CX_GPU_PROFILE '?')"; fi
  printf '%sTermux On DeX %s — %s%s (%s)\n' "$C_BOLD" "$TOD_VERSION" "$(t doc_title)" "$C_0" "$(date '+%F %T')"
  device_summary
  if [[ -n $X11_APK ]]; then x11_app=ok; else x11_app=$(t missing); fi
  printf '  %-12s %s\n' "Termux:X11" "app: $x11_app · pkg: ${x11_v:-—} · UID: $(x11_uid_status) ($(t x11_recommended) $(x11_variant))"
  printf '  %-12s %s · stack %s%s · %s %s\n' "Mesa" "${mesa_v:-—}" "$(gpu_stack)" \
    "$( [[ $(gpu_stack) == lfdevs ]] && printf ' (%s)' "$(conf_get GPU_LFDEVS_TAG)")" "hold:" "${held:-—}"
  printf '  %-12s %s\n' "$(t lbl_session)" "$(session_running && t running || t stopped)"
  printf '  %-12s %s\n' "$(t lbl_container)" "$cx"
  printf '  %-12s %s\n' "Phantom" "$(phantom_status)"
  printf '  %-12s %s\n' "Shizuku" "$(shizuku_status)"
  printf '  %-12s %s\n' "$(t lbl_lingua)" "$(lingua_doctor)"
  printf '  %-12s %s\n' "Config" "DE=$(conf_get DE xfce) DPI=$(conf_get DPI auto) VSYNC=$(conf_get VSYNC on) X11_LEGACY=$(conf_get X11_LEGACY 0)"
  gpu_show
  if [[ -f $TOD_STATE_DIR/cx-gpu-probe.txt ]]; then
    printf '%sGPU container%s  %s=%s\n' "$C_BOLD" "$C_0" "$(t gpu_active)" "$(conf_get CX_GPU_PROFILE '?')"
    while IFS='|' read -r p st r; do
      [[ -n $p ]] || continue
      if [[ $st == ok ]]; then printf '  ✔ %-15s %s\n' "$p" "$r"; else printf '  ✘ %-15s\n' "$p"; fi
    done <"$TOD_STATE_DIR/cx-gpu-probe.txt"
  fi
  printf '%sAudio%s\n' "$C_BOLD" "$C_0"
  audio_status
  printf '%sServer X%s  %s: %s\n' "$C_BOLD" "$C_0" "$(t doc_x11_pids)" "$(x11_server_pids | tr '\n' ' ')"
  local f
  for f in session.log x11-probe.log; do
    if [[ -s $TOD_STATE_DIR/$f ]]; then
      printf '  [%s]\n' "$f"
      tail -n 10 "$TOD_STATE_DIR/$f" | cut -c1-200 | sed 's/^/    /'
    fi
  done
  printf '%s%s%s\n' "$C_BOLD" "$(t doc_recent)" "$C_0"
  { grep -E ' (ERR|WARN|ERRORE) ' "$TOD_LOG" 2>/dev/null || true; } | tail -n 12 | sed 's/^/  /'
  printf '\n%s\n' "$(t doc_hint "$TOD_LOG")"
}

# ----------------------------------------------------------------------------
#  Il codice di Termux On DeX da GitHub: tod update e la finestra Aggiornamenti (_self_check, _self_update)
# ----------------------------------------------------------------------------
self_upstream() { # → "origin v2" se questa copia di tod segue un ramo su GitHub (installazione), sennò errore
  local up
  [[ -d $TOD_ROOT/.git ]] && have git || return 1
  up=$(git -C "$TOD_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || return 1
  [[ $up == ?*/?* ]] || return 1
  printf '%s %s' "${up%%/*}" "${up#*/}"
}

self_check() { # tod _self_check [--locale]: novità di Termux On DeX → righe chiave=valore per Aggiornamenti
  local up remote branch here new
  if ! up=$(self_upstream); then echo "stato=nessuno"; return 0; fi
  read -r remote branch <<<"$up"
  # 30 commit bastano a contare le novità di una copia leggera (git clone --depth 1 dell'installazione)
  if [[ ${1:-} != --locale ]] && ! timeout 120 git -C "$TOD_ROOT" fetch -q --depth 30 "$remote" "$branch" 2>/dev/null; then
    echo "stato=errore"
    return 0
  fi
  here=$(git -C "$TOD_ROOT" rev-parse HEAD)
  new=$(git -C "$TOD_ROOT" rev-parse -q --verify FETCH_HEAD 2>/dev/null) || new=$here
  if [[ $new == "$here" ]]; then echo "stato=aggiornato"; return 0; fi
  printf 'stato=nuovo\nda=%s\na=%s\n' "${here:0:7}" "${new:0:7}"
  # storia riscritta su GitHub (o troppo vecchia): le novità non si contano, ma l'aggiornamento c'è
  if git -C "$TOD_ROOT" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
    printf 'novita=%s\n' "$(git -C "$TOD_ROOT" rev-list --count HEAD..FETCH_HEAD)"
    git -C "$TOD_ROOT" log --format='titolo=%s' -n 8 HEAD..FETCH_HEAD
  else
    git -C "$TOD_ROOT" log --format='titolo=%s' -n 1 FETCH_HEAD
  fi
}

self_is_install() { # è la copia di tod fatta da install.sh (non una copia di sviluppo)?
  local inst="${TOD_TERMUX_HOME:-$HOME}/.local/share/tod"
  # leggera (git clone --depth 1), o al suo posto: un controllo con fetch --depth 30 su un ramo di pochi commit
  # scarica tutta la storia e la copia smette di essere "leggera"
  [[ $(git -C "$TOD_ROOT" rev-parse --is-shallow-repository 2>/dev/null) == true ]] && return 0
  [[ -d $inst && ! -L $inst && $(cd "$TOD_ROOT" && pwd -P) == "$(cd "$inst" && pwd -P)" ]]
}

self_update() { # il codice nuovo da GitHub. 0 = aggiornato o già aggiornato
  local up remote branch
  up=$(self_upstream) || return 1
  read -r remote branch <<<"$up"
  if self_is_install; then
    # copia dell'installazione: come install.sh, così regge anche una storia riscritta
    # su GitHub (1° novembre: dopo il commit unico, git pull --ff-only falliva sulle installazioni del 31 ottobre).
    # Ma mai sopra modifiche fatte a mano
    # (i permessi non contano: install.sh e questa funzione fanno chmod 755 su tod)
    if [[ -n $(git -C "$TOD_ROOT" -c core.fileMode=false status --porcelain --untracked-files=no) ]]; then
      warn "$(t up_self_local)"
      return 1
    fi
    git -C "$TOD_ROOT" fetch -q --depth 1 "$remote" "$branch" || return 1
    git -C "$TOD_ROOT" reset -q --hard FETCH_HEAD || return 1
  else
    git -C "$TOD_ROOT" pull -q --ff-only "$remote" "$branch" || return 1   # una copia di sviluppo: solo avanti
  fi
  chmod 755 "$TOD_ROOT/tod"
}

self_after() { # tod _self_after: con il codice nuovo, i file che dipendono da lui (dalla finestra Aggiornamenti)
  desktop_install_entries || true
  # dischi USB: i file di tod-lkl della versione nuova
  if usb_on && ! usb_lkl_ok; then usb_install || warn "$(t s_usb)"; fi
  # Termux:X11 nuova: installarla chiude Termux (sharedUid), quindi solo da tod update in Termux
  if x11_glamor_da_aggiornare; then echo "x11=nuova"; fi
  return 0
}

self_update_cli() { # tod _self_update: codice nuovo, poi i passi successivi eseguiti dal codice nuovo
  self_update || { err "$(t up_self_fail)"; return 1; }
  exec "$TOD_ROOT/tod" _self_after
}

tod_update() { # tod update [--senza-codice]
  local rel tag reprobe=0 before after
  detect_device
  if [[ ${1:-} != --senza-codice ]] && self_upstream >/dev/null; then
    before=$(git -C "$TOD_ROOT" rev-parse HEAD)
    if run_step "$(t up_self)" self_update; then
      # codice cambiato: il resto dell'aggiornamento lo fa la versione nuova (versioni di LKL, Termux:X11...)
      if [[ $(git -C "$TOD_ROOT" rev-parse HEAD) != "$before" ]]; then exec "$TOD_ROOT/tod" update --senza-codice; fi
    else
      warn "$(t up_self_fail)"
    fi
  fi
  before=$(pkg_version mesa)
  run_step "$(t up_pkgs)" pkg_upgrade || warn "$(t up_pkgs_fail)"
  after=$(pkg_version mesa)
  if [[ $before != "$after" ]]; then reprobe=1; fi
  if [[ $(gpu_stack) == lfdevs ]] && have jq; then
    if rel=$(gh_release "$LFDEVS_TERMUX_REPO" freedreno-); then
      tag=$(jq -r .tag_name <<<"$rel")
      if [[ $tag != "$(conf_get GPU_LFDEVS_TAG)" ]] && ui_yesno "GPU" "$(t up_gpu_new "$tag")" y; then
        run_step "$(t s_gpu_lfdevs)" gpu_install_lfdevs && reprobe=1
      fi
    fi
  fi
  if cx_installed; then run_step "$(t s_cx_update)" cx_upgrade || warn "$(t up_cx_fail)"; fi
  # dischi USB: i file di tod-lkl della versione nuova (e, una volta, via la vecchia macchina QEMU)
  if usb_on && { ! usb_lkl_ok || [[ -f $(usb_data)/disco.img ]]; }; then run_step "$(t s_usb)" usb_install || warn "$(t s_usb)"; fi
  if (( reprobe )); then run_step "$(t s_gpu_probe)" gpu_reprobe || warn "$(t gpu_none)"; fi
  ok "$(t up_done)"
  x11_glamor_aggiorna || true   # per ultima: installare la Termux:X11 chiude Termux
}

tod_first_timestamp() { # inizio della prima installazione (configurazione o primo log)
  local ts
  ts=$(conf_get INSTALL_START)
  if [[ -z $ts ]]; then
    ts=$(cat "$TOD_LOG.1" "$TOD_LOG" 2>/dev/null | sed -n 's/^\([0-9]\{4\}-[0-9-]* [0-9:]*\) .*/\1/p' | sed -n 1p) || ts=""
  fi
  printf '%s' "$ts"
}

tod_installed_packages() { # pacchetti installati dopo $1 (vuoto = da quando Termux è stato installato)
  local since=${1:-} f p
  for f in "$PREFIX"/var/log/dpkg.log*; do
    [[ -f $f ]] || continue
    if [[ $f == *.gz ]]; then gzip -dc "$f" 2>/dev/null || true; else cat "$f"; fi
  done | awk -v since="$since" '$3 == "install" && $5 == "<none>" && ($1 " " $2) >= since {
    sub(/:.*/, "", $4); print $4 }' | sort -u | while IFS= read -r p; do
    if pkg_installed "$p"; then printf '%s\n' "$p"; fi
  done
}

uninstall_session() {
  session_stop >/dev/null 2>&1 || true
  if have termux-wake-unlock; then termux-wake-unlock || true; fi
  return 0
}

uninstall_container() {
  local base="$PREFIX/var/lib/proot-distro" d
  d=$(cx_distro)
  if have proot-distro; then
    if cx_installed || [[ -d $base/containers/$d || -d $base/installed-rootfs/$d ]]; then
      progress_note 10 "$(t un_s_cx)"
      proot-distro remove "$d" || return 1
    fi
    proot-distro clear-cache >/dev/null 2>&1 || true
  fi
  return 0
}

uninstall_packages() { # i pacchetti diventano "automatici": apt toglie solo quelli che non servono a nient'altro
  local since crit sim
  local -a pk=()
  since=$(conf_get UNINSTALL_SINCE)
  mapfile -t pk < <(tod_installed_packages "$since")
  log "disinstallazione: ${#pk[@]} pacchetti candidati (da '${since:-sempre}')"
  pkg_unhold mesa mesa-vulkan-icd-freedreno
  if ((${#pk[@]} == 0)); then return 0; fi
  apt-mark auto "${pk[@]}" >/dev/null 2>&1 || true
  # prova generale: mai togliere i pacchetti vitali di Termux
  sim=$(apt-get -s autoremove --purge 2>/dev/null | awk '/^(Purg|Remv) / {print $2}') || sim=""
  for crit in apt bash coreutils dash dpkg termux-tools termux-exec termux-keyring termux-core termux-am-socket; do
    if grep -qx "$crit" <<<"$sim"; then err "$(t un_pkgs_unsafe "$crit")"; return 1; fi
  done
  apt_run "${APT_FLAGS[@]}" autoremove --purge
}

uninstall_files() {
  local p
  # file scritti dall'aspetto fuori dalle nostre cartelle
  if [[ -f $TOD_STATE_DIR/look-paths ]]; then
    while IFS= read -r p; do
      case $p in "$HOME"/* | "$PREFIX"/share/*) rm -rf "$p" ;; esac
    done <"$TOD_STATE_DIR/look-paths"
  fi
  rm -f "$HOME"/.local/share/applications/tod-*.desktop "$HOME/.config/autostart/tod-hook.desktop" \
    "$HOME/.shortcuts/Linux DeX" "$HOME/.shortcuts/Linux DeX - stop" "$PREFIX/bin/termux_on_dex" "$LINGUA_SO"
  rm -rf "$LINGUA_DIR"
  p=$(sed -n 1p "$PREFIX/etc/xdg/xfce4/kiosk/kioskrc" 2>/dev/null) || p=""
  if [[ $p == *"Termux On DeX"* ]]; then rm -f "$PREFIX/etc/xdg/xfce4/kiosk/kioskrc"; fi
  if [[ -f $PREFIX/lib/firefox/distribution/.tod ]]; then rm -rf "$PREFIX/lib/firefox/distribution"; fi
  # impostazioni e dati dei programmi del desktop (cartelle nascoste create usandolo)
  rm -f "$HOME"/.config/user-dirs.{dirs,conf,locale} "$HOME/.hidden"
  rm -rf "$HOME"/.config/{xfce4,xfce4.prima-della-v1,Thunar,Mousepad,ristretto,xarchiver,pulse,dconf,gtk-3.0,gtk-4.0,menus,autostart,kdeglobals,mimeapps.list} \
    "$HOME"/.cache/{xfce4,sessions,thumbnails,fontconfig,mesa_shader_cache,mesa_shader_cache_db,thunar,mozilla,dconf} \
    "$HOME"/.local/share/{xfce4,recently-used.xbel,applications,icons,pixmaps,backgrounds,Trash,mime} \
    "$HOME/.themes" "$HOME/.icons" "$HOME/.mozilla" "$HOME/.ICEauthority" "$HOME/.Xauthority" "$HOME/.dbus" 2>/dev/null || true
  rm -rf "$TOD_CONF_DIR" "$TOD_STATE_DIR" "$TOD_CACHE_DIR"
  rm -f "$PREFIX/bin/tod"
  return 0
}

tod_uninstall() {
  local scope since
  detect_device
  if [[ -n ${DISPLAY:-} ]] && session_running; then die "$(t un_in_session)"; fi
  ui_yesno "$(t un_title)" "$(t un_confirm_full)" n || return 0
  scope=$(ui_menu "$(t un_title)" "$(t un_scope_text)" tod \
    tod "$(t un_scope_tod)" all "$(t un_scope_all)") || return 0
  if [[ $scope == all ]]; then since=""; else since=$(tod_first_timestamp); fi
  conf_set UNINSTALL_SINCE "$since"
  TUI_TITLE=$(t un_title)
  if tui_init; then
    tui_register un_session "$(t un_s_session)" 3
    tui_register un_phantom "$(t un_s_phantom)" 2
    tui_register un_cx "$(t un_s_cx)" 25
    tui_register un_pkgs "$(t un_s_pkgs)" 55
    tui_register un_files "$(t un_s_files)" 15
  fi
  _step un_session "$(t un_s_session)" uninstall_session
  if ! step_done un_phantom; then
    if ((TUI_ON)); then tui_interactive un_phantom phantom_restore
    elif phantom_restore; then step_mark un_phantom
    fi
  fi
  _step un_cx "$(t un_s_cx)" uninstall_container
  _step un_pkgs "$(t un_s_pkgs)" uninstall_packages
  _step un_files "$(t un_s_files)" uninstall_files
  if ((TUI_ON)); then tui_end; clear; fi
  ok "$(t un_done)"
  printf '\n%s\n' "$(t un_after)"
  if x11_app_installed && ui_yesno "$(t un_title)" "$(t un_x11_app)" y; then
    am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:com.termux.x11 >/dev/null 2>&1 || true
  fi
  rm -rf "$TOD_ROOT"   # per ultimo: il codice di Termux On DeX stesso
}

tod_help() {
  printf '%sTermux On DeX %s%s\n\n' "$C_BOLD" "$TOD_VERSION" "$C_0"
  printf '%b\n' "$(t help_text)"
}
