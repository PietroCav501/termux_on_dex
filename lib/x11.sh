# shellcheck shell=bash
# =============================================================================
#  Termux:X11 — app, server X, preferenze, DPI/scala adattivi (telefono vs DeX)
# =============================================================================

TOD_X11_APK="$TMPDIR/termux-x11.apk"
TOD_X11_DEB="$TMPDIR/termux-x11-nightly.deb"

x11_sock() { printf '%s/.X11-unix/X%s' "$TMPDIR" "${1:-0}"; }

x11_lock_pid() { # PID che il server X scrive nel suo file di lock (standard X11), se è ancora vivo
  local f="$TMPDIR/.X0-lock" p=""
  if [[ ! -r $f ]]; then return 1; fi
  p=$(tr -dc '0-9' <"$f" 2>/dev/null) || p=""
  if [[ -z $p ]] || ! kill -0 "$p" 2>/dev/null; then return 1; fi
  # PID riciclato da un altro processo? controllo che sia davvero un server X
  if ! grep -qaE 'x11|X11|app_process' "/proc/$p/cmdline" "/proc/$p/comm" 2>/dev/null; then return 1; fi
  printf '%s\n' "$p"
}

x11_server_pids() { # server X attivi: dal file di lock e dal nome del processo
  {
    x11_lock_pid || true
    pgrep -f '^[^ ]*app_process[^ ]* .*com\.termux\.x11\.CmdEntryPoint' 2>/dev/null || true
    pgrep -x termux-x11 2>/dev/null || true
    # il server della sessione (argv "termux-x11 com.termux.x11 :0 ..."): il suo nome di processo non è
    # termux-x11 e, dopo un arresto con l'app ancora aperta, il file di lock può mancare (22 ottobre:
    # la dimensione dalle Impostazioni non si applicava più perché il server sembrava spento)
    pgrep -f '^termux-x11 com\.termux\.x11 :0( |$)' 2>/dev/null || true
  } | sort -u | sed '/^$/d' || true
}

x11_running() { [[ -S $(x11_sock) && -n $(x11_server_pids) ]]; }

x11_cleanup_stale() { # lock/socket rimasti da una sessione morta impediscono il riavvio
  if [[ -z $(x11_server_pids) ]]; then rm -f "$TMPDIR/.X0-lock" "$(x11_sock)"; fi
}

x11_wait_socket() { # x11_wait_socket [secondi]
  local i max=$((${1:-20} * 4))
  for ((i = 0; i < max; i++)); do
    if [[ -S $(x11_sock) ]]; then return 0; fi
    sleep 0.25
  done
  return 1
}

x11_kill() {
  local p i
  am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
  for p in $(x11_server_pids); do kill "$p" 2>/dev/null || true; done
  for ((i = 0; i < 12; i++)); do
    if [[ -z $(x11_server_pids) ]]; then break; fi
    sleep 0.25
  done
  for p in $(x11_server_pids); do kill -9 "$p" 2>/dev/null || true; done
  # ultima risorsa, come nel README di Termux:X11 (pkill -f termux-x11), ma solo sul
  # server e sul suo lanciatore: non tocca termux-x11-preference né altri comandi
  pkill -9 -f '(^|/)termux-x11( |$)' 2>/dev/null || true
  sleep "${TOD_X11_SETTLE:-1}"   # lascia all'app il tempo di chiudere prima di un nuovo avvio
  x11_cleanup_stale
}

x11_open_activity() { am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true; }

# x11_with_server comando...  → garantisce un server X su :0 per la durata del comando
# (usato dagli auto-test GPU durante l'installazione: l'activity non serve)
x11_with_server() {
  local started=0 pid rc=0 try
  if ! x11_running; then
    for try in 1 2 3; do
      x11_cleanup_stale
      XDG_RUNTIME_DIR=$TMPDIR nohup termux-x11 :0 -ac >"$TOD_STATE_DIR/x11-probe.log" 2>&1 </dev/null &
      pid=$!
      if x11_wait_socket "${TOD_X11_WAIT:-30}"; then started=1; break; fi
      # nel log principale finisce anche l'output del server: serve per capire il perché
      log "x11: avvio $try/3 fallito: $(tail -n 8 "$TOD_STATE_DIR/x11-probe.log" 2>/dev/null | tr '\n' ' ')"
      kill "$pid" 2>/dev/null || true
      x11_kill
      sleep "${TOD_X11_RETRY_PAUSE:-3}"
    done
    if (( ! started )); then err "$(t x11_no_socket)"; return 1; fi
    sleep 1
  fi
  DISPLAY=:0 "$@" || rc=$?
  if (( started )); then x11_kill; fi
  return "$rc"
}

