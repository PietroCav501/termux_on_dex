# shellcheck shell=bash
# =============================================================================
#  Installazione "premium": interfaccia a schermo intero (dialog)
#   - tema scuro con accento ciano (DIALOGRC generato)
#   - barra di avanzamento complessiva + elenco dei passi con il loro stato
#   - avanzamento reale di apt, pacchetto per pacchetto (APT::Status-Fd),
#     anche dentro il container (file condiviso in /tmp)
#   - popup di errore: Riprova / Mostra log / Esci
#   - schermata di benvenuto e schermata finale con "Avvia il desktop"
#  Senza terminale interattivo (o con --yes / --verbose) resta la modalità testo.
# =============================================================================

TUI_ON=0
TUI_FIFO=""
TUI_GAUGE_PID=""
TUI_START=$SECONDS
TUI_BACKTITLE=""
TUI_LOG_MARK=0
declare -ga TUI_IDS=() TUI_TITLES=() TUI_WEIGHTS=()
declare -gA TUI_STATE=()
# colori del testo (codici di dialog --colors), adatti al tema in uso
TUI_C_OK='\Z2' TUI_C_RUN='\Z4' TUI_C_FAIL='\Z1' TUI_C_SKIP='\Z5' TUI_C_ACCENT='\Z4'

tui_available() {
  [[ $TOD_YES != 1 && $TOD_VERBOSE != 1 && ${TOD_PLAIN:-0} != 1 && -t 0 && -t 1 ]] && have dialog && have mkfifo
}

tui_theme() { # predefinito: colori classici di dialog (alto contrasto, come la v1)
  if [[ $(conf_get UI_THEME classico) != scuro ]]; then
    unset DIALOGRC
    TUI_C_OK='\Z2' TUI_C_RUN='\Z4' TUI_C_FAIL='\Z1' TUI_C_SKIP='\Z5' TUI_C_ACCENT='\Z4'
    return 0
  fi
  # facoltativo: tod tweak tema scuro
  TUI_C_OK='\Z2' TUI_C_RUN='\Z6' TUI_C_FAIL='\Z1' TUI_C_SKIP='\Z3' TUI_C_ACCENT='\Z6'
  local rc="$TOD_STATE_DIR/dialogrc"
  cat >"$rc" <<'EOF'
# Termux On DeX - tema dialog
use_shadow = OFF
use_colors = ON
screen_color = (WHITE,BLACK,ON)
shadow_color = (BLACK,BLACK,ON)
dialog_color = (WHITE,BLACK,OFF)
title_color = (CYAN,BLACK,ON)
border_color = (CYAN,BLACK,ON)
border2_color = (CYAN,BLACK,ON)
button_active_color = (BLACK,CYAN,ON)
button_inactive_color = (WHITE,BLACK,OFF)
button_key_active_color = (BLACK,CYAN,ON)
button_key_inactive_color = (CYAN,BLACK,ON)
button_label_active_color = (BLACK,CYAN,ON)
button_label_inactive_color = (WHITE,BLACK,ON)
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (CYAN,BLACK,ON)
inputbox_border2_color = (CYAN,BLACK,ON)
searchbox_color = (WHITE,BLACK,OFF)
searchbox_title_color = (CYAN,BLACK,ON)
searchbox_border_color = (CYAN,BLACK,ON)
position_indicator_color = (CYAN,BLACK,ON)
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (CYAN,BLACK,ON)
menubox_border2_color = (CYAN,BLACK,ON)
item_color = (WHITE,BLACK,OFF)
item_selected_color = (BLACK,CYAN,ON)
tag_color = (CYAN,BLACK,ON)
tag_selected_color = (BLACK,CYAN,ON)
tag_key_color = (CYAN,BLACK,ON)
tag_key_selected_color = (BLACK,CYAN,ON)
check_color = (WHITE,BLACK,OFF)
check_selected_color = (BLACK,CYAN,ON)
uarrow_color = (CYAN,BLACK,ON)
darrow_color = (CYAN,BLACK,ON)
itemhelp_color = (WHITE,BLACK,OFF)
form_active_text_color = (BLACK,CYAN,ON)
form_text_color = (WHITE,BLACK,ON)
form_item_readonly_color = (CYAN,BLACK,ON)
gauge_color = (CYAN,BLACK,ON)
EOF
  export DIALOGRC=$rc
}

