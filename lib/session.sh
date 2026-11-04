# shellcheck shell=bash
# =============================================================================
#  Sessione desktop: avvio/arresto pulito, audio, hook all'interno della sessione
# =============================================================================

# PulseAudio gira con XDG_RUNTIME_DIR=$TMPDIR, la stessa cartella della sessione grafica:
# altrimenti il socket finisce altrove e le app del desktop non lo trovano.
audio_socket() { printf 'unix:%s/pulse/native' "$TMPDIR"; }
audio_pactl() { XDG_RUNTIME_DIR=$TMPDIR PULSE_SERVER=$(audio_socket) pactl "$@"; }
audio_running() { XDG_RUNTIME_DIR=$TMPDIR pulseaudio --check 2>/dev/null; }

audio_start() {
  have pulseaudio || return 0
  if ! audio_running; then
    # un demone partito senza XDG_RUNTIME_DIR (o avviato da un client) è invisibile al desktop
    pulseaudio --kill >/dev/null 2>&1 || true
    if ! XDG_RUNTIME_DIR=$TMPDIR pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1; then
      warn "$(t audio_fail)"
      return 0
    fi
  fi
  if audio_ensure; then return 0; fi
  # Visto sul telefono (Android 17): un demone vivo a cui Android rifiuta ogni uscita
  # (AudioFlinger "could not create track", status -1) mentre uno nuovo funziona.
  # Si riavvia una volta, invece di restare muti su "Dummy Output".
  log "audio: nessuna uscita vera, riavvio PulseAudio"
  audio_kill
  if XDG_RUNTIME_DIR=$TMPDIR pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 && audio_ensure; then return 0; fi
  warn "$(t audio_fail)"
}

audio_kill() {
  XDG_RUNTIME_DIR=$TMPDIR pulseaudio --kill >/dev/null 2>&1 || true
  pulseaudio --kill >/dev/null 2>&1 || true
  sleep 1
}

audio_module_ids() { audio_pactl list short modules 2>/dev/null | awk -v m="$1" '$2 == m {print $1}' || true; }

audio_ensure() { # modulo TCP per il container, un'uscita vera, niente sospensione
  local i want have_a have_s m
  for ((i = 0; i < 20; i++)); do
    if audio_pactl info >/dev/null 2>&1; then break; fi
    sleep 0.25
  done
  audio_pactl info >/dev/null 2>&1 || return 1
  if [[ -z $(audio_module_ids module-native-protocol-tcp) ]]; then
    audio_pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 >/dev/null 2>&1 || true
  fi
  # su Android l'uscita sospesa spesso non si risveglia più
  for m in $(audio_module_ids module-suspend-on-idle); do audio_pactl unload-module "$m" >/dev/null 2>&1 || true; done
  want=$(conf_get AUDIO_SINK auto)
  have_a=$(audio_module_ids module-aaudio-sink)
  have_s=$(audio_module_ids module-sles-sink)
  case $want in
    sles)
      for m in $have_a; do audio_pactl unload-module "$m" >/dev/null 2>&1 || true; done
      if [[ -z $have_s ]]; then audio_pactl load-module module-sles-sink >/dev/null 2>&1 || true; fi
      ;;
    aaudio)
      for m in $have_s; do audio_pactl unload-module "$m" >/dev/null 2>&1 || true; done
      if [[ -z $have_a ]]; then audio_pactl load-module module-aaudio-sink >/dev/null 2>&1 || true; fi
      ;;
  esac
  if [[ -z $(audio_sinks) ]]; then # nessuna uscita vera: prima AAudio, poi OpenSL ES
    audio_pactl load-module module-aaudio-sink >/dev/null 2>&1 ||
      audio_pactl load-module module-sles-sink >/dev/null 2>&1 || true
  fi
  m=$(audio_sinks | sed -n 1p)
  if [[ -z $m ]]; then return 1; fi
  audio_pactl set-default-sink "$m" >/dev/null 2>&1 || true
  log "audio: uscita $m ($(audio_module_ids module-aaudio-sink | grep -q . && echo AAudio || echo 'OpenSL ES'))"
}