# ----------------------------------------------------------------------------
#  App Termux:X11 (APK nightly ufficiale, abbinata al pacchetto termux-x11-nightly)
#
#  Variante "sharedUid": gira con lo stesso UID di Termux. Con la variante normale,
#  appena Termux:X11 va a schermo intero Android considera Termux in background e
#  sposta desktop e giochi sui core lenti (misurato: fino a 6 volte più lento).
#  Si può usare solo con Termux da GitHub (stessa firma).
# ----------------------------------------------------------------------------
x11_variant() { # → shareduid | regular
  if [[ ${TERMUX_APP__APK_RELEASE:-${TERMUX_APK_RELEASE:-}} == GITHUB ]]; then echo shareduid; else echo regular; fi
}

x11_uid_status() { # → shared | separate | unknown   (confronta l'UID di Termux:X11 con il nostro)
  local out uid
  out=$("${TOD_PM:-/system/bin/pm}" list packages -U com.termux.x11 2>/dev/null) || out=""
  uid=$(sed -n 's/^package:com\.termux\.x11 .*uid:\([0-9][0-9]*\).*/\1/p' <<<"$out" | sed -n 1p)
  if [[ -z $uid ]]; then echo unknown
  elif [[ $uid == "$(id -u)" ]]; then echo shared
  else echo separate; fi
}

x11_asset_query() { # filtro jq per l'APK giusto: x11_asset_query shareduid|regular
  if [[ $1 == shareduid ]]; then
    echo 'first(.assets[] | select(.name | test("sharedUid.*\\.apk$"))) | .browser_download_url'
  else
    # in jq la virgola lega più della pipe: ogni alternativa va tra parentesi
    echo 'first((.assets[] | select((.name | test("universal.*\\.apk$")) and (.name | test("sharedUid") | not))),
                (.assets[] | select((.name | test("arm64-v8a.*\\.apk$")) and (.name | test("sharedUid") | not)))) | .browser_download_url'
  fi
}

# Termux:X11 di Termux On DeX (x11/README.md): la nightly 6dfb8b4 con glamor (composizione con la GPU nel
# server X) e il mouse immediato. Solo sharedUid (firmata come Termux da GitHub). Viene dalla release
# x11-glamor-N del repository (o da dist/); se non arriva o l'impronta non torna, nightly ufficiale senza glamor.
X11_GLAMOR_VERSIONE=1
X11_GLAMOR_SHA256=3f20b6b2d6a7013d64887960a6c7f3ce5036c13563f38e947b281703a1b391aa
# TOD_X11_GLAMOR_URL: un'altra fonte per le prove prima di pubblicare (l'impronta vale lo stesso)
X11_GLAMOR_URL=${TOD_X11_GLAMOR_URL:-"https://github.com/PietroCav501/termux_on_dex/releases/download/x11-glamor-$X11_GLAMOR_VERSIONE/termux-x11-glamor-shareduid.apk"}

x11_glamor_download() { # → $TOD_X11_APK con la Termux:X11 con glamor, se c'è e l'impronta torna
  local locale=$TOD_ROOT/dist/termux-x11-glamor-shareduid.apk
  if [[ -f $locale ]] && sha256_ok "$locale" "$X11_GLAMOR_SHA256"; then
    cp -f "$locale" "$TOD_X11_APK"
    return 0
  fi
  net_download "$X11_GLAMOR_URL" "$TOD_X11_APK" "$X11_GLAMOR_SHA256"
}

