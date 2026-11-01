# shellcheck shell=bash
# =============================================================================
#  Benvenuto grafico (share/tod-benvenuto.py), come la prima accensione di un Mac.
#
#  Termux fa solo il minimo (aggiornamento, ADB, Termux:X11 e Termux:API); appena
#  c'è Termux:X11 si apre la schermata di benvenuto: lingua, account, aspetto, app.
#  Intanto, dietro, l'installazione va avanti e la schermata ne mostra l'avanzamento
#  (e gli errori, con Riprova/Esci). Alla fine "Inizia" apre il desktop.
#  Parlano con tre file in $BV_DIR: stato (da qui), risposte.json e comando (da lì).
#  Se la schermata non parte si continua nel terminale, con le domande di sempre.
# =============================================================================

BV_ON=0
BV_PID=""
BV_LAST=""
BV_DIR="$TMPDIR/tod-benvenuto"
BV_PKGS="python pygobject gtk3 ttf-dejavu"   # GTK 3 di Termux e un carattere: niente desktop ancora

bv_wanted() { # installazione nuova, con l'interfaccia a schermo intero
  (( TUI_ON )) && [[ $TOD_YES != 1 && $(conf_get INSTALLED 0) != 1 && $(conf_get BENVENUTO 1) == 1 ]]
}

bv_alive() { [[ -n $BV_PID ]] && kill -0 "$BV_PID" 2>/dev/null; }