audio_sinks() { audio_pactl list short sinks 2>/dev/null | awk '$2 != "auto_null" {print $2}' || true; }

audio_tone() { # 1 secondo a 440 Hz, volume moderato (u8, 16 kHz, mono)
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 16000; i++) printf "%c", 128 + int(50 * sin(i * 6.2831853 * 440 / 16000)) }'
}

audio_test() {
  local r1=ko r2=-
  audio_start
  info "$(t audio_test_native)"
  if audio_tone | XDG_RUNTIME_DIR=$TMPDIR PULSE_SERVER=$(audio_socket) pacat --raw --format=u8 --rate=16000 --channels=1 2>>"$TOD_LOG"; then r1=ok; fi
  if cx_installed; then
    info "$(t audio_test_cx)"
    r2=ko
    # la nota passa da un file nella /tmp condivisa: lo stdin di cx_root è già lo script
    audio_tone >"$TMPDIR/tod-tone.raw"
    if cx_root /tmp/tod-tone.raw <<'EOF'; then r2=ok; fi
PULSE_SERVER=127.0.0.1 pacat --raw --format=u8 --rate=16000 --channels=1 "$1"
EOF
    rm -f "$TMPDIR/tod-tone.raw"
  fi
  log "audio test: nativo=$r1 container=$r2"
  printf '  %-12s %s\n' "$(t audio_lbl_native)" "$r1" "$(t audio_lbl_cx)" "$r2"
  info "$(t audio_test_ask)"
}

audio_status() {
  local m
  if ! audio_running; then printf '  %s\n' "$(t stopped)"; return 0; fi
  printf '  %-12s %s\n' "$(t audio_lbl_out)" "$(audio_sinks | tr '\n' ' ')"
  if [[ -n $(audio_module_ids module-aaudio-sink) ]]; then m=AAudio
  elif [[ -n $(audio_module_ids module-sles-sink) ]]; then m="OpenSL ES"
  else m="—"; fi
  printf '  %-12s %s\n' "Driver" "$m"
  printf '  %-12s %s\n' "Container" "$([[ -n $(audio_module_ids module-native-protocol-tcp) ]] && echo "TCP 127.0.0.1 ok" || t missing)"
  local inputs
  # senza risposta da PulseAudio niente "Errore inatteso": pipefail + wc -l fallivano insieme
  inputs=$(audio_pactl list short sink-inputs 2>/dev/null) || inputs=""
  printf '  %-12s %s\n' "$(t audio_lbl_streams)" "$(grep -c . <<<"$inputs" || true)"
}

audio_cli() { # tod audio [status|test|restart|uscita auto|aaudio|sles]
  case ${1:-status} in
    status) audio_status ;;
    test) audio_test ;;
    restart)
      audio_kill
      audio_start
      audio_status
      ;;
    uscita | sink | output)
      [[ ${2:-} =~ ^(auto|aaudio|sles)$ ]] || die "tod audio uscita auto|aaudio|sles"
      conf_set AUDIO_SINK "$2"
      audio_ensure || warn "$(t audio_fail)"
      audio_status
      ;;
    *) die "tod audio [status|test|restart|uscita auto|aaudio|sles]" ;;
  esac
}

session_running() { x11_running; }

session_x_args() { # argomenti del server X (uno per riga), senza -xstartup
  local dpi
  dpi=$(conf_get DPI auto)
  if [[ ! $dpi =~ ^[0-9]+$ ]]; then dpi=96; fi   # il valore reale lo imposta l'hook
  printf '%s\n' :0 -ac -dpi "$dpi"
  if [[ $(conf_get X11_LEGACY 0) == 1 ]]; then echo -legacy-drawing; fi
  if [[ $(conf_get X11_BGRA 0) == 1 ]]; then echo -force-bgra; fi
}