x11_app_download() { # x11_app_download [shareduid|regular]
  local rel url variant
  variant=${1:-$(x11_variant)}
  rm -f "$TOD_X11_APK" "$TOD_X11_DEB"
  # X11_GLAMOR_APK=0 in tod.conf: sempre la nightly ufficiale
  if [[ $variant == shareduid && $(conf_get X11_GLAMOR_APK 1) == 1 ]]; then
    if x11_glamor_download; then
      log "Termux:X11: versione di Termux On DeX con glamor (x11-glamor-$X11_GLAMOR_VERSIONE)"
      # il pacchetto termux-x11-nightly resta quello del repository di Termux: il server viene dall'APK
      conf_set X11_GLAMOR 1
      conf_set X11_GLAMOR_INSTALLATA "$X11_GLAMOR_VERSIONE"   # per sapere quando ne esce una nuova
      return 0
    fi
    rm -f "$TOD_X11_APK"
    log "Termux:X11: la versione con glamor non è disponibile, uso la nightly ufficiale"
  fi
  conf_set X11_GLAMOR 0
  rel=$(net_get "https://api.github.com/repos/termux/termux-x11/releases/tags/nightly") || return 1
  url=$(jq -r "$(x11_asset_query "$variant")" <<<"$rel")
  if [[ (-z $url || $url == null) && $variant == shareduid ]]; then
    url=$(jq -r "$(x11_asset_query regular)" <<<"$rel")
  fi
  [[ -n $url && $url != null ]] || return 1
  log "Termux:X11: scarico $url"
  rm -f "$TOD_X11_APK" "$TOD_X11_DEB"
  net_download "$url" "$TOD_X11_APK" || return 1
  # pacchetto companion della *stessa* build: app e termux-x11-nightly devono combaciare
  url=$(jq -r 'first(.assets[] | select(.name | test("^termux-x11-nightly.*\\.deb$"))) | .browser_download_url' <<<"$rel")
  if [[ -n $url && $url != null ]]; then net_download "$url" "$TOD_X11_DEB" || rm -f "$TOD_X11_DEB"; fi
  return 0
}

x11_glamor_ok() { # glamor (composizione con la GPU nel server X): la nostra Termux:X11, e solo dove è provato
  # (Adreno). 1° novembre, S20+ (Mali): con glamor la Termux:X11 si chiudeva appena aperta. X11_GLAMOR_NO=1: su
  # questo telefono si è chiusa all'avvio (session_start), quindi mai più
  [[ $(conf_get X11_GLAMOR 0) == 1 && $(conf_get X11_GLAMOR_NO 0) != 1 ]] || return 1
  if [[ -z ${GPU_FAMILY:-} ]]; then detect_gpu; fi
  [[ ${GPU_FAMILY:-} == adreno ]]
}

x11_resta_vivo() { # x11_resta_vivo secondi: il server X è ancora acceso dopo un po' (glamor parte con la finestra)
  local i
  for ((i = 0; i < ${1:-4} * 4; i++)); do
    sleep 0.25
    x11_running || return 1
  done
  return 0
}

x11_glamor_da_aggiornare() { # c'è una Termux:X11 di Termux On DeX più nuova di quella installata?
  # (le installazioni da prima del 1° novembre non hanno il numero: avevano la 1)
  [[ $(conf_get X11_GLAMOR 0) == 1 && $(conf_get X11_GLAMOR_INSTALLATA 1) != "$X11_GLAMOR_VERSIONE" ]]
}

x11_glamor_aggiorna() { # da tod update, come ultimo passo: installarla chiude Termux e il desktop (sharedUid)
  x11_glamor_da_aggiornare || return 0
  if ! ui_yesno "Termux:X11" "$(t up_x11_new "$X11_GLAMOR_VERSIONE")" y; then
    info "$(t up_x11_later)"
    return 0
  fi
  run_step "$(t x11app_dl)" x11_app_download shareduid || { err "$(t x11app_dl_fail)"; return 1; }
  if priv_ready && apk_install_auto "$TOD_X11_APK"; then return 0; fi
  termux-open "$TOD_X11_APK" >/dev/null 2>&1 || true
}

