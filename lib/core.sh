# shellcheck shell=bash
# =============================================================================
#  Termux On DeX 2 — core
#  Log, passi con spinner, UI (dialog), configurazione, stato, rete.
#
#  Regole di stile (importanti con `set -Eeuo pipefail`):
#   - mai terminare una funzione con `cond && azione` (ritorna 1 se cond è falsa)
#   - mai `x=$(cmd)` se cmd può fallire: usare `if x=$(cmd); then ...` o `|| x=""`
#   - niente `| head` dopo comandi verbosi (SIGPIPE + pipefail): usare `sed -n 1p`
#   - dentro funzioni chiamate in un `if`/`||`/`&&` bash IGNORA `set -e` (anche
#     nelle subshell): ogni comando critico va controllato esplicitamente
#     (`cmd || return 1`). I passi di run_step sono scritti così.
#  tests/lint_errexit.py controlla le prime regole in automatico.
# =============================================================================

TOD_VERSION="2.0.0-alpha.1"

: "${PREFIX:=/data/data/com.termux/files/usr}"
: "${HOME:=/data/data/com.termux/files/home}"
: "${TMPDIR:=$PREFIX/tmp}"
export PREFIX HOME TMPDIR

# sempre quelle di Termux, anche dal desktop (dove HOME è la cartella dell'utente, files/<utente>):
# una configurazione sola, anche se un collegamento della cartella dell'utente manca (S20+, 17 ottobre)
TOD_CONF_DIR="${XDG_CONFIG_HOME:-${TOD_TERMUX_HOME:-$HOME}/.config}/tod"
TOD_STATE_DIR="${XDG_STATE_HOME:-${TOD_TERMUX_HOME:-$HOME}/.local/state}/tod"
TOD_CACHE_DIR="${XDG_CACHE_HOME:-${TOD_TERMUX_HOME:-$HOME}/.cache}/tod"
TOD_CONF="$TOD_CONF_DIR/tod.conf"
TOD_GPU_ENV="$TOD_CONF_DIR/gpu.env"
TOD_LOG="$TOD_STATE_DIR/tod.log"
TOD_YES="${TOD_YES:-0}"
TOD_VERBOSE="${TOD_VERBOSE:-0}"
declare -gA TOD_CFG=()
declare -ga UI_DIALOG_OPTS=()   # opzioni comuni a tutte le finestre (la TUI aggiunge il backtitle)
TUI_TTY=${TUI_TTY:-/dev/tty}
TUI_ON=${TUI_ON:-0}

tod_init() {
  mkdir -p "$TOD_CONF_DIR" "$TOD_STATE_DIR" "$TOD_CACHE_DIR" "$TMPDIR"
  # rotazione semplice del log (> 2 MB)
  local size=0
  if [[ -f $TOD_LOG ]]; then size=$(stat -c %s "$TOD_LOG" 2>/dev/null) || size=0; fi
  if (( size > 2097152 )); then mv -f "$TOD_LOG" "$TOD_LOG.1"; fi
  _tod_colors
  conf_load
  i18n_init
  tod_save_android_env
  ui_terminfo
}

ui_terminfo() { # tastierino numerico: le cifre arrivino come cifre anche nelle finestre di dialog.
  # dialog accende il "tastierino applicazione" (smkx con \E=): lì Termux manda i tasti del tastierino
  # come Esc O p..y, e dialog prende l'Esc per Annulla (l'associazione ADB falliva a ogni cifra).
  # Una copia della definizione del terminale senza \E= / \E>, solo per noi (TERMINFO)
  local d="$TOD_STATE_DIR/terminfo" t=${TERM:-}
  [[ -n $t && -t 0 ]] || return 0
  have infocmp && have tic || return 0
  if [[ ! -f $d/.$t ]]; then
    mkdir -p "$d"
    infocmp -x "$t" 2>/dev/null | sed 's/smkx=\\E\[?1h\\E=,/smkx=\\E[?1h,/; s/rmkx=\\E\[?1l\\E>,/rmkx=\\E[?1l,/' |
      tic -x -o "$d" - >/dev/null 2>&1 || return 0
    : >"$d/.$t"
  fi
  export TERMINFO=$d
}