session_prepare() { # tutto ciò che serve prima del desktop: file, audio, GPU
  rm -f "$TMPDIR/tod-desktop-pronto"   # lo riscrive l'hook a desktop sistemato
  desktop_tune_files
  files_user_home_setup || true   # nuovi file nascosti di Termux anche nella home dell'utente
  files_hide_technical || true    # .hidden scritti dal vero Termux (dal proot finirebbero in una copia)
  if have termux-wake-lock; then termux-wake-lock || true; fi
  audio_start
  gpu_env_export   # (azzera prima eventuali variabili GPU dell'ambiente chiamante)
  if [[ ${TOD_NEEDS_VIRGL:-0} == 1 || $(conf_get CX_GPU_PROFILE) == virgl ]]; then
    virgl_start || warn "$(t virgl_fail)"
  fi
}

session_adopt() { # il desktop sul server X già acceso (schermata di benvenuto): niente schermo nero
  [[ $(conf_get INSTALLED 0) == 1 ]] || die "$(t not_installed)"
  if ! x11_running; then session_start; return; fi
  session_prepare
  # come farebbe termux-x11 con -xstartup: alla chiusura della sessione xstartup spegne tutto
  XDG_RUNTIME_DIR=$TMPDIR DISPLAY=:0 setsid nohup "$PREFIX/bin/tod" _xstartup >>"$TOD_STATE_DIR/session.log" 2>&1 </dev/null &
  x11_open_activity
  ok "$(t session_started "$(conf_get DE xfce)" "${TOD_GPU_PROFILE:-$(conf_get GPU_PROFILE llvmpipe)}")"
}

session_start() {
  [[ $(conf_get INSTALLED 0) == 1 ]] || die "$(t not_installed)"
  if session_running; then
    info "$(t session_already)"
    x11_open_activity
    return 0
  fi
  x11_cleanup_stale
  session_prepare
  local -a args=()
  mapfile -t args < <(session_x_args)
  args+=(-xstartup "$PREFIX/bin/tod _xstartup")
  # nuova sessione di processo: chiudere la scheda di Termux non uccide il desktop
  local -a launch=(nohup)
  if have setsid; then launch=(setsid nohup); fi
  # X11_GLAMOR=1: composizione X con la GPU nel server (serve la Termux:X11 con glamor, ~/src/x11-build);
  # X11_MISURA=1: il server scrive ogni 5 s nel logcat (LorieNative) quanto costa ogni tipo di richiesta
  local glamor=0 misura
  if x11_glamor_ok; then glamor=1; fi
  misura=$(conf_get X11_MISURA 0)
  local try started=0
  for try in 1 2 3; do
    # azzerato e poi aperto in coda (>>): così session_log_cap può accorciarlo mentre il server scrive
    : >"$TOD_STATE_DIR/session.log"
    XDG_RUNTIME_DIR=$TMPDIR TERMUX_X11_GLAMOR=$glamor TERMUX_X11_MISURA=$misura \
      "${launch[@]}" termux-x11 "${args[@]}" >>"$TOD_STATE_DIR/session.log" 2>&1 </dev/null &
    if x11_wait_socket "${TOD_X11_WAIT:-30}"; then
      x11_open_activity
      # con glamor il server usa la GPU quando la finestra si apre: deve restare acceso
      if (( ! glamor )) || x11_resta_vivo "${TOD_X11_VIVO:-4}"; then started=1; break; fi
      log "sessione: la Termux:X11 con glamor si è chiusa appena aperta. Server X: $(tail -n 15 "$TOD_STATE_DIR/session.log" 2>/dev/null | tr '\n' ' ')"
    else
      # l'output del server finisce nel log: è quello che serve per capire il perché
      log "sessione: avvio $try fallito. Server X: $(tail -n 15 "$TOD_STATE_DIR/session.log" 2>/dev/null | tr '\n' ' ')"
    fi
    x11_kill
    if (( glamor )); then
      # questo telefono non regge glamor: si riparte senza, e così per sempre (X11_GLAMOR_NO)
      glamor=0
      conf_set X11_GLAMOR_NO 1
      warn "$(t x11_glamor_off)"
    elif (( try >= 2 )); then
      break
    fi
  done
  if (( ! started )); then
    err "$(t x11_no_socket)"
    tail -n 20 "$TOD_STATE_DIR/session.log" >&2 || true
    return 1
  fi
  if [[ $(x11_uid_status) == separate ]]; then warn "$(t x11_shared_warn)"; fi
  if [[ $(conf_get X11_PREFS_APPLIED) != "$TOD_VERSION" ]]; then
    sleep 2
    # segnate come fatte solo se riuscite: sennò si riprova al prossimo avvio (S20+: "applicazione fallita")
    if x11_apply_prefs; then conf_set X11_PREFS_APPLIED "$TOD_VERSION"; fi
  fi
  ok "$(t session_started "$(conf_get DE xfce)" "${TOD_GPU_PROFILE:-$(conf_get GPU_PROFILE llvmpipe)}")"
}