x11_app_ensure() { # interattivo: non va dentro run_step
  local tries=0 variant
  variant=$(x11_variant)
  while ! x11_app_installed; do
    tries=$((tries + 1))
    if (( tries > 3 )); then err "$(t x11app_missing)"; return 1; fi
    # la variante sharedUid su alcuni telefoni resta su "Installazione in corso" per sempre:
    # al secondo giro si ripiega sulla normale (più lenta a schermo intero, ma si installa)
    if (( tries == 2 )) && [[ $variant == shareduid ]]; then
      variant=regular
      rm -f "$TOD_X11_APK" "$HOME/storage/downloads/termux-x11.apk"
      log "Termux:X11: la variante sharedUid non si è installata, provo la normale"
      ui_msg "$(t x11app_title)" "$(t x11app_fallback)"
    elif ! priv_ready; then
      ui_msg "$(t x11app_title)" "$(t x11app_text)"
    fi
    if [[ ! -s $TOD_X11_APK ]]; then
      run_step "$(t x11app_dl)" x11_app_download "$variant" || { err "$(t x11app_dl_fail)"; continue; }
    fi
    # con ADB collegato (passo dei processi di Android) si installa da sola
    if priv_ready && run_step "$(t apk_auto_run Termux:X11)" apk_install_auto "$TOD_X11_APK" && x11_app_installed; then ok "$(t apk_auto_ok Termux:X11)"; break; fi
    if priv_ready; then ui_msg "$(t x11app_title)" "$(t apk_manual_note)"; fi
    if [[ ! -d $HOME/storage/downloads ]]; then termux-setup-storage >/dev/null 2>&1 || true; sleep 4; fi
    if [[ -d $HOME/storage/downloads ]]; then cp -f "$TOD_X11_APK" "$HOME/storage/downloads/termux-x11.apk" || true; fi
    termux-open "$TOD_X11_APK" >/dev/null 2>&1 || true
    ui_msg "$(t x11app_title)" "$(t x11app_wait)"
    if ! x11_app_installed; then
      # su alcuni telefoni il passaggio Termux → installer di Android non parte:
      # si installa dalla cartella Download con il gestore file
      am start -a android.intent.action.VIEW_DOWNLOADS >/dev/null 2>&1 || true
      ui_msg "$(t x11app_title)" "$(t x11app_manual)"
    fi
  done
  if [[ -s $TOD_X11_DEB ]]; then
    local have_v deb_v
    have_v=$(pkg_version termux-x11-nightly)
    deb_v=$(dpkg-deb -f "$TOD_X11_DEB" Version 2>/dev/null) || deb_v=""
    if [[ -z $have_v ]] || { [[ -n $deb_v ]] && ! dpkg --compare-versions "$have_v" ge "$deb_v"; }; then
      run_step "termux-x11-nightly" apt_run "${APT_FLAGS[@]}" install --allow-downgrades "$TOD_X11_DEB" || true
    else
      log "termux-x11-nightly $have_v già aggiornato (release: ${deb_v:-?}): niente downgrade"
    fi
    rm -f "$TOD_X11_DEB"
  fi
  ok "$(t x11app_ok)"
  # già installata ma nella variante lenta? proponi il cambio
  # (non dopo il ripiego: la sharedUid su questo telefono non si installa)
  if [[ $variant == shareduid && $(x11_variant) == shareduid && $(x11_uid_status) == separate ]]; then
    x11_switch_shared || true
  fi
}

x11_switch_shared() { # interattivo: sostituisce Termux:X11 normale con la sharedUid
  if [[ $(x11_variant) != shareduid ]]; then warn "$(t x11_shared_na)"; return 1; fi
  if [[ $(x11_uid_status) == shared ]]; then ok "$(t x11_shared_ok)"; return 0; fi
  ui_yesno "$(t x11_shared_title)" "$(t x11_shared_text)" y || return 0
  # niente intent di disinstallazione diretto (serve un permesso): apro la pagina dell'app
  am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:com.termux.x11 >/dev/null 2>&1 || true
  ui_msg "$(t x11_shared_title)" "$(t x11_shared_wait)"
  rm -f "$TOD_X11_APK"
  x11_app_ensure
}

x11_cli() { # tod x11 [status|shared]
  case ${1:-status} in
    status) info "Termux:X11: $(x11_uid_status) (variante consigliata: $(x11_variant))" ;;
    shared) x11_switch_shared ;;
    *) die "tod x11 [status|shared]" ;;
  esac
}

# ----------------------------------------------------------------------------
#  Preferenze Termux:X11 da riga di comando (solo le chiavi che esistono davvero)
# ----------------------------------------------------------------------------
x11_prefs_filter() { # x11_prefs_filter "<output di 'list'>" chiave=valore... → quelle supportate
  local avail=$1 kv key
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    if grep -Eq "^\"?${key}\"?[[:space:]]*[=:]" <<<"$avail"; then printf '%s\n' "$kv"; fi
  done
}