tui_init() { # attiva l'interfaccia se possibile
  tui_available || return 1
  TUI_ON=1
  TUI_START=$SECONDS
  TUI_LOG_MARK=$(wc -l <"$TOD_LOG" 2>/dev/null || echo 0)
  TUI_BACKTITLE="Termux On DeX $TOD_VERSION · ${DEV_BRAND^} ${DEV_NAME:-$DEV_MODEL} · Android $ANDROID_REL${ONEUI_VER:+ · One UI $ONEUI_VER}"
  tui_theme
  UI_DIALOG_OPTS=(--backtitle "$TUI_BACKTITLE")
  export TOD_PROGRESS_FILE="$TMPDIR/tod-progress"
  : >"$TOD_PROGRESS_FILE"
  trap 'tui_abort' INT TERM
}

tui_abort() {
  if [[ -n ${TUI_STEP_PID:-} ]]; then kill "$TUI_STEP_PID" 2>/dev/null || true; fi
  tui_gauge_close
  clear 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  err "$(t aborted)"
  exit 130
}

tui_end() { # chiude tutto e torna al terminale normale
  tui_gauge_close
  rm -f "${TOD_PROGRESS_FILE:-}"
  unset TOD_PROGRESS_FILE
  trap - INT TERM
  TUI_ON=0
}

# ----------------------------------------------------------------------------
#  Passi
# ----------------------------------------------------------------------------
tui_register() { # tui_register id "titolo" peso
  TUI_IDS+=("$1")
  TUI_TITLES+=("$2")
  TUI_WEIGHTS+=("$3")
  if step_done "$1"; then TUI_STATE[$1]=done; else TUI_STATE[$1]=wait; fi
}

tui_all_done() { # tutti i passi fatti o saltati?
  local id
  for id in "${TUI_IDS[@]}"; do
    case ${TUI_STATE[$id]} in done | skip) ;; *) return 1 ;; esac
  done
  return 0
}

tui_index() { local i; for ((i = 0; i < ${#TUI_IDS[@]}; i++)); do if [[ ${TUI_IDS[i]} == "$1" ]]; then echo "$i"; return 0; fi; done; return 1; }

tui_overall() { # tui_overall id_corrente avanzamento_del_passo(0-100) → percentuale totale
  local cur=$1 sub=$2 i id total=0 done_w=0 w
  for ((i = 0; i < ${#TUI_IDS[@]}; i++)); do
    id=${TUI_IDS[i]} w=${TUI_WEIGHTS[i]}
    total=$((total + w))
    if [[ ${TUI_STATE[$id]} == done || ${TUI_STATE[$id]} == skip ]]; then
      done_w=$((done_w + w))
    elif [[ $id == "$cur" ]]; then
      done_w=$((done_w + w * sub / 100))
    fi
  done
  if (( total == 0 )); then echo 0; else echo $((done_w * 100 / total)); fi
}

tui_render() { # testo del riquadro: intestazione, elenco dei passi, dettaglio
  local detail=${1:-} i id mark n=${#TUI_IDS[@]} cur=0 el title
  el=$((SECONDS - TUI_START))
  for ((i = 0; i < n; i++)); do
    if [[ ${TUI_STATE[${TUI_IDS[i]}]} == run ]]; then cur=$((i + 1)); fi
  done
  if (( cur == 0 )) && tui_all_done; then
    printf '%s\n\n' "$(t tui_header_done "$(printf '%d:%02d' $((el / 60)) $((el % 60)))")"
  else
    printf '%s\n\n' "$(t tui_header "$cur" "$n" "$(printf '%d:%02d' $((el / 60)) $((el % 60)))")"
  fi
  for ((i = 0; i < n; i++)); do
    id=${TUI_IDS[i]} title=${TUI_TITLES[i]}
    case ${TUI_STATE[$id]} in
      done) mark="${TUI_C_OK}✔\\Zn" ;;
      run) mark="${TUI_C_RUN}▶\\Zn" title="\\Zb$title\\ZB" ;;
      fail) mark="${TUI_C_FAIL}✘\\Zn" ;;
      skip) mark="${TUI_C_SKIP}–\\Zn" ;;
      *) mark='·' ;;
    esac
    printf ' %s %s\n' "$mark" "$title"
  done
  if [[ -n $detail ]]; then printf '\n %s↳\\Zn %s\n' "$TUI_C_ACCENT" "$detail"; fi
}

tui_parse_status() { # ultima riga di avanzamento → "percentuale|testo" (percentuale vuota = sconosciuta)
  local line kind a b c rest
  line=$(tail -n 1 "${TOD_PROGRESS_FILE:-/dev/null}" 2>/dev/null) || line=""
  if [[ -z $line ]]; then echo "|"; return 0; fi
  kind=${line%%:*}
  IFS=: read -r _ a b rest <<<"$line"
  c=${b%%.*}
  case $kind in
    dlstatus) # dlstatus:<n>:<percentuale>:Retrieving file 3 of 25
      if [[ $rest =~ ([0-9]+)\ of\ ([0-9]+) ]]; then
        echo "$((c * 30 / 100))|$(t tui_dl "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"
      else
        echo "$((c * 30 / 100))|$(t tui_dl_generic)"
      fi
      ;;
    pmstatus) echo "$((30 + c * 70 / 100))|$(t tui_pkg "$a")" ;;      # pmstatus:<pacchetto>:<percentuale>:<testo>
    pmerror) echo "|\\Z1$(t tui_pkg_error "$a")\\Zn" ;;
    tod) # tod:<percentuale o ->:<testo>
      if [[ $a =~ ^[0-9]+$ ]]; then echo "$a|$b${rest:+:$rest}"; else echo "|$b${rest:+:$rest}"; fi
      ;;
    *) echo "|" ;;
  esac
}