session_user_env() { # la sessione grafica gira come l'utente scelto, nella sua home
  local u uh
  u=$(conf_get USER_NAME)
  export TOD_TERMUX_HOME=${TOD_TERMUX_HOME:-$HOME}
  uh=$(files_user_home) || return 0
  [[ -d $uh ]] || return 0
  export HOME=$uh USER=$u LOGNAME=$u TOD_USER=$u TOD_USER_HOME=$uh
  # /data/data & co.: niente "Permesso negato" nel file manager (vedi files_fs_map)
  if [[ -d $(files_fs_map_dir) ]]; then export TOD_FS_MAP; TOD_FS_MAP=$(files_fs_map_dir); fi
  export TOD_USER_FULLNAME
  TOD_USER_FULLNAME=$(conf_get USER_FULLNAME "${u^}")
  # il nome utente lo dà tod-gettext.so (getpwuid): caricata anche se la lingua è l'inglese
  if [[ -f $LINGUA_SO && ":${LD_PRELOAD:-}:" != *":$LINGUA_SO:"* ]]; then
    export LD_PRELOAD="$LINGUA_SO${LD_PRELOAD:+:$LD_PRELOAD}"
  fi
  # dischi USB: /media/usb/<nome> come cartelle vere in ogni programma (share/usb/lkl/tod-fs.c)
  local fs_so="$TOD_TERMUX_HOME/.local/share/tod-usb/tod-fs.so"
  if [[ $(conf_get USB_DISCHI 1) == 1 && -f $fs_so && ":${LD_PRELOAD:-}:" != *":$fs_so:"* ]]; then
    export LD_PRELOAD="$fs_so${LD_PRELOAD:+:$LD_PRELOAD}"
  fi
  cd "$uh" || true
}

