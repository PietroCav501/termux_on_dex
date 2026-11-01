# shellcheck shell=bash
# =============================================================================
#  Lingua del desktop
#
#  Bionic (la libc di Android) non supporta le localizzazioni, quindi XFCE e GTK
#  nativi restano in inglese. tod-gettext.so, caricata con LD_PRELOAD solo nella
#  sessione grafica, legge direttamente i cataloghi .mo, che prendiamo dai pacchetti
#  Debian del container (scaricati, non installati). Firefox usa il suo pacchetto
#  lingua, LibreOffice del container il suo.
# =============================================================================

LINGUA_SO="$PREFIX/lib/tod-gettext.so"
LINGUA_DIR="$PREFIX/share/tod-locale"
LINGUA_DEB_PKGS="xfce4-session xfce4-settings xfdesktop4 xfdesktop4-data xfwm4 thunar thunar-data thunar-archive-plugin
  libexo-common libexo-2-0 exo-utils libxfce4ui-common libxfce4util-common libgarcon-common xfce4-terminal
  mousepad ristretto xfce4-taskmanager xfce4-screenshooter xfce4-notifyd xfce4-power-manager-data
  xfce4-appfinder xarchiver tumbler-common libgtk-3-common libgtk-4-common libglib2.0-data file-roller"

# app di Termux con i cataloghi in pacchetti Debian a parte (programma:pacchetti): si scaricano solo se
# l'app c'è. GIMP di Termux è compilato senza traduzioni: così si traducono le sue librerie e i plug-in (26 ottobre)
LINGUA_APP_PKGS="gimp:gimp-data,libgimp-3.0-0"

lingua_app_pkgs() { # → i pacchetti con i cataloghi delle app installate
  local e
  for e in $LINGUA_APP_PKGS; do
    if have "${e%%:*}"; then printf '%s\n' "${e#*:}" | tr ',' '\n'; fi
  done
}

lingua_code() { # → "it", "en", ... (dalla configurazione, altrimenti dalla lingua di Android)
  local l
  l=$(conf_get LINGUA)
  if [[ -z $l ]]; then l=$(prop persist.sys.locale); fi
  if [[ -z $l ]]; then l=$(prop ro.product.locale); fi
  l=${l%%[-_]*}
  l=${l,,}
  printf '%s' "${l:-en}"
}

lingua_active() { # traduzione del desktop pronta per la lingua scelta?
  local l
  l=$(lingua_code)
  [[ $l != en && -f $LINGUA_SO ]] && compgen -G "$LINGUA_DIR/$l/LC_MESSAGES/*.mo" >/dev/null
}

lingua_env() { # esporta l'ambiente di traduzione (solo per la sessione grafica)
  # tod-gettext.c cambiato (es. la rinomina in linea): si ricompila prima di avviare il desktop
  if [[ -f $LINGUA_SO && $TOD_ROOT/share/tod-gettext.c -nt $LINGUA_SO ]] && have clang; then lingua_build || true; fi
  local l
  l=$(lingua_code)
  if [[ $l == en ]]; then return 0; fi
  # le nostre finestre (Start, barra, Impostazioni...) seguono LANGUAGE: sempre la lingua scelta, anche quando la
  # traduzione di XFCE manca (1° novembre, S20+: passo di traduzione fallito → tutto il desktop in inglese)
  export LANGUAGE=$l
  if ! lingua_active; then return 0; fi
  export TOD_GETTEXT_LANG=$l TOD_GETTEXT_DIR=$LINGUA_DIR
  case ":${LD_PRELOAD:-}:" in
    *":$LINGUA_SO:"*) ;;
    *) export LD_PRELOAD="$LINGUA_SO${LD_PRELOAD:+:$LD_PRELOAD}" ;;
  esac
}

lingua_build() { # compila tod-gettext.so (clang serve solo la prima volta)
  local src="$TOD_ROOT/share/tod-gettext.c"
  if [[ -f $LINGUA_SO && $LINGUA_SO -nt $src ]]; then return 0; fi
  if ! have clang; then pkg_install clang || return 1; fi
  progress_note - "$(t lg_compile)"
  clang -shared -fPIC -O2 -o "$LINGUA_SO.tmp" "$src" -ldl || return 1
  mv -f "$LINGUA_SO.tmp" "$LINGUA_SO"
}