x11_apply_prefs() {
  have termux-x11-preference || return 0
  local avail
  # attenzione: senza activity aperta il tool resta appeso → timeout
  if ! avail=$(timeout 10 termux-x11-preference list 2>/dev/null); then
    log "prefs: elenco non disponibile (activity chiusa?)"
    return 1
  fi
  local -a want=(
    fullscreen=true
    keepScreenOn=true
    displayResolutionMode=native
    hideCutout=true
    dexMetaKeyCapture=true
    clipboardEnable=true
    "showAdditionalKbd=$(conf_get X11_EXTRA_KEYS false)"
  )
  local -a sel=()
  mapfile -t sel < <(x11_prefs_filter "$avail" "${want[@]}")
  # termux-x11-preference vuole chiave:valore; con chiave=valore stampava l'uso e non applicava niente
  # (dexMetaKeyCapture e hideCutout erano rimasti false: 28 ottobre)
  sel=("${sel[@]/=/:}")
  local out kv bad=""
  if ((${#sel[@]})) && ! out=$(timeout 10 termux-x11-preference "${sel[@]}" 2>&1); then
    # tutte insieme non sono passate (S20+, 17 ottobre): una per volta, per sapere quale e salvare le altre
    log "prefs: applicazione fallita tutte insieme: ${out:-tempo scaduto}"
    for kv in "${sel[@]}"; do
      if ! out=$(timeout 10 termux-x11-preference "$kv" 2>&1); then bad+="$kv (${out:-tempo scaduto}) "; fi
    done
    if [[ -n $bad ]]; then log "prefs: non applicate: $bad"; fi
    # quelle che contano: schermo intero e risoluzione dello schermo
    if [[ $bad == *fullscreen=* || $bad == *displayResolutionMode=* ]]; then return 1; fi
  fi
  log "prefs Termux:X11: ${sel[*]:-nessuna}"
}

# ----------------------------------------------------------------------------
#  DPI e scala adattivi: lo stesso desktop va bene sul telefono, a 1080p e in 4K
# ----------------------------------------------------------------------------
# display_classify L A → "dpi scala tipo"   (pura, testabile)
display_classify() {
  local w=$1 h=$2 long short ar
  if (( w >= h )); then long=$w short=$h; else long=$h short=$w; fi
  if (( short <= 0 )); then echo "96 1 unknown"; return 0; fi
  ar=$((long * 100 / short))
  if (( ar >= 205 && ar <= 230 && short >= 1000 && long <= 3300 )); then
    # pannello del telefono (19.5:9 ~ 21:9, es. 3120x1440 o 2340x1080)
    if (( short >= 1400 )); then echo "200 1 phone"; else echo "160 1 phone"; fi
  elif (( short >= 2000 )); then echo "96 2 uhd"   # 4K / 5K2K → scala 2x
  elif (( short >= 1600 )); then echo "144 1 hidpi"
  elif (( short >= 1400 )); then echo "120 1 qhd"  # 1440p, ultrawide 3440x1440
  else echo "108 1 fhd"; fi   # monitor 1080p: 112%, testo ben leggibile da scrivania
}

display_current_res() { # WxH dello schermo X corrente
  local r=""
  if have xrandr; then
    r=$(xrandr --current 2>/dev/null | sed -n 's/.*current \([0-9][0-9]*\) x \([0-9][0-9]*\).*/\1x\2/p' | sed -n 1p) || r=""
  fi
  if [[ -z $r ]] && have xdpyinfo; then
    r=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ && !d {print $2; d = 1}') || r=""
  fi
  printf '%s' "$r"
}

display_tune() { # da eseguire dentro la sessione (hook di avvio)
  local mode res="" dpi scale kind
  mode=$(conf_get DPI auto)
  if [[ $mode =~ ^[0-9]+$ ]]; then
    dpi=$mode scale=$(conf_get SCALE 1) kind=manual
  else
    res=$(display_current_res)
    if [[ ! $res =~ ^([0-9]+)x([0-9]+)$ ]]; then log "display: risoluzione sconosciuta"; return 0; fi
    read -r dpi scale kind <<<"$(display_classify "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"
  fi
  log "display: ${res:-manuale} → dpi=$dpi scala=$scale ($kind)"
  case $(conf_get DE xfce) in
    xfce)
      have xfconf-query || return 0
      xfconf-query -c xsettings -p /Xft/DPI -n -t int -s "$dpi" || true
      xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s "$scale" || true
      look_scale_apply "$dpi" || true
      if [[ $scale == 2 ]]; then
        xfconf-query -c xfwm4 -p /general/theme -n -t string -s Default-xhdpi || true
      elif [[ $(xfconf-query -c xfwm4 -p /general/theme 2>/dev/null || true) == Default-xhdpi ]]; then
        xfconf-query -c xfwm4 -p /general/theme -s Default || true
      fi
      ;;
  esac
}

display_cli() { # tod display [auto|<dpi>] [scala]
  local v=${1:-}
  case $v in
    "") info "DPI=$(conf_get DPI auto) SCALE=$(conf_get SCALE 1) · $(t display_res): $(DISPLAY=:0 display_current_res || true)" ;;
    auto) conf_set DPI auto; ok "$(t display_set auto)" ;;
    tune) DISPLAY=${DISPLAY:-:0} display_tune ;;
    *)
      [[ $v =~ ^[0-9]{2,3}$ ]] || die "$(t display_bad "$v")"
      conf_set DPI "$v"
      conf_set SCALE "${2:-1}"
      ok "$(t display_set "$v")"
      ;;
  esac
  if x11_running && [[ $v != tune ]]; then DISPLAY=:0 display_tune || true; fi
}