session_xstartup() { # eseguito da termux-x11 al posto del classico -xstartup "xfce4-session"
  local de cmd
  export XDG_RUNTIME_DIR=$TMPDIR DISPLAY=${DISPLAY:-:0}
  # link e file si aprono con le app del desktop, non di Android (vedi share/bin/xdg-open)
  if [[ ":$PATH:" != *":$TOD_ROOT/share/bin:"* ]]; then export PATH="$TOD_ROOT/share/bin:$PATH"; fi
  gpu_env_export
  de=$(conf_get DE xfce)
  cmd=$(desktop_start_cmd "$de") || cmd=xfce4-session
  export XDG_CURRENT_DESKTOP=XFCE   # le app "OnlyShowIn=XFCE" (Impostazioni...) compaiono nei menu
  lingua_env
  session_user_env
  export PULSE_SERVER
  PULSE_SERVER=$(audio_socket)
  log "xstartup: $de ($cmd) profilo=${TOD_GPU_PROFILE:-?} lingua=${TOD_GETTEXT_LANG:-en}"
  local srv ora
  srv=$(x11_server_pids | sort | tr '\n' ' ')
  dbus-launch --exit-with-session "$cmd" || true
  # il server X di questa sessione si è chiuso da solo e ne è già partito un altro (session_start riparte
  # senza glamor): l'arresto spegnerebbe quello nuovo
  ora=$(x11_server_pids | sort | tr '\n' ' ')
  if [[ -n ${ora// /} && $ora != "$srv" ]]; then
    log "sessione chiusa, ma il server X è un altro: niente arresto"
    return 0
  fi
  # "Esci" dal menu: si spegne tutto come un PC (audio, server X, finestra) e si torna ad Android.
  # Staccato, perché il server X di cui siamo figli sta per chiudersi.
  log "sessione chiusa dal desktop: arresto completo"
  setsid nohup "$PREFIX/bin/tod" stop >/dev/null 2>&1 </dev/null &
}

updates_start() { # Aggiornamenti: controllo in sottofondo (dopo 2 minuti, poi ogni 6 ore) e avviso
  [[ $(conf_get AGGIORNAMENTI_AUTO 1) == 1 ]] || return 0
  (low_prio setsid python3 "$TOD_ROOT/share/tod-updates.py" controlla --ciclo </dev/null \
    >>"$TOD_STATE_DIR/updates.log" 2>&1 &)
}

# --- modalità sviluppo (SVILUPPO=1, `tod sviluppo on|off`): solo per chi lavora sul progetto ----
# All'avvio del desktop: il ponte per lo sviluppo (tools/termux-bridge, comandi di Android dal proot)
# e ADB senza fili ricollegato da solo, se il Debug wireless è acceso (la porta cambia ogni volta).
dev_tools_start() {
  [[ $(conf_get SVILUPPO 0) == 1 ]] || return 0
  local bridge="$TOD_ROOT/tools/termux-bridge" st="$TOD_STATE_DIR"
  if [[ -f $bridge ]]; then
    (setsid env HOME="$(files_termux_home)" bash "$bridge" </dev/null >>"$st/bridge.log" 2>&1 &)
  fi
  if have adb; then (setsid "$PREFIX/bin/tod" _dev_adb </dev/null >>"$st/tod.log" 2>&1 &); fi
}

dev_adb_reconnect() { # in sottofondo: niente finestre, niente domande
  local s
  adb start-server >/dev/null 2>&1 || true
  s=$(adb_local_device) || s=""
  if [[ -z $s ]] && have nmap; then s=$(adb_find_connect_port) || s=""; fi
  if [[ -n $s ]]; then echo "$(date '+%F %T') sviluppo: ADB collegato ($s)"; else
    echo "$(date '+%F %T') sviluppo: ADB non collegato (Debug wireless spento o senza Wi-Fi)"; fi
}

dev_cli() { # tod sviluppo on|off
  case ${1:-} in
    on | si | sì) conf_set SVILUPPO 1; dev_tools_start ;;
    off | no) conf_set SVILUPPO 0 ;;
    *) die "tod sviluppo on|off" ;;
  esac
  ok "$(t dev_state "$(conf_get SVILUPPO 0)")"
}

session_log_cap() { # registri della sessione con un tetto: un'app che li riempie di errori portava session.log
  # a 265 MB e start.log a 49 MB (23 ottobre; le app aperte da barra e Start ereditano i loro registri)
  local f max=${SESSION_LOG_MAX:-5242880} n
  for f in "$TOD_STATE_DIR"/{session,barra,start}.log; do
    [[ -f $f ]] || continue
    n=$(stat -c %s "$f" 2>/dev/null || echo 0)
    ((n > max)) || continue
    # si tiene l'ultimo quinto; cat (non mv) perché i programmi della sessione lo tengono aperto in coda
    { printf '[tod] registro accorciato: tolti %s KB più vecchi\n' "$(((n - max / 5) / 1024))"; tail -c $((max / 5)) "$f"; } >"$f.tmp"
    cat "$f.tmp" >"$f"
    rm -f "$f.tmp"
  done
}