lingua_install_mo() { # lingua_install_mo lingua cartella  → sposta i .mo nella cartella delle traduzioni
  local l=$1 from=$2 f n=0
  mkdir -p "$LINGUA_DIR/$l/LC_MESSAGES"
  for f in "$from"/*.mo; do
    if [[ -f $f ]]; then mv -f "$f" "$LINGUA_DIR/$l/LC_MESSAGES/"; n=$((n + 1)); fi
  done
  # i plug-in di GIMP controllano che la cartella delle traduzioni compilata ci sia ($PREFIX/share/locale,
  # che Termux non ha): senza, "Localization disabled". tod-gettext.so legge comunque da qui
  if [[ ! -e $PREFIX/share/locale && ! -L $PREFIX/share/locale ]]; then ln -s tod-locale "$PREFIX/share/locale"; fi
  log "lingua: $n cataloghi .mo per '$l'"
  echo "$n"
}

lingua_fetch_mo() { # cataloghi dai pacchetti Debian, senza installarli nel container
  local l=$1 n
  if ! cx_installed; then warn "$(t lg_no_cx)"; return 1; fi
  progress_note - "$(t lg_fetch)"
  rm -rf "$TMPDIR/tod-mo-out"
  local app
  app=$(lingua_app_pkgs)
  # shellcheck disable=SC2086
  cx_root "$l" $LINGUA_DEB_PKGS $app <<'EOF' || return 1
set -e
lang="$1"
shift
work=/tmp/tod-mo-work
rm -rf "$work"
mkdir -p "$work/x" /tmp/tod-mo-out
cd "$work"
apt-get update -q >/dev/null 2>&1 || true
for p in "$@"; do apt-get download -q "$p" >/dev/null 2>&1 || true; done
for d in ./*.deb; do
  [ -f "$d" ] || continue
  dpkg-deb --fsys-tarfile "$d" | tar -x -C x --wildcards "./usr/share/locale/$lang/LC_MESSAGES/*" 2>/dev/null || true
done
cp -f x/usr/share/locale/"$lang"/LC_MESSAGES/*.mo /tmp/tod-mo-out/ 2>/dev/null || true
cd /
rm -rf "$work"
EOF
  n=$(lingua_install_mo "$l" "$TMPDIR/tod-mo-out")
  rm -rf "$TMPDIR/tod-mo-out"
  ((n > 0))
}

lingua_firefox() { # pacchetto lingua per la versione esatta di Firefox (via policies.json)
  local l=$1 ver dir url
  if ! have firefox; then return 0; fi
  ver=$(firefox --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+(esr)?' | sed -n 1p) || ver=""
  if [[ -z $ver ]]; then return 0; fi
  url="https://releases.mozilla.org/pub/firefox/releases/$ver/linux-x86_64/xpi/$l.xpi"
  if ! curl -fsIL --connect-timeout 15 "$url" >/dev/null 2>&1; then
    log "firefox: nessun pacchetto lingua '$l' per la versione $ver"
    return 0
  fi
  dir="$PREFIX/lib/firefox"
  if [[ ! -d $dir ]]; then dir=$(dirname "$(readlink -f "$PREFIX/bin/firefox")"); fi
  mkdir -p "$dir/distribution"
  if [[ -f $dir/distribution/policies.json && ! -f $dir/distribution/.tod ]]; then
    log "firefox: policies.json dell'utente, non lo tocco"
    return 0
  fi
  cat >"$dir/distribution/policies.json" <<EOF
{
  "policies": {
    "RequestedLocales": ["$l"],
    "ExtensionSettings": {
      "langpack-$l@firefox.mozilla.org": {
        "installation_mode": "force_installed",
        "install_url": "$url"
      }
    }
  }
}
EOF
  touch "$dir/distribution/.tod"
  log "firefox: pacchetto lingua '$l' per la $ver"
}

lingua_container() { # LibreOffice e dizionario nel container
  local l=$1 root
  if [[ $l == en ]] || ! root=$(cx_rootfs); then return 0; fi
  if grep -qx 'Package: libreoffice-core' "$root/var/lib/dpkg/status" 2>/dev/null; then
    cx_root "$l" <<'EOF' || true
export DEBIAN_FRONTEND=noninteractive
for p in "libreoffice-l10n-$1" "hunspell-$1" "hyphen-$1"; do
  apt-get install -y -q "$p" >/dev/null 2>&1 || true
done
EOF
  fi
}

lingua_setup() { # passo dell'installer e "tod lingua": non blocca mai l'installazione
  local l
  l=$(lingua_code)
  conf_set LINGUA "$l"
  if [[ $l == en ]]; then log "lingua: inglese, niente da tradurre"; return 0; fi
  if ! lingua_build; then warn "$(t lg_build_fail)"; return 0; fi
  lingua_fetch_mo "$l" || warn "$(t lg_mo_fail)"
  lingua_firefox "$l" || true
  lingua_container "$l" || true
  return 0
}

lingua_ripara() { # nel desktop: lingua scelta ma traduzione di XFCE mancante (passo fallito) → in sottofondo
  local l prova="$TOD_STATE_DIR/lingua-tentativo" oggi
  l=$(lingua_code)
  if [[ $l == en ]] || lingua_active; then return 0; fi
  oggi=$(date +%F)
  if [[ $(cat "$prova" 2>/dev/null) == "$oggi" ]]; then return 0; fi   # al massimo un tentativo al giorno
  echo "$oggi" >"$prova"
  log "lingua: traduzione '$l' mancante, la installo in sottofondo"
  (
    exec </dev/null >>"$TOD_LOG" 2>&1
    if have renice; then renice -n 10 -p "$BASHPID" >/dev/null 2>&1 || true; fi   # mai a scapito del desktop
    if lingua_setup && lingua_active; then
      log "lingua: traduzione '$l' pronta"
      if have notify-send; then notify-send -i preferences-desktop-locale "$(t lg_ready_title)" "$(t lg_ready_text)" || true; fi
    else
      log "lingua: traduzione '$l' ancora mancante, riprovo domani"
    fi
  ) &
  return 0
}

lingua_doctor() { # una riga per tod doctor
  local l
  l=$(lingua_code)
  if [[ $l == en ]]; then printf 'en'; elif lingua_active; then t lg_doc_ok "$l"; else t lg_doc_missing "$l" "$l"; fi
}

lingua_cli() { # tod lingua [it|en|...]
  local l=${1:-}
  if [[ -z $l ]]; then info "$(t lg_current "$(lingua_code)")"; return 0; fi
  [[ $l =~ ^[a-z]{2}$ ]] || die "tod lingua it|en|de|fr|es…"
  conf_set LINGUA "$l"
  run_step "$(t s_lingua "$l")" lingua_setup || true
  if session_running; then info "$(t m_restart_needed)"; fi
}