# ----------------------------------------------------------------------------
#  Barra (dialog --gauge alimentato da una FIFO)
# ----------------------------------------------------------------------------
tui_geometry() {
  local lines cols h w
  lines=$(tput lines 2>/dev/null || echo 30)
  cols=$(tput cols 2>/dev/null || echo 80)
  h=$((${#TUI_IDS[@]} + 12))
  if (( h > lines - 2 )); then h=$((lines - 2)); fi
  w=$((cols - 4))
  if (( w > 76 )); then w=76; fi
  echo "$h $w"
}

tui_gauge_open() {
  if [[ -n $TUI_GAUGE_PID ]]; then return 0; fi
  local h w
  read -r h w <<<"$(tui_geometry)"
  TUI_FIFO="$TMPDIR/tod-gauge.$$"
  rm -f "$TUI_FIFO"
  mkfifo "$TUI_FIFO" || return 1
  dialog --colors --backtitle "$TUI_BACKTITLE" --title " ${TUI_TITLE:-$(t tui_title)} " --gauge "" "$h" "$w" 0 <"$TUI_FIFO" >"$TUI_TTY" 2>&1 &
  TUI_GAUGE_PID=$!
  exec 7<>"$TUI_FIFO"   # lettura+scrittura: l'apertura non si blocca mai
}

tui_gauge_update() { # tui_gauge_update percentuale testo
  if [[ -z $TUI_GAUGE_PID ]]; then return 0; fi
  if ! kill -0 "$TUI_GAUGE_PID" 2>/dev/null; then TUI_GAUGE_PID=""; return 0; fi
  printf 'XXX\n%d\n%s\nXXX\n' "$1" "$2" >&7 2>/dev/null || true
}

tui_gauge_close() {
  if [[ -z $TUI_GAUGE_PID ]]; then return 0; fi
  local i
  exec 7>&- 2>/dev/null || true
  for ((i = 0; i < 20; i++)); do
    if ! kill -0 "$TUI_GAUGE_PID" 2>/dev/null; then break; fi
    pausa 0.1
  done
  # se un altro processo tiene ancora aperta la FIFO dialog non vede la fine: lo chiudiamo noi
  kill "$TUI_GAUGE_PID" 2>/dev/null || true
  wait "$TUI_GAUGE_PID" 2>/dev/null || true
  TUI_GAUGE_PID=""
  rm -f "$TUI_FIFO"
}

# ----------------------------------------------------------------------------
#  Esecuzione dei passi
# ----------------------------------------------------------------------------
tui_run() { # tui_run id comando...   (passo non interattivo, con barra e popup di errore)
  local id=$1 rc p txt best i title choice
  shift
  i=$(tui_index "$id") || return 1
  title=${TUI_TITLES[i]}
  while true; do
    TUI_STATE[$id]=run
    best=0
    : >"$TOD_PROGRESS_FILE"
    log "STEP (tui): $title ($*)"
    tui_gauge_open
    ( exec 7>&-; trap - ERR; "$@" ) >>"$TOD_LOG" 2>&1 </dev/null &
    TUI_STEP_PID=$!
    while kill -0 "$TUI_STEP_PID" 2>/dev/null; do
      IFS='|' read -r p txt <<<"$(tui_parse_status)"
      if [[ $p =~ ^[0-9]+$ ]] && (( p > best && p <= 99 )); then best=$p; fi
      tui_gauge_update "$(tui_overall "$id" "$best")" "$(tui_render "${txt:-$(t tui_working)}")"
      bv_note "$(tui_overall "$id" "$best")" "$id"
      pausa 0.3
    done
    if wait "$TUI_STEP_PID"; then rc=0; else rc=$?; fi
    TUI_STEP_PID=""
    conf_load
    log "STEP $title → rc=$rc"
    if [[ $rc == 0 ]]; then
      TUI_STATE[$id]=done
      step_mark "$id"
      tui_gauge_update "$(tui_overall "$id" 100)" "$(tui_render "")"
      return 0
    fi
    TUI_STATE[$id]=fail
    tui_gauge_close
    if (( BV_ON )); then choice=$(bv_error_choice "$id" "$title" "$(tui_overall "$id" "$best")"); else choice=$(tui_error_popup "$title" "$rc"); fi
    BV_LAST=""   # la schermata mostra ancora l'errore: il prossimo stato va scritto comunque
    if [[ $choice != retry ]]; then
      tui_end
      clear 2>/dev/null || true
      die "$(t step_failed "$title" "$TOD_LOG")"
    fi
  done
}

tui_interactive() { # tui_interactive id comando...   (passo con domande: la barra si chiude)
  local id=$1 rc=0
  shift
  tui_gauge_close
  TUI_STATE[$id]=run
  ui_backdrop
  "$@" || rc=$?
  ui_backdrop
  if [[ $rc == 0 ]]; then TUI_STATE[$id]=done; step_mark "$id"; else TUI_STATE[$id]=skip; fi
  return 0
}

tui_error_popup() { # → stampa "retry" o "quit"
  local title=$1 rc=$2 tail_txt r
  tail_txt=$(tail -n 12 "$TOD_LOG" 2>/dev/null | cut -c1-150 | sed 's/\\/\\\\/g') || tail_txt=""
  while true; do
    if dialog --colors --backtitle "$TUI_BACKTITLE" --title " \\Z1$(t tui_err_title)\\Zn " \
      --yes-label "$(t tui_retry)" --no-label "$(t tui_quit)" \
      --extra-button --extra-label "$(t tui_showlog)" \
      --yesno "$(t tui_err_text "$title" "$rc")\n\n$tail_txt" 0 0 >"$TUI_TTY" 2>&1; then
      echo retry
      return 0
    else
      r=$?
    fi
    case $r in
      3) dialog --backtitle "$TUI_BACKTITLE" --title " $(t tui_log_title) " --textbox "$TOD_LOG" \
           "$(($(tput lines 2>/dev/null || echo 30) - 2))" "$(($(tput cols 2>/dev/null || echo 80) - 2))" \
           >"$TUI_TTY" 2>&1 || true ;;
      *) echo quit; return 0 ;;
    esac
  done
}

tui_warnings() { # avvisi comparsi nel log durante questa installazione
  tail -n +"$((TUI_LOG_MARK + 1))" "$TOD_LOG" 2>/dev/null | grep -c ' WARN ' || true
}

# ----------------------------------------------------------------------------
#  Schermate
# ----------------------------------------------------------------------------
tui_banner() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)
  if (( cols >= 62 )); then
    printf '%s\n' "${TUI_C_ACCENT}\\Zb ▀█▀ █▀▀ █▀█ █▀▄▀█ █ █ ▀▄▀   █▀█ █▄ █   █▀▄ █▀▀ ▀▄▀" \
      "  █  ██▄ █▀▄ █ ▀ █ █▄█ █ █   █▄█ █ ▀█   █▄▀ ██▄ █ █\\Zn"
  else
    printf '%s\n' "${TUI_C_ACCENT}\\ZbTERMUX ON DEX\\Zn"
  fi
}