session_log_watch() { # ogni 5 minuti session_log_cap, finché c'è il server X; uno solo per sessione
  local pid=$TMPDIR/tod-registro.pid
  [[ -S $TMPDIR/.X11-unix/X0 ]] || return 0
  (
    echo "$BASHPID" >"$pid"
    while sleep "${SESSION_LOG_EVERY:-300}"; do
      [[ -S $TMPDIR/.X11-unix/X0 && $(cat "$pid" 2>/dev/null) == "$BASHPID" ]] || break
      session_log_cap
    done
  ) </dev/null >/dev/null 2>&1 &
}

session_old_daemons() { # i demoni di sessione delle accensioni di prima, chiusi prima di avviare i nuovi.
  # Da soli si chiudono quando il server X manca da un po', ma con "Esci" e subito l'icona della Termux:X11
  # il socket X0 torna prima (3 novembre: tre demoni del telefono con le chiamate a Termux:API triplicate,
  # tre tod-open-host, tre ponti, due controlli degli aggiornamenti). Per argomenti esatti, come orfani()
  # di tod-usb: mai un testo che può stare nel comando di qualcun altro. TOD_PROC: per i test
  local proc=${TOD_PROC:-/proc} f pid coda IFS=' '
  local -a argv
  # nei test, mai i processi veri (12 ottobre: un test ha chiuso il desktop di Pietro)
  if [[ -n ${TOD_TEST_RUN:-} && -z ${TOD_PROC:-} ]]; then return 0; fi
  local -A demoni=(
    ["$TOD_ROOT/share/tod-phone-status.py demone"]=1
    ["$TOD_ROOT/share/tod-open-host"]=1
    ["$TOD_ROOT/share/tod-updates.py controlla --ciclo"]=1
    ["$TOD_ROOT/tools/termux-bridge"]=1
  )
  for f in "$proc"/[0-9]*/cmdline; do
    pid=${f%/cmdline}
    pid=${pid##*/}
    if [[ $pid == "$$" || $pid == "$BASHPID" ]]; then continue; fi
    mapfile -d '' -t argv 2>/dev/null <"$f" || continue
    if ((${#argv[@]} < 2)); then continue; fi
    coda="${argv[*]:1}"
    if [[ -n ${demoni[$coda]:-} ]]; then
      log "sessione: chiudo ${coda##*/} rimasto da prima (pid $pid)"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
}

session_hook() { # autostart dentro il desktop: DPI per lo schermo attuale, env del container
  local t0=$SECONDS
  session_old_daemons || true
  display_tune || true
  # barra, Start e pannelli per primi, appena si conoscono i DPI (le loro proporzioni): il resto dopo.
  # Prima partivano dopo aspetto e cartelle, e sul S20+ il desktop restava a lungo senza barra
  if have python3 && [[ $(conf_get DE xfce) == xfce ]]; then look_barra_avvia || true; fi
  if [[ -x $PREFIX/bin/tod-start ]]; then
    (setsid "$PREFIX/bin/tod-start" --preload </dev/null >>"$TOD_STATE_DIR/start.log" 2>&1 &)
  fi
  # pannelli della barra (notifiche, volume...): in memoria, si aprono all'istante
  if have python3 && [[ -x $TOD_ROOT/share/tod-pannello ]]; then
    (setsid "$TOD_ROOT/share/tod-pannello" --preload </dev/null >>"$TOD_STATE_DIR/session.log" 2>&1 &)
  fi
  log "sessione: barra, Start e pannelli avviati dopo $((SECONDS - t0)) s"
  session_log_cap   # barra.log e start.log non si azzerano all'avvio
  session_log_watch
  look_session_apply || true
  files_session || true
  files_trust_launchers || true
  files_rename_css || true
  lingua_ripara || true   # lingua scelta ma traduzione mancante: si installa da sola, in sottofondo
  log "sessione: aspetto e cartelle pronti dopo $((SECONDS - t0)) s"
  # bordi invisibili per ridimensionare: la cornice disegnata è una riga (share/tod-edges.py)
  if [[ $(conf_get BORDI_INVISIBILI 1) == 1 ]] && have python3; then
    (setsid python3 "$TOD_ROOT/share/tod-edges.py" </dev/null >>"$TOD_STATE_DIR/session.log" 2>&1 &)
  fi
  # dischi USB (share/usb/tod-usb): servizio che li dà a tod-lkl e li mostra in Esplora file
  if [[ $(conf_get USB_DISCHI 1) == 1 && -x $TOD_TERMUX_HOME/.local/share/tod-usb/tod-lkl ]]; then
    (setsid bash "$TOD_ROOT/share/usb/tod-usb" sorveglia </dev/null >>"$TOD_STATE_DIR/usb.log" 2>&1 &)
  fi
  if cx_installed; then
    # link e file aperti dalle app di Debian → app del desktop (vedi share/tod-open-host)
    (setsid env TOD_CX_ROOTFS="$(cx_rootfs)" bash "$TOD_ROOT/share/tod-open-host" </dev/null \
      >>"$TOD_STATE_DIR/open-host.log" 2>&1 &)
    cx_sync_session_env || true
    cx_install_runner || true   # tod-run (e pkexec, se scelto) sempre aggiornati
    cx_sync_look || true
    cx_sync_apps || true
    # app di Debian senza proot (lib/diretto.sh): la prima volta installa libfakechroot, poi è un controllo
    (diretto_prepara || true) </dev/null >>"$TOD_STATE_DIR/session.log" 2>&1 &
  fi
  apt_shell_setup || true
  android_apps_sync || true
  phone_status_start || true
  dev_tools_start || true
  updates_start || true
  # XFCE_TUNED: versione dei ritocchi (2 = compositore acceso e ombre); cambiandola si riapplicano
  if [[ $(conf_get DE xfce) == xfce && $(conf_get XFCE_TUNED 0) != 2 ]]; then
    xfce_first_run || true
    conf_set XFCE_TUNED 2
  fi
  # desktop sistemato (icone, cartelle, aspetto): la schermata di benvenuto può scoprirlo
  : >"$TMPDIR/tod-desktop-pronto"
  log "sessione: avvio completo in $((SECONDS - t0)) s"
}

# --- primo avvio preparato durante l'installazione ------------------------------------------------
# Tema, icone, cartelle, barra e ritocchi di XFCE si scrivono con xfconf-query, che vuole xfconfd: con il
# desktop già acceso XFCE partiva con le impostazioni di fabbrica e le cambiava a vista (S20+, 17 ottobre).
# Qui un xfconfd privato (dbus-run-session) le scrive nei file prima del primo avvio; i programmi di XFCE
# sono finti, così nessuna barra o scrivania parte sullo schermo della schermata di benvenuto.
session_preseed() {
  [[ $(conf_get DE xfce) == xfce ]] || return 0
  if ! have dbus-run-session || ! have xfconf-query; then return 0; fi
  local stub c rc=0 sh
  sh=$(command -v sh) || sh=$PREFIX/bin/sh
  stub=$(mktemp -d "$TMPDIR/tod-preseed.XXXXXX")
  for c in xfce4-panel xfdesktop xfwm4 xfsettingsd xfce4-session thunar Thunar; do
    printf '#!%s\nexit 0\n' "$sh" >"$stub/$c"
    chmod 755 "$stub/$c"
  done
  # DISPLAY solo se c'è lo schermo (la schermata di benvenuto): serve a calcolare la scala giusta
  if x11_running; then
    PATH="$stub:$PATH" DISPLAY=:0 dbus-run-session -- "$PREFIX/bin/tod" _preseed || rc=$?
  else
    PATH="$stub:$PATH" dbus-run-session -- env -u DISPLAY "$PREFIX/bin/tod" _preseed || rc=$?
  fi
  rm -rf "$stub"
  return "$rc"
}

session_preseed_inner() { # dentro dbus-run-session: le stesse cose del primo hook, senza desktop
  files_user_home_setup || true
  session_user_env
  if [[ -n ${DISPLAY:-} ]]; then display_tune || true; fi
  look_session_apply || true
  files_session || true
  files_rename_css || true
  if [[ $(conf_get XFCE_TUNED 0) != 2 ]]; then
    xfce_first_run || true
    conf_set XFCE_TUNED 2
  fi
  log "primo avvio preparato (tema $(xfconf-query -c xsettings -p /Net/ThemeName 2>/dev/null || echo ?))"
}

termux_exit() { # dopo lo spegnimento (tod spegni) anche Termux, come "Exit" nella sua notifica (Pietro, 4 novembre:
  # "quando faccio Spegni non può fare anche exit da Termux?"): la Termux:X11 si chiude, poi il servizio di Termux
  # con tutte le sue sessioni, compresa questa. L'icona della Termux:X11 riaccende tutto (TodAvvio).
  # SPEGNI_TERMUX=0 in tod.conf: Termux resta aperto
  if [[ $(conf_get SPEGNI_TERMUX 1) != 1 ]]; then return 0; fi
  log "spegnimento: chiudo anche Termux"
  am broadcast --user 0 -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
  am startservice --user 0 -n com.termux/com.termux.app.TermuxService -a com.termux.service_stop >/dev/null 2>&1 || true
}

session_stop() {
  local p
  # dischi USB: prima i dati scritti sui dischi, poi servizio, macchina e centralino chiusi (sennò
  # sopravvivono alla sessione e si contendono la macchina con quelli della sessione dopo). Mai nei
  # test: agirebbe sui processi veri
  if [[ -z ${TOD_TEST_RUN:-} && -f $TOD_ROOT/share/usb/tod-usb ]]; then
    timeout 60 bash "$TOD_ROOT/share/usb/tod-usb" ferma >>"$TOD_STATE_DIR/usb.log" 2>&1 || true
  fi
  # le app di Debian (proot) prima del desktop, con qualche secondo per chiudersi bene
  pkill -TERM -f '(^|/)proot( |$)' 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -f '(^|/)proot( |$)' >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  for p in xfce4-session xfce4-panel xfdesktop xfwm4 xfsettingsd; do
    pkill -x "$p" 2>/dev/null || true
  done
  x11_kill
  virgl_stop
  pkill -f 'dbus-daemon.*--session' 2>/dev/null || true
  if [[ $(conf_get AUDIO_KEEP 0) != 1 ]]; then XDG_RUNTIME_DIR=$TMPDIR pulseaudio --kill 2>/dev/null || true; fi
  if have termux-wake-unlock; then termux-wake-unlock || true; fi
  sync   # come ogni spegnimento: tutto ciò che è in memoria va scritto
  ok "$(t session_stopped)"
}

session_status() {
  local s c a
  if session_running; then s="$C_G$(t running)$C_0"; else s="$C_DIM$(t stopped)$C_0"; fi
  if cx_installed; then c="$(cx_distro) · GPU $(conf_get CX_GPU_PROFILE '?')"; else c="—"; fi
  if have pulseaudio && audio_running; then a=$(t running); else a=$(t stopped); fi
  printf '%sTermux On DeX %s%s\n' "$C_BOLD" "$TOD_VERSION" "$C_0"
  printf '  %-12s %s\n' "$(t lbl_session)" "$s"
  printf '  %-12s %s\n' "Desktop" "$(conf_get DE xfce)"
  printf '  %-12s %s (stack %s)\n' "GPU" "$(conf_get GPU_PROFILE '?')" "$(gpu_stack)"
  printf '  %-12s %s\n' "$(t lbl_container)" "$c"
  printf '  %-12s %s\n' "Audio" "$a"
  printf '  %-12s DPI %s · VSync %s\n' "$(t lbl_display)" "$(conf_get DPI auto)" "$(conf_get VSYNC on)"
}