bv_app_list() { # il catalogo delle app per la schermata: "id|nome|on" per riga
  local -a cat=()
  local i
  mapfile -t cat < <(apps_catalog_args)
  for ((i = 0; i + 2 < ${#cat[@]}; i += 3)); do printf '%s|%s|%s\n' "${cat[i]}" "${cat[i + 1]}" "${cat[i + 2]}"; done
}

bv_screen_size() { # → "larghezza altezza" dello schermo di Termux:X11
  DISPLAY=:0 xrandr --current 2>/dev/null | sed -n 's/.*current \([0-9]*\) x \([0-9]*\).*/\1 \2/p' | sed -n 1p
}

bv_wait_screen() { # Termux:X11 collegato e risoluzione stabile (all'inizio il server ne ha una provvisoria)
  local i last="" cur same=0
  for ((i = 0; i < 20; i++)); do
    cur=$(bv_screen_size) || cur=""
    if [[ -n $cur && $cur == "$last" ]]; then
      same=$((same + 1))
      if (( same >= 2 )); then break; fi
    else
      same=0
    fi
    last=$cur
    pausa 1
  done
  log "benvenuto: schermo ${cur:-sconosciuto}"
}

bv_sfondo() { # lo schermo di X subito nel blu della schermata: Termux:X11 non si apre mai nero. Resta
  # collegato finché c'è $BV_DIR/sfondo (senza client il server X si azzera e lo sfondo torna nero)
  : >"$BV_DIR/sfondo"
  DISPLAY=:0 setsid nohup python3 - "$BV_DIR/sfondo" >/dev/null 2>&1 </dev/null <<'EOF' &
import ctypes, ctypes.util, os, sys, time
x = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so")
x.XOpenDisplay.restype = ctypes.c_void_p
x.XOpenDisplay.argtypes = [ctypes.c_char_p]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XSetWindowBackground.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong]
x.XClearWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x.XFlush.argtypes = [ctypes.c_void_p]
d = x.XOpenDisplay(None)
if d:
    r = x.XDefaultRootWindow(d)
    x.XSetWindowBackground(d, r, 0x0b1424)   # il colore d'inizio della sfumatura di tod-benvenuto.py
    x.XClearWindow(d, r)
    x.XFlush(d)
    fine = time.time() + 180
    while os.path.exists(sys.argv[1]) and time.time() < fine:
        time.sleep(0.3)
EOF
}

bv_prefs() { # schermo intero e risoluzione nativa già da qui: il desktop poi parte giusto
  local i
  for ((i = 0; i < 3; i++)); do
    if x11_apply_prefs; then conf_set X11_PREFS_APPLIED "$TOD_VERSION"; return 0; fi
    pausa 3
  done
  return 0
}

bv_start() { # apre la schermata; 0 = aperta (da qui in poi l'installazione si vede lì)
  local w h scale=1 mode=""
  local -a args=()
  mkdir -p "$BV_DIR"
  rm -f "$BV_DIR/comando" "$BV_DIR/stato" "$TMPDIR/tod-desktop-pronto"
  bv_app_list >"$BV_DIR/app"
  if [[ $(conf_get BV_RISPOSTE 0) == 1 ]]; then mode=--avanzamento; else rm -f "$BV_DIR/risposte.json"; fi
  if ! x11_running; then
    x11_cleanup_stale
    # lo stesso server che userà il desktop: alla fine il desktop parte qui, senza chiudere Termux:X11
    mapfile -t args < <(session_x_args)
    XDG_RUNTIME_DIR=$TMPDIR setsid nohup termux-x11 "${args[@]}" >"$TOD_STATE_DIR/session.log" 2>&1 </dev/null &
    if ! x11_wait_socket "${TOD_X11_WAIT:-30}"; then log "benvenuto: il server X non è partito"; return 1; fi
  fi
  local t0=$SECONDS
  bv_sfondo
  x11_open_activity
  bv_wait_screen
  read -r w h <<<"$(bv_screen_size)" || true
  # schermi molto densi (4K, telefono in verticale ad alta risoluzione): tutto il doppio
  if [[ ${w:-0} =~ ^[0-9]+$ && ${h:-0} =~ ^[0-9]+$ ]] && (( (w < h ? w : h) >= 1440 )); then scale=2; fi
  env -u LD_PRELOAD DISPLAY=:0 GDK_SCALE=$scale NO_AT_BRIDGE=1 TOD_BV_LANG="$TOD_LANG" TOD_BV_LINGUA="$(lingua_code)" \
    TOD_BV_DISPOSITIVO="${DEV_NAME:-$DEV_MODEL}" TOD_BV_NOME="$(conf_get USER_FULLNAME)" \
    TOD_BV_UTENTE="$(conf_get USER_NAME)" TOD_BV_PRONTO="$TMPDIR/tod-desktop-pronto" \
    setsid nohup python3 "$TOD_ROOT/share/tod-benvenuto.py" "$BV_DIR" $mode \
    >"$TOD_STATE_DIR/benvenuto.log" 2>&1 </dev/null &
  BV_PID=$!
  log "benvenuto: schermata avviata $((SECONDS - t0)) s dopo l'apertura di Termux:X11"
  # schermo intero e risoluzione nativa dopo, con la schermata già lì (segue da sola i cambi di misura):
  # prima, sul S20+ le preferenze una per volta tenevano lo schermo nero a lungo
  bv_prefs
  log "benvenuto: preferenze di Termux:X11 in $((SECONDS - t0)) s"
  pausa 2
  rm -f "$BV_DIR/sfondo"   # da qui lo sfondo lo tiene la schermata (un client collegato: X non si azzera)
  if ! bv_alive; then
    log "benvenuto: la schermata si è chiusa subito: $(tail -n 5 "$TOD_STATE_DIR/benvenuto.log" 2>/dev/null | tr '\n' ' ')"
    BV_PID=""
    return 1
  fi
  BV_ON=1
  log "benvenuto: aperta (pid $BV_PID, schermo ${w:-?}x${h:-?}, scala $scale)"
}

bv_note() { # bv_note percentuale id_del_passo [fase] [errore]   (stato per la schermata)
  (( BV_ON )) || return 0
  local s
  # solo l'id del passo: i nomi da mostrare (comprensibili, senza termini tecnici) li ha la schermata
  s="pct=$1"$'\n'"passo=$2"$'\n'"fase=${3:-lavoro}"$'\n'
  if [[ -n ${4:-} ]]; then s+="errore=$4"$'\n'"log=$TOD_LOG"$'\n'; fi
  if [[ $s == "$BV_LAST" ]]; then return 0; fi
  BV_LAST=$s
  printf '%s' "$s" >"$BV_DIR/.stato" 2>/dev/null || return 0
  mv -f "$BV_DIR/.stato" "$BV_DIR/stato" 2>/dev/null || true
}

bv_command() { # bv_command parola... → aspetta dalla schermata una di queste parole; 1 = schermata chiusa
  local c
  rm -f "$BV_DIR/comando"
  while bv_alive; do
    if [[ -s $BV_DIR/comando ]]; then
      read -r c <"$BV_DIR/comando" || c=""
      rm -f "$BV_DIR/comando"
      if [[ " $* " == *" $c "* ]]; then printf '%s' "$c"; return 0; fi
    fi
    pausa 0.5
  done
  return 1
}

bv_error_choice() { # bv_error_choice id titolo percentuale → "retry" o "quit" (Riprova/Esci nella schermata)
  local c
  bv_note "$3" "$1" errore "$1"
  if c=$(bv_command riprova esci); then
    BV_LAST=""
    if [[ $c == riprova ]]; then echo retry; else echo quit; fi
    return 0
  fi
  BV_ON=0   # schermata chiusa: si decide nel terminale
  tui_error_popup "$2" 1
}

bv_answers() { # aspetta le scelte della schermata e le mette nella configurazione
  (( BV_ON )) || return 0
  if [[ $(conf_get BV_RISPOSTE 0) == 1 ]]; then return 0; fi
  local f="$BV_DIR/risposte.json" v id ok_ids=" " apps=""
  while [[ ! -s $f ]]; do
    if ! bv_alive; then
      BV_ON=0
      tui_gauge_close
      installer_questions_main
      return 0
    fi
    tui_gauge_update "$(tui_overall "" 0)" "$(tui_render "$(t bv_waiting)")"
    pausa 1
  done
  v=$(jq -r '.utente // ""' "$f") || v=""
  if files_user_valid "$v"; then conf_set USER_NAME "$v"; fi
  v=$(jq -r '.nome // ""' "$f" | tr -d '\n\r') || v=""
  if [[ -n $v ]]; then conf_set USER_FULLNAME "$v"; fi
  v=$(jq -r '.lingua // ""' "$f") || v=""
  if [[ $v =~ ^[a-z]{2}$ ]]; then conf_set LINGUA "$v"; fi
  v=$(jq -r '.tema // ""' "$f") || v=""
  if [[ $v == chiaro || $v == scuro ]]; then conf_set TEMA "$v"; fi
  v=$(jq -r '.accento // ""' "$f") || v=""
  if [[ -n $v && -n ${LOOK_ACCENTS[$v]:-} ]]; then conf_set ACCENTO "${LOOK_ACCENTS[$v]}"; fi
  while IFS='|' read -r id _; do ok_ids+="$id "; done <"$BV_DIR/app"
  while read -r id; do
    if [[ -n $id && $ok_ids == *" $id "* ]]; then apps+="$id "; fi
  done < <(jq -r '.app[]? // empty' "$f")
  conf_set APPS "$apps"
  conf_set BV_RISPOSTE 1
  log "benvenuto: risposte salvate (utente $(conf_get USER_NAME), lingua $(conf_get LINGUA), app: ${apps:-nessuna})"
}

bv_finish() { # fine: "Tutto pronto" e il pulsante Inizia; 0 = si apre il desktop
  # Dopo "Inizia" la schermata resta davanti ("Avvio del desktop…") finché l'hook della sessione non
  # ha sistemato icone, cartelle e aspetto ($TMPDIR/tod-desktop-pronto): poi si chiude da sola.
  (( BV_ON )) || return 1
  bv_note 100 "" fatto
  bv_command avvia >/dev/null || true
  BV_ON=0
  return 0
}