tui_welcome() { # 0 = inizia, 1 = esci
  local text
  text="$(tui_banner)\n\n$(device_summary | sed 's/^ *//')\n\n$(t tui_welcome_text)"
  dialog --colors --no-collapse --cr-wrap --backtitle "$TUI_BACKTITLE" --title " $(t welcome_title) " \
    --yes-label "$(t tui_begin)" --no-label "$(t tui_quit)" --yesno "$text" 0 0 >"$TUI_TTY" 2>&1
}

tui_finish() { # riepilogo finale; 0 = l'utente vuole avviare subito il desktop
  local warns cx="" el
  warns=$(tui_warnings)
  el=$((SECONDS - TUI_START))
  if cx_installed; then cx="$(cx_distro) · GPU $(conf_get CX_GPU_PROFILE llvmpipe)"; fi
  tui_gauge_close
  dialog --colors --backtitle "$TUI_BACKTITLE" --title " $(t done_title) " \
    --yes-label "$(t tui_start_now)" --no-label "$(t tui_close)" \
    --yesno "$(t tui_done_text "$(conf_get DE xfce)" "$(conf_get GPU_PROFILE llvmpipe)" "${cx:-—}" \
      "$(printf '%d:%02d' $((el / 60)) $((el % 60)))" "${warns:-0}")" 0 0 >"$TUI_TTY" 2>&1
}