tod_save_android_env() { # per tools/termux-run: dal proot servono le variabili di Android (app_process, am)
  if [[ -z ${BOOTCLASSPATH:-} ]]; then return 0; fi
  local f="$TOD_STATE_DIR/android.env" cur
  cur=$(env | grep -E '^(BOOTCLASSPATH|DEX2OATBOOTCLASSPATH|SYSTEMSERVERCLASSPATH|ANDROID_[A-Z_]+|EXTERNAL_STORAGE)=' | sort) || return 0
  if [[ ! -f $f || $(cat "$f" 2>/dev/null) != "$cur" ]]; then printf '%s\n' "$cur" >"$f" 2>/dev/null || true; fi
}

# ----------------------------------------------------------------------------
#  Output
# ----------------------------------------------------------------------------
_tod_colors() {
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[34m' C_C=$'\e[36m'
    C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_0=$'\e[0m'
  else
    C_R='' C_G='' C_Y='' C_B='' C_C='' C_BOLD='' C_DIM='' C_0=''
  fi
}
_tod_colors

log() { { printf '%s %s\n' "$(date '+%F %T')" "$*"; } 2>/dev/null >>"$TOD_LOG" || true; }
# nell'installazione a schermo intero (TUI_ON) le righe vanno solo nel registro: sullo schermo restano
# le finestre di dialog, senza il terminale nudo che compare tra una e l'altra
tui_quiet() { (( ${TUI_ON:-0} )); }
info() { tui_quiet || printf '%s•%s %s\n' "$C_B" "$C_0" "$*"; log "INFO $*"; }
ok() { tui_quiet || printf '%s✔%s %s\n' "$C_G" "$C_0" "$*"; log "OK $*"; }
warn() { tui_quiet || printf '%s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; log "WARN $*"; }
err() { tui_quiet || printf '%s✘%s %s\n' "$C_R" "$C_0" "$*" >&2; log "ERR $*"; }
die() { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
num() { if [[ ${1:-} =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf 0; fi; }
header() { printf '\n%s%s━━ %s ━━%s\n' "$C_BOLD" "$C_C" "$*" "$C_0"; log "== $*"; }

tod_on_error() { # chiamata dalla trap ERR
  local rc=$1 where=$2 cmd=$3
  log "ERRORE rc=$rc $where: $cmd"
  printf '\n%s✘ %s%s\n' "$C_R" "$(t unexpected_error "$rc" "$cmd")" "$C_0" >&2
  printf '  %s\n' "$(t see_log "$TOD_LOG")" >&2
}

# run_step "titolo" comando [argomenti...]
# Esegue un passo non interattivo: output nel log, spinner a schermo,
# in caso di errore mostra le ultime righe del log. Il comando gira in una
# subshell: lo stato va salvato su file (conf_set / step_mark), non in variabili.
# Il codice d'uscita del passo è quello del comando (vedi la nota su set -e sopra).
run_step() {
  local title=$1 rc=0 pid
  shift
  log "STEP: $title ($*)"
  if [[ ${TUI_ON:-0} == 1 ]]; then # modalità grafica: finestra di attesa invece dello spinner
    dialog "${UI_DIALOG_OPTS[@]}" --infobox "$title…" 5 $((${#title} + 10)) >"$TUI_TTY" 2>&1 || true
    ( exec 7>&- 2>/dev/null; trap - ERR; "$@" ) >>"$TOD_LOG" 2>&1 </dev/null &
    pid=$!
    if wait "$pid"; then rc=0; else rc=$?; fi
    conf_load
    log "STEP $title → rc=$rc"
    return "$rc"
  fi
  if [[ $TOD_VERBOSE == 1 || ! -t 1 ]]; then
    printf '%s→%s %s\n' "$C_B" "$C_0" "$title"
    ( trap - ERR; "$@" ) > >(tee -a "$TOD_LOG") 2>&1 </dev/null &
    pid=$!
    if wait "$pid"; then rc=0; else rc=$?; fi
    pausa 0.05   # lascia finire tee
  else
    local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    local i=0 start=$SECONDS
    ( trap - ERR; "$@" ) >>"$TOD_LOG" 2>&1 </dev/null &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || true; tput cnorm 2>/dev/null || true; printf "\n"; exit 130' INT TERM
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r %s%s%s %s %s(%ss)%s\e[K' "$C_C" "${frames[i % ${#frames[@]}]}" "$C_0" \
        "$title" "$C_DIM" "$((SECONDS - start))" "$C_0"
      i=$((i + 1))
      pausa 0.15
    done
    tput cnorm 2>/dev/null || true
    trap - INT TERM
    if wait "$pid"; then rc=0; else rc=$?; fi
    if [[ $rc == 0 ]]; then
      printf '\r %s✔%s %s %s(%ss)%s\e[K\n' "$C_G" "$C_0" "$title" "$C_DIM" "$((SECONDS - start))" "$C_0"
    else
      printf '\r %s✘%s %s\e[K\n' "$C_R" "$C_0" "$title"
      tail -n 20 "$TOD_LOG" | sed 's/^/   │ /' >&2
    fi
  fi
  conf_load   # la subshell può aver modificato la configurazione
  log "STEP $title → rc=$rc"
  return "$rc"
}

progress_note() { # progress_note percentuale|- "testo"   (dettaglio per la barra della TUI)
  if [[ -n ${TOD_PROGRESS_FILE:-} ]]; then printf 'tod:%s:%s\n' "$1" "$2" >>"$TOD_PROGRESS_FILE" 2>/dev/null || true; fi
}

# pausa <secondi>: attesa senza programmi esterni. Durante l'aggiornamento di Termux
# `sleep` può restare un attimo senza librerie (CANNOT LINK EXECUTABLE)
pausa() { read -rt "$1" <> <(:) || true; }

low_prio() { # low_prio comando...: priorità più bassa di processore e disco (lavoro in sottofondo, che
  # non deve mai togliere fluidità al desktop, soprattutto sui telefoni meno potenti)
  # nice -n AGGIUNGE alla priorità attuale, e i processi del desktop girano a -10 (top-app): si conta
  # quanto manca a 19, il minimo vero (campo 19 di /proc/<pid>/stat)
  local cur
  cur=$(awk '{print $19}' "/proc/$BASHPID/stat" 2>/dev/null) || cur=0
  [[ $cur =~ ^-?[0-9]+$ ]] || cur=0
  local -a p=(nice -n $((19 - cur)))
  if have ionice && ionice -c 3 true 2>/dev/null; then p+=(ionice -c 3); fi
  "${p[@]}" "$@"
}

# retry <tentativi> <attesa_iniziale_s> comando...   (attesa raddoppiata a ogni giro)
retry() {
  local tries=$1 delay=$2 n=1
  shift 2
  while true; do
    if "$@"; then return 0; fi
    if (( n >= tries )); then return 1; fi
    log "RETRY $n/$tries tra ${delay}s: $*"
    pausa "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
  done
}

# ----------------------------------------------------------------------------
#  UI: dialog se disponibile, altrimenti testo semplice; con TOD_YES=1 usa i default
# ----------------------------------------------------------------------------
ui_has_dialog() { [[ $TOD_YES != 1 ]] && have dialog && [[ -t 0 ]]; }

ui_backdrop() { # dopo una finestra: nell'installazione a schermo intero un riquadro "Lavoro in corso…"
  if (( ${TUI_ON:-0} )) && ui_has_dialog; then
    dialog "${UI_DIALOG_OPTS[@]}" --infobox "$(t tui_working)" 3 34 >"$TUI_TTY" 2>&1 || clear >/dev/tty
  else
    clear >/dev/tty 2>/dev/null || true
  fi
}

ui_msg() { # ui_msg "titolo" "testo"
  if [[ $TOD_YES == 1 ]]; then
    printf '%s%s%s\n%s\n' "$C_BOLD" "$1" "$C_0" "$2"
    return 0
  fi
  if ui_has_dialog; then
    dialog "${UI_DIALOG_OPTS[@]}" --title "$1" --msgbox "$2" 0 0 || true
    ui_backdrop
    return 0
  fi
  printf '\n%s%s%s\n%s\n' "$C_BOLD" "$1" "$C_0" "$2"
  read -rp "$(t press_enter) " || true
}

ui_yesno() { # ui_yesno "titolo" "testo" [y|n]
  local def=${3:-y} a=""
  if [[ $TOD_YES == 1 ]]; then [[ $def == y ]]; return; fi
  if ui_has_dialog; then
    local -a o=("${UI_DIALOG_OPTS[@]}" --title "$1" --yes-label "$(t yes)" --no-label "$(t no)")
    if [[ $def == n ]]; then o+=(--defaultno); fi
    if dialog "${o[@]}" --yesno "$2" 0 0; then ui_backdrop; return 0; fi
    ui_backdrop
    return 1
  fi
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_0"
  local hint="S/n"
  if [[ $def == n ]]; then hint="s/N"; fi
  read -rp "$2 [$hint] " a || a=""
  if [[ -z $a ]]; then a=$def; fi
  [[ $a =~ ^[sSyY] ]]
}

ui_menu() { # ui_menu "titolo" "testo" "predefinito" tag voce [tag voce...] → stampa il tag
  local title=$1 text=$2 def=$3 r a i=1
  shift 3
  if [[ $TOD_YES == 1 ]]; then printf '%s' "$def"; return 0; fi
  if ui_has_dialog; then
    if r=$(dialog "${UI_DIALOG_OPTS[@]}" --cancel-label "$(t ui_cancel)" --title "$title" --default-item "$def" --menu "$text" 0 0 0 "$@" 2>&1 >/dev/tty); then
      ui_backdrop
      printf '%s' "$r"
      return 0
    fi
    ui_backdrop
    return 1
  fi
  local -a tags=()
  printf '\n%s%s%s\n%s\n' "$C_BOLD" "$title" "$C_0" "$text" >&2
  while (($# >= 2)); do
    tags+=("$1")
    printf '  %d) %s\n' "$i" "$2" >&2
    shift 2
    i=$((i + 1))
  done
  read -rp "> " a || a=""
  if [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= ${#tags[@]} )); then
    printf '%s' "${tags[a - 1]}"
  else
    printf '%s' "$def"
  fi
}

ui_checklist() { # ui_checklist "titolo" "testo" tag voce on|off ... → tag scelti (uno per riga)
  local title=$1 text=$2 r
  shift 2
  if [[ $TOD_YES == 1 ]] || ! ui_has_dialog; then
    while (($# >= 3)); do
      if [[ $3 == on ]]; then printf '%s\n' "$1"; fi
      shift 3
    done
    return 0
  fi
  if r=$(dialog "${UI_DIALOG_OPTS[@]}" --cancel-label "$(t ui_cancel)" --title "$title" --separate-output --checklist "$text" 0 0 0 "$@" 2>&1 >/dev/tty); then
    ui_backdrop
    printf '%s\n' "$r"
    return 0
  fi
  ui_backdrop
  return 1
}

ui_input() { # ui_input "titolo" "testo" [predefinito]
  local def=${3:-} r=""
  if [[ $TOD_YES == 1 ]]; then printf '%s' "$def"; return 0; fi
  if ui_has_dialog; then
    if r=$(dialog "${UI_DIALOG_OPTS[@]}" --cancel-label "$(t ui_cancel)" --title "$1" --inputbox "$2" 0 0 "$def" 2>&1 >/dev/tty); then
      ui_backdrop
      printf '%s' "$r"
      return 0
    fi
    ui_backdrop
    return 1
  fi
  printf '\n%s\n' "$2" >&2
  read -rp "> " r || r=""
  printf '%s' "${r:-$def}"
}

# ----------------------------------------------------------------------------
#  Configurazione (~/.config/tod/tod.conf, formato CHIAVE="valore")
# ----------------------------------------------------------------------------
conf_load() {
  TOD_CFG=()
  [[ -f $TOD_CONF ]] || return 0
  local k v
  while IFS='=' read -r k v || [[ -n $k ]]; do
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    v=${v%\"}
    v=${v#\"}
    TOD_CFG[$k]=$v
  done <"$TOD_CONF"
}

conf_get() { # conf_get CHIAVE [predefinito]
  local v=${TOD_CFG[$1]-}
  if [[ -n $v ]]; then printf '%s' "$v"; else printf '%s' "${2-}"; fi
}

conf_set() { # conf_set CHIAVE valore
  local tmp k
  TOD_CFG[$1]=$2
  mkdir -p "$TOD_CONF_DIR"
  tmp=$(mktemp "$TOD_CONF_DIR/.tod.conf.XXXXXX")
  for k in "${!TOD_CFG[@]}"; do printf '%s="%s"\n' "$k" "${TOD_CFG[$k]}"; done | sort >"$tmp"
  mv -f "$tmp" "$TOD_CONF"
}

# ----------------------------------------------------------------------------
#  Stato dei passi dell'installazione (permette di riprendere dopo un errore)
# ----------------------------------------------------------------------------
step_done() { [[ -f $TOD_STATE_DIR/steps ]] && grep -qxF "$1" "$TOD_STATE_DIR/steps"; }
step_mark() { if ! step_done "$1"; then { printf '%s\n' "$1" >>"$TOD_STATE_DIR/steps"; } 2>/dev/null || true; fi; }
step_reset() { rm -f "$TOD_STATE_DIR/steps"; }

# ----------------------------------------------------------------------------
#  Rete e GitHub
# ----------------------------------------------------------------------------
# una rete che si pianta a metà (S20+, 22 ottobre: fermo 20 minuti): sotto 1 KB/s per 60 s curl si ferma,
# e il giro dopo riprova
NET_STALLO=(--speed-limit 1024 --speed-time 60)
net_get() { curl -fsSL --connect-timeout 15 "${NET_STALLO[@]}" --max-time 120 --retry 3 --retry-delay 2 "$@"; }

sha256_ok() { # sha256_ok file atteso
  local s
  s=$(sha256sum "$1" 2>/dev/null) || return 1
  s=${s%% *}
  [[ -n $s && $s == "${2,,}" ]]
}

net_download() { # net_download url destinazione [sha256]
  local url=$1 dest=$2 sha=${3:-}
  if [[ -n $sha && -f $dest ]] && sha256_ok "$dest" "$sha"; then
    log "cache valida: $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  progress_note - "$(t tui_download "${dest##*/}")"
  if ! retry 3 4 curl -fsSL --connect-timeout 20 "${NET_STALLO[@]}" -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    return 1
  fi
  if [[ -n $sha ]]; then
    if ! sha256_ok "$dest.part" "$sha"; then
      err "$(t checksum_bad "${dest##*/}")"
      rm -f "$dest.part"
      return 1
    fi
  else
    warn "$(t checksum_missing "${dest##*/}")"
  fi
  mv -f "$dest.part" "$dest"
}

# gh_release owner/repo prefisso_tag → JSON (compatto) della release più recente
gh_release() {
  local json
  json=$(net_get -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$1/releases?per_page=50") || return 1
  jq -ce --arg p "$2" \
    '[.[] | select((.draft | not) and (.tag_name | startswith($p)))] | sort_by(.published_at) | last' \
    <<<"$json"
}

# gh_asset "$json_release" regex → "url|sha256|nome" del primo asset corrispondente
gh_asset() {
  jq -r --arg rx "$2" \
    'first(.assets[] | select(.name | test($rx)))
     | [.browser_download_url, ((.digest // "") | sub("^sha256:"; "")), .name] | join("|")' \
    <<<"$1"
}

# gh_body_sha "$json_release" nome_file → sha256 elencato nelle note di rilascio
gh_body_sha() {
  jq -r '.body // ""' <<<"$1" | tr -d '\r' | awk -v f="$2" '
    ($2 == f || $2 == "*" f) && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && !done { print $1; done = 1 }'
}
