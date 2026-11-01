# shellcheck shell=bash
# =============================================================================
#  Aspetto del desktop: DeX OS (temi, icone e puntatore generati qui, share/dexos),
#  barra in basso con Start e app al centro. È l'unico aspetto: niente XFCE di base.
#  Va applicato a sessione ferma: xfconfd riscrive i suoi file quando XFCE si chiude.
# =============================================================================

look_record() { # ricorda cosa abbiamo scritto fuori dalle nostre cartelle, per il disinstallatore
  printf '%s\n' "$@" >>"$TOD_STATE_DIR/look-paths"
}

LOOK_W11_VERSION=9   # da aumentare a ogni rifinitura: si riapplica alla prossima sessione

# ----------------------------------------------------------------------------
#  Pulizia: niente temi, icone e puntatori di XFCE, GNOME, KDE, LXDE o della v1, né in Termux né nel
#  container (Pietro: "la roba vecchia deve sparire TUTTA"). I file dei pacchetti si tolgono e dpkg non
#  li rimette più (path-exclude), nemmeno con gli aggiornamenti. Restano: hicolor (le icone che ogni app
#  porta con sé), le parti di "Default" che GTK usa per i tasti, Fluent-Light e Fluent-Dark (da lì nasce
#  DeX OS). Le icone sono tutte nostre (DeX OS); la barra è la nostra (share/tod-barra.py).
#  Se manca un'icona compare un quadratino: va disegnata nel set DeX OS, non rimesso il vecchio.
# ----------------------------------------------------------------------------
LOOK_PULIZIA_VERSIONE=4
# la barra di XFCE e il suo contorno, sostituiti dalla nostra barra, dallo Start e dalle icone DeX OS
LOOK_VIA_PACCHETTI="fluent-icon-theme xfce4-docklike-plugin xfce4-genmon-plugin xfce4-whiskermenu-plugin
  xfce4-pulseaudio-plugin xfce4-clipman-plugin"
LOOK_VIA_TEMI="Daloa Default-hdpi Default-xhdpi Kokodi Moheli Bright Retro Smoke XP-Balloon ZOMG-PONIES! Emacs
  Raleigh HighContrast Adwaita Adwaita-dark Fluent Fluent-compact Fluent-Dark-compact Fluent-Light-compact
  Default/xfwm4 Default/xfce-notify-4.0 PiXflat PiXflat_l PiXnoir PiXnoir_l tPiXflat Windows-10-3.2.1"
LOOK_VIA_ICONE="Adwaita AdwaitaLegacy HighContrast breeze breeze-dark nuoveXT2 PiXflat Windows-10-3.2.1 Fluent
  Fluent-dark Fluent-light"

look_pulizia_righe() { # look_pulizia_righe RADICE_DI_SHARE → righe path-exclude per dpkg (la cartella
  # e il contenuto: con il solo contenuto dpkg ricreava le cartelle, vuote)
  local r=$1 n
  for n in $LOOK_VIA_TEMI; do printf 'path-exclude=%s/themes/%s\npath-exclude=%s/themes/%s/*\n' "$r" "$n" "$r" "$n"; done
  for n in $LOOK_VIA_ICONE; do printf 'path-exclude=%s/icons/%s\npath-exclude=%s/icons/%s/*\n' "$r" "$n" "$r" "$n"; done
  printf 'path-exclude=%s/backgrounds/*\n' "$r"   # sfondi di XFCE e di altri: solo i nostri
}

look_pulizia() { # una volta per versione: via la roba vecchia (Termux e container)
  [[ $(conf_get LOOK_PULIZIA 0) == "$LOOK_PULIZIA_VERSIONE" ]] && return 0
  local n d h root
  h=${TOD_TERMUX_HOME:-$HOME}
  mkdir -p "$PREFIX/etc/dpkg/dpkg.cfg.d"
  look_pulizia_righe "$PREFIX/share" >"$PREFIX/etc/dpkg/dpkg.cfg.d/tod-pulizia"
  for n in $LOOK_VIA_TEMI; do rm -rf "${PREFIX:?}/share/themes/$n" "$h/.themes/$n" "$h/.local/share/themes/$n"; done
  for n in $LOOK_VIA_ICONE; do rm -rf "${PREFIX:?}/share/icons/$n" "$h/.icons/$n" "$h/.local/share/icons/$n"; done
  # sfondi: quelli della v1 e di XFCE via; prima i nostri, perché non resti uno schermo vuoto
  look_sfondi_ensure
  rm -rf "${PREFIX:?}"/share/backgrounds/*
  if [[ $(conf_get SFONDO fiore) == /* && $(conf_get SFONDO) == "$PREFIX"/share/backgrounds/* ]]; then conf_set SFONDO fiore; fi
  conf_set LOOK_WALLPAPER ""
  if [[ -n ${DISPLAY:-} ]]; then look_sfondo_apply; fi
  # il puntatore di X (finestre senza un loro puntatore, programmi non GTK): il nostro
  look_puntatore_predefinito
  look_via_barra_xfce
  if cx_installed && root=$(cx_rootfs); then
    { look_pulizia_righe /usr/share; printf 'path-exclude=/usr/share/icons/default/*\n'; } |
      cx_write /etc/dpkg/dpkg.cfg.d/tod-pulizia 644
    for n in $LOOK_VIA_TEMI; do rm -rf "${root:?}/usr/share/themes/$n"; done
    for n in $LOOK_VIA_ICONE; do rm -rf "${root:?}/usr/share/icons/$n"; done
    # il puntatore predefinito di X nel container: il nostro (prima Adwaita)
    rm -rf "${root:?}/usr/share/icons/default"
    mkdir -p "$root/usr/share/icons/default"
    printf '[Icon Theme]\nInherits=DeX-OS-Puntatore\n' >"$root/usr/share/icons/default/index.theme"
    for d in "$root"/usr/share/themes/* "$root"/usr/share/icons/*; do   # collegamenti rimasti senza meta
      if [[ -L $d && ! -e $d ]]; then rm -f "$d"; fi
    done
    cx_sync_look || true
  fi
  conf_set LOOK_PULIZIA "$LOOK_PULIZIA_VERSIONE"
  log "pulizia dell'aspetto: fatta (versione $LOOK_PULIZIA_VERSIONE)"
}

look_via_barra_xfce() { # pacchetti, file e impostazioni della barra di XFCE e delle icone Fluent
  local p h
  local -a via=()
  h=${TOD_TERMUX_HOME:-$HOME}
  for p in $LOOK_VIA_PACCHETTI; do
    if pkg_installed "$p"; then via+=("$p"); fi
  done
  if ((${#via[@]})); then
    log "pulizia: via ${via[*]}"
    apt_run "${APT_FLAGS[@]}" remove "${via[@]}" >/dev/null 2>&1 || log "pulizia: pacchetti non tolti (apt occupato?)"
  fi
  rm -rf "$h/.local/share/icons/Fluent-tod" "$h/.config/xfce4/panel" "$h/.config/xfce4.prima-di-windows11" \
    "$h/.config/xfce4.prima-della-v1" "$h/.local/share/icons/hicolor/scalable/apps/tod-start.svg"
  if have xfconf-query && [[ -n ${DISPLAY:-} ]]; then xfconf-query -c xfce4-panel -p / -r -R 2>/dev/null || true; fi
  rm -f "$h/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
  return 0
}

look_dexos_vecchi() { # temi, icone e puntatori DeX OS di disegni superati (-vN più vecchi): via. Gli altri
  # colori restano, per cambiare accento all'istante
  local -a n
  local d b v
  read -ra n <<<"$(look_dexos_names)"
  ((${#n[@]} >= 5)) || return 0
  local vt=${n[0]##*-v} vi=${n[4]##*-v} vc=""
  if ((${#n[@]} >= 6)); then vc=${n[5]##*-v}; fi
  for d in "$(look_dexos_dir)"/DeX-OS-*-v* "$HOME"/.local/share/icons/DeX-OS-*-v*; do
    [[ -d $d && ! -L $d ]] || continue
    b=${d##*/}
    v=${b##*-v}
    [[ $v =~ ^[0-9]+$ ]] || continue
    case $b in
      DeX-OS-Icons-*) [[ $v == "$vi" ]] && continue ;;
      DeX-OS-Cursors-*) [[ -z $vc || $v == "$vc" ]] && continue ;;
      *) [[ $v == "$vt" ]] && continue ;;
    esac
    rm -rf "$d"
  done
  return 0
}

look_puntatore_predefinito() { # DeX-OS-Puntatore = il puntatore scelto, con un nome fisso (per X e il container)
  local h c
  h=${TOD_TERMUX_HOME:-$HOME}
  c=$(look_dexos_cursor)
  [[ -n $c ]] || return 0
  ln -sfn "$c" "$h/.local/share/icons/DeX-OS-Puntatore"
  mkdir -p "$h/.icons/default"
  printf '[Icon Theme]\nInherits=DeX-OS-Puntatore\n' >"$h/.icons/default/index.theme"
}

look_session_apply() { # nella sessione, una volta per versione: l'aspetto DeX OS (le rifiniture si riapplicano)
  look_pulizia || true
  if [[ $(conf_get LOOK_SESSION_SET 0) == "$LOOK_W11_VERSION" ]] || ! have xfconf-query; then return 0; fi
  look_session_windows11
  conf_set LOOK_SESSION_SET "$LOOK_W11_VERSION"
}

# ----------------------------------------------------------------------------
#  DeX OS: tema generato da Fluent (repository di Termux), font Inter (dal pacchetto Debian),
#  la nostra barra in basso con Start e app al centro.
# ----------------------------------------------------------------------------
LOOK_W11_GTK=Fluent-Light
LOOK_W11_FONT_FAMILY=Inter
LOOK_W11_FONT="$LOOK_W11_FONT_FAMILY 10"
LOOK_W11_FONT_FILES="Inter-Regular Inter-Italic Inter-Medium Inter-SemiBold Inter-Bold Inter-BoldItalic"

look_fonts_inter() { # Inter dal pacchetto Debian del container (scaricato, non installato)
  local dest="$PREFIX/share/fonts/tod-inter" n=0 f
  if [[ -f $dest/Inter-Regular.otf ]]; then return 0; fi
  if ! cx_installed; then warn "$(t look_no_font)"; return 0; fi
  rm -rf "$TMPDIR/tod-fonts-out"
  # shellcheck disable=SC2086
  cx_root $LOOK_W11_FONT_FILES <<'EOS' || { warn "$(t look_no_font)"; return 0; }
set -e
w=/tmp/tod-fonts-work
rm -rf "$w"; mkdir -p "$w/x" /tmp/tod-fonts-out
cd "$w"
apt-get download -q fonts-inter >/dev/null 2>&1 || { apt-get update -q >/dev/null 2>&1; apt-get download -q fonts-inter >/dev/null 2>&1; }
dpkg-deb -x ./fonts-inter_*.deb x
for f in "$@"; do cp -f "x/usr/share/fonts/opentype/inter/$f.otf" /tmp/tod-fonts-out/ 2>/dev/null || true; done
cd /; rm -rf "$w"
EOS
  mkdir -p "$dest"
  for f in "$TMPDIR"/tod-fonts-out/*.otf; do
    if [[ -f $f ]]; then mv -f "$f" "$dest/"; n=$((n + 1)); fi
  done
  rm -rf "$TMPDIR/tod-fonts-out"
  if ((n == 0)); then warn "$(t look_no_font)"; return 0; fi
  look_record "$dest"
  if have fc-cache; then fc-cache -f "$dest" >/dev/null 2>&1 || true; fi
  log "aspetto: font Inter ($n file)"
}

look_apply_windows11() {
  # fluent-gtk-theme: la base del tema DeX OS; pygobject (il nome in Termux): Start, barra, pannelli;
  # gli altri: le app del telefono nello Start
  # shellcheck disable=SC2086
  pkg_install_avail fluent-gtk-theme pygobject $ANDROID_APPS_PKGS || true
  look_fonts_inter
  conf_set ASPETTO windows11
  conf_set XFCE_TUNED 0
  conf_set LOOK_SESSION_SET 0
  desktop_tune_files
}

look_px() { printf '%s' $((($1 * $2 + 48) / 96)); }   # look_px <pixel a 96 DPI> <dpi>

look_scale_apply() { # tutto in proporzione allo schermo: un solo valore (DPI) per testo, icone, barra
  local dpi=$1 q=xfconf-query
  have xfconf-query || return 0
  # il testo segue già i DPI (Xft/DPI, anche le app del container e Electron); qui ciò che è in pixel
  $q -c xfce4-desktop -p /desktop-icons/icon-size -n -t uint -s "$(look_px 48 "$dpi")" || true
  $q -c xfce4-desktop -p /desktop-icons/use-custom-font-size -n -t bool -s false || true
  $q -c xsettings -p /Gtk/CursorThemeSize -n -t int -s "$(look_px 24 "$dpi")" || true
  $q -c thunar -p /last-icon-view-zoom-level -n -t string -s THUNAR_ZOOM_LEVEL_100_PERCENT || true
  $q -c thunar -p /shortcuts-icon-size -n -t string -s THUNAR_ICON_SIZE_24 || true
  # la cornice DeX OS è disegnata ai DPI dello schermo: cambiati i DPI si ridisegna
  local built
  built=$(conf_get DEXOS_BUILT)
  look_dexos_ensure "$dpi"
  if [[ $built != "$(conf_get DEXOS_BUILT)" ]]; then look_theme_reload; fi
}

# --- barra delle applicazioni: la nostra (share/tod-barra.py), mai xfce4-panel ------------------------
# La sessione di XFCE avvia la sua barra dall'elenco "Failsafe": se ne scrive uno senza xfce4-panel
# (avviare la nostra lì costava ~16 s: xfce4-session aspetta che ogni programma si registri), e la nostra
# parte dall'hook della sessione.
look_barra_sessione() {
  local q=xfconf-query c=xfce4-session p=/sessions/Failsafe i
  $q -c $c -p $p/IsFailsafe -n -t bool -s true || true
  $q -c $c -p $p/Count -n -t int -s 4 || true
  $q -c $c -p $p/Client0_Command -n -a -t string -s xfwm4 || true
  $q -c $c -p $p/Client0_Priority -n -t int -s 15 || true
  $q -c $c -p $p/Client1_Command -n -a -t string -s xfsettingsd || true
  $q -c $c -p $p/Client1_Priority -n -t int -s 20 || true
  $q -c $c -p $p/Client2_Command -n -a -t string -s Thunar -t string -s --daemon || true
  $q -c $c -p $p/Client2_Priority -n -t int -s 30 || true
  $q -c $c -p $p/Client3_Command -n -a -t string -s xfdesktop || true
  $q -c $c -p $p/Client3_Priority -n -t int -s 35 || true
  for i in 0 1 2 3; do $q -c $c -p $p/Client${i}_PerScreen -n -t bool -s false || true; done
  $q -c $c -p $p/Client4_Command -r 2>/dev/null || true
}

look_barra_avvia() { # nella sessione: la nostra barra (e via xfce4-panel, se una sessione vecchia lo avvia ancora)
  look_barra_sessione
  if pgrep -x xfce4-panel >/dev/null 2>&1; then xfce4-panel --quit >/dev/null 2>&1 || true; fi
  # --replace: una barra già aperta (magari col codice vecchio) lascia il posto
  (setsid "$TOD_ROOT/share/tod-barra" --replace </dev/null >/dev/null 2>&1 &)
}

look_notifiche_registro() { # le notifiche restano nel registro di xfce4-notifyd, che il pannello Notifiche legge
  local q=xfconf-query k ty v cambiato=0
  # registro: sempre (non solo in "Non disturbare"), di tutte le app; notifiche in basso a destra, vicino
  # alla campanella. xfce4-notifyd le legge solo all'avvio: se cambiano lo si chiude, D-Bus lo riavvia
  while read -r k ty v; do
    if [[ $($q -c xfce4-notifyd -p "$k" 2>/dev/null || true) != "$v" ]]; then
      $q -c xfce4-notifyd -p "$k" -n -t "$ty" -s "$v" || true
      cambiato=1
    fi
  done <<'EOF'
/notification-log bool true
/log-level uint 1
/log-level-apps uint 0
/notify-location string bottom-right
EOF
  if ((cambiato)); then pkill -x xfce4-notifyd 2>/dev/null || true; fi
}

# tema chiaro o scuro (Impostazioni → Aspetto, `tod aspetto tema chiaro|scuro`): TEMA in tod.conf
look_dark() { [[ $(conf_get TEMA chiaro) == scuro ]]; }

# --- DeX OS: tema nostro (share/dexos/dexos-theme.py), nel colore d'accento scelto (ACCENTO) ---
declare -gA LOOK_ACCENTS=([blu]="#0067c0" [viola]="#8a5cf5" [rosa]="#c239b3" [rosso]="#d13438"
  [arancione]="#ca5010" [giallo]="#b58900" [verde]="#107c10" [acqua]="#038387" [grafite]="#68768a")
look_accent() { conf_get ACCENTO "${LOOK_ACCENTS[blu]}"; }
look_dexos_dir() { printf '%s' "$HOME/.local/share/themes"; }
look_dexos_names() { conf_get DEXOS_NAMES; }   # "gtk-chiaro gtk-scuro cornice-chiara cornice-scura icone"
look_dexos_ok() {
  local -a n
  read -ra n <<<"$(look_dexos_names)"
  ((${#n[@]} >= 4)) && [[ -f $(look_dexos_dir)/${n[0]}/gtk-3.0/gtk.css && -f $(look_dexos_dir)/${n[3]}/xfwm4/themerc ]]
}

look_dexos_ensure() { # look_dexos_ensure dpi → tema DeX OS pronto per questo accento e questi DPI
  local dpi=${1:-96} scale out
  scale=$(awk -v d="$dpi" 'BEGIN { printf "%.3f", d / 96 }')
  # DEXOS_BUILT comprende la versione dei generatori: un disegno nuovo si rifà da solo
  local stamp
  stamp="$(look_accent)|$scale|$(cat "$TOD_ROOT"/share/dexos/*.py "$TOD_ROOT"/share/dexos/icone/*.{py,json,txt} 2>/dev/null | cksum | cut -d' ' -f1)"
  if look_dexos_ok && [[ -n $(look_dexos_icons) && $(conf_get DEXOS_BUILT) == "$stamp" ]]; then
    look_dexos_icone_app
    return 0
  fi
  have python3 && have rsvg-convert || return 0
  out=$(python3 "$TOD_ROOT/share/dexos/dexos-theme.py" build --accent "$(look_accent)" --scale "$scale" \
    --out "$(look_dexos_dir)" 2>/dev/null) || { log "DeX OS: tema non creato"; return 0; }
  # icone DeX OS (tutte nostre, cartelle nell'accento): ~/.local/share/icons/DeX-OS-Icons-[Dark-]<accento>
  local icons
  icons=$(look_dexos_icone_build)
  # puntatore DeX OS (corpo scuro e corpo chiaro, accento nei dettagli): ~30 s la prima volta per colore
  local cur
  cur=$(python3 "$TOD_ROOT/share/dexos/dexos-cursors.py" build --accent "$(look_accent)" \
    --out "$HOME/.local/share/icons" 2>/dev/null | tr '\n' ' ') || cur=""
  conf_set DEXOS_NAMES "$out${icons:+ $icons}${cur:+ ${cur% }}"
  look_dexos_vecchi
  look_sfondi_ensure
  conf_set DEXOS_BUILT "$stamp"
  if cx_installed; then cx_sync_look || true; fi   # le app di Debian trovano i temi nuovi
  log "DeX OS: tema pronto (accento $(look_accent), scala $scale): $out"
}

# --- sfondi DeX OS (share/dexos/dexos-sfondi.py): quattro famiglie, chiare e scure, nell'accento -------
look_sfondi_dir() { printf '%s/.local/share/backgrounds/dexos' "${TOD_TERMUX_HOME:-$HOME}"; }

look_sfondi_ensure() { # gli sfondi dell'accento di adesso (si rifanno se l'accento è cambiato)
  local d
  d=$(look_sfondi_dir)
  if [[ $(cat "$d/.accento" 2>/dev/null) == "$(look_accent)" ]] && ls "$d"/fiore-chiaro.* >/dev/null 2>&1; then return 0; fi
  have python3 && have rsvg-convert || return 0
  python3 "$TOD_ROOT/share/dexos/dexos-sfondi.py" build --accent "$(look_accent)" --out "$d" >/dev/null 2>&1 ||
    log "DeX OS: sfondi non creati"
}

look_sfondo_path() { # lo sfondo da mostrare: SFONDO = famiglia DeX OS (variante del tema) o un'immagine dell'utente
  local s f v=chiaro
  s=$(conf_get SFONDO fiore)
  if [[ $s == /* ]]; then
    if [[ -f $s ]]; then printf '%s' "$s"; return 0; fi
    s=fiore   # l'immagine scelta non c'è più
  fi
  if look_dark; then v=scuro; fi
  for f in "$(look_sfondi_dir)/$s-$v.jpg" "$(look_sfondi_dir)/$s-$v.png"; do
    if [[ -f $f ]]; then printf '%s' "$f"; return 0; fi
  done
  return 0
}

look_sfondo_apply() { # su ogni schermo (il nome del monitor cambia tra telefono e DeX)
  local w p mon
  local -a props=()
  w=$(look_sfondo_path)
  [[ -n $w ]] && have xfconf-query || return 0
  mapfile -t props < <(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/last-image$' || true)
  while IFS= read -r mon; do
    if [[ -n $mon ]]; then props+=("/backdrop/screen0/monitor$mon/workspace0/last-image"); fi
  done < <(xrandr --listmonitors 2>/dev/null | awk 'NR > 1 {print $NF}')
  for p in "${props[@]}"; do xfconf-query -c xfce4-desktop -p "$p" -n -t string -s "$w" 2>/dev/null || true; done
}

look_sfondo_cli() { # tod aspetto sfondo fiore|seta|paesaggio|vetro|/percorso/immagine
  local s=${1:-}
  case $s in
    "") info "$(conf_get SFONDO fiore)"; return 0 ;;
    fiore | seta | paesaggio | vetro) conf_set SFONDO "$s" ;;
    /*) [[ -f $s ]] || die "$s: file non trovato"; conf_set SFONDO "$s" ;;
    *) die "tod aspetto sfondo fiore|seta|paesaggio|vetro|/percorso/immagine" ;;
  esac
  look_sfondi_ensure
  look_sfondo_apply
}

look_dexos_icons() { # nome del tema di icone DeX OS, se c'è (col tema scuro la variante con i simboli chiari)
  local -a n
  local d=$HOME/.local/share/icons
  read -ra n <<<"$(look_dexos_names)"
  ((${#n[@]} >= 5)) && [[ -f $d/${n[4]}/index.theme ]] || return 0
  if look_dark && [[ -f $d/${n[4]/DeX-OS-Icons-/DeX-OS-Icons-Dark-}/index.theme ]]; then
    printf '%s' "${n[4]/DeX-OS-Icons-/DeX-OS-Icons-Dark-}"
  else
    printf '%s' "${n[4]}"
  fi
}

look_dexos_icone_build() { # costruisce (o trova già fatte) le icone DeX OS, stampa il nome del tema chiaro
  local icons t
  icons=$(python3 "$TOD_ROOT/share/dexos/dexos-icons.py" build --accent "$(look_accent)" \
    --out "$HOME/.local/share/icons" 2>/dev/null) || icons=""
  [[ -n $icons ]] || return 0
  if have gtk-update-icon-cache; then
    for t in "$icons" "${icons/DeX-OS-Icons-/DeX-OS-Icons-Dark-}"; do
      if [[ $HOME/.local/share/icons/$t/index.theme -nt $HOME/.local/share/icons/$t/icon-theme.cache ]]; then
        gtk-update-icon-cache -q -f -t "$HOME/.local/share/icons/$t" 2>/dev/null || true
      fi
    done
  fi
  printf '%s' "$icons"
}

look_dexos_icone_app() { # app installate o tolte: le loro icone nello squircle si rifanno (0,2 s se niente cambia)
  have python3 || return 0
  look_dexos_icone_build >/dev/null
}

look_dexos_cursor() { # tema del puntatore DeX OS (PUNTATORE=scuro|chiaro), se c'è
  local -a n
  local i=5
  read -ra n <<<"$(look_dexos_names)"
  if [[ $(conf_get PUNTATORE scuro) == chiaro ]]; then i=6; fi
  if ((${#n[@]} > i)) && [[ -f $HOME/.local/share/icons/${n[$i]}/index.theme ]]; then printf '%s' "${n[$i]}"; fi
}

look_cursor_cli() { # tod aspetto puntatore scuro|chiaro
  case ${1:-} in
    scuro | dark) conf_set PUNTATORE scuro ;;
    chiaro | light) conf_set PUNTATORE chiaro ;;
    *) die "tod aspetto puntatore scuro|chiaro" ;;
  esac
  local c
  c=$(look_dexos_cursor)
  if [[ -n $c ]] && have xfconf-query; then xfconf-query -c xsettings -p /Gtk/CursorThemeName -n -t string -s "$c" || true; fi
  look_puntatore_predefinito
}

look_w11_gtk() {
  local -a n
  if look_dexos_ok; then
    read -ra n <<<"$(look_dexos_names)"
    if look_dark; then printf '%s' "${n[1]}"; else printf '%s' "${n[0]}"; fi
  elif look_dark; then printf 'Fluent-Dark'; else printf '%s' "$LOOK_W11_GTK"; fi
}

look_w11_wm() { # cornice delle finestre: DeX OS (se manca, quella del tema GTK)
  local -a n
  if look_dexos_ok; then
    read -ra n <<<"$(look_dexos_names)"
    if look_dark; then printf '%s' "${n[3]}"; else printf '%s' "${n[2]}"; fi
    return 0
  fi
  look_w11_gtk
}

look_theme_reload() { # i nomi dei temi DeX OS cambiano con accento e scala: basta impostarli
  local icons
  icons=$(look_dexos_icons)
  if [[ -n $icons ]]; then xfconf-query -c xsettings -p /Net/IconThemeName -n -t string -s "$icons" || true; fi
  local cur
  cur=$(look_dexos_cursor)
  if [[ -n $cur ]]; then xfconf-query -c xsettings -p /Gtk/CursorThemeName -n -t string -s "$cur" || true; fi
  look_puntatore_predefinito
  look_sfondo_apply
  xfconf-query -c xsettings -p /Net/ThemeName -n -t string -s "$(look_w11_gtk)" || true
  xfconf-query -c xfwm4 -p /general/theme -n -t string -s "$(look_w11_wm)" || true
  xfconf-query -c xfce4-notifyd -p /theme -n -t string -s "$(look_w11_gtk)" || true   # notifiche DeX OS
}

look_accent_cli() { # tod aspetto accento <nome|#rrggbb>
  local v=${1:-} hex dpi
  if [[ -z $v ]]; then info "$(look_accent)"; return 0; fi
  hex=${LOOK_ACCENTS[$v]:-$v}
  [[ $hex =~ ^#[0-9a-fA-F]{6}$ ]] || die "tod aspetto accento ${!LOOK_ACCENTS[*]} | #rrggbb"
  conf_set ACCENTO "$hex"
  [[ -n ${DISPLAY:-} ]] && have xfconf-query || return 0
  dpi=$(xfconf-query -c xsettings -p /Xft/DPI 2>/dev/null) || dpi=96
  look_dexos_ensure "$dpi"
  look_theme_reload   # barra, Start e pannelli seguono il tema da soli (leggono ACCENTO)
}

look_theme_cli() { # tod aspetto tema chiaro|scuro — subito, senza riavviare il desktop
  case ${1:-} in
    chiaro | light) conf_set TEMA chiaro ;;
    scuro | dark) conf_set TEMA scuro ;;
    *) info "$(conf_get TEMA chiaro)"; return 0 ;;
  esac
  if [[ -n ${DISPLAY:-} ]] && have xfconf-query; then
    xfconf-query -c xsettings -p /Net/ThemeName -n -t string -s "$(look_w11_gtk)" || true
    xfconf-query -c xfwm4 -p /general/theme -n -t string -s "$(look_w11_wm)" || true
    xfconf-query -c xfce4-notifyd -p /theme -n -t string -s "$(look_w11_gtk)" || true
    look_sfondo_apply
  fi
}

look_session_windows11() { # nella sessione: tema, icone, font, finestre e menu Start
  local q=xfconf-query
  look_dexos_ensure "$($q -c xsettings -p /Xft/DPI 2>/dev/null || echo 96)"
  $q -c xsettings -p /Net/ThemeName -n -t string -s "$(look_w11_gtk)" || true
  $q -c xfce4-notifyd -p /theme -n -t string -s "$(look_w11_gtk)" || true   # notifiche DeX OS
  local icons
  icons=$(look_dexos_icons)
  if [[ -n $icons ]]; then $q -c xsettings -p /Net/IconThemeName -n -t string -s "$icons" || true; fi
  local cur
  cur=$(look_dexos_cursor)
  if [[ -n $cur ]]; then $q -c xsettings -p /Gtk/CursorThemeName -n -t string -s "$cur" || true; fi
  look_puntatore_predefinito
  look_sfondo_apply
  if [[ -f $PREFIX/share/fonts/tod-inter/Inter-Regular.otf ]]; then
    $q -c xsettings -p /Gtk/FontName -n -t string -s "$LOOK_W11_FONT" || true
    $q -c xfwm4 -p /general/title_font -n -t string -s "Inter Semi-Bold 10" || true
  fi
  $q -c xsettings -p /Xft/Antialias -n -t int -s 1 || true
  $q -c xsettings -p /Xft/HintStyle -n -t string -s hintslight || true
  $q -c xsettings -p /Xft/RGBA -n -t string -s none || true
  # cornice delle finestre: DeX OS
  $q -c xfwm4 -p /general/theme -n -t string -s "$(look_w11_wm)" || true
  $q -c xfwm4 -p /general/button_layout -n -t string -s "O|HMC" || true
  $q -c xfwm4 -p /general/title_alignment -n -t string -s left || true
  # niente striscia in alto: con xfwm4 4.20 copre l'angolo arrotondato; dall'alto si ridimensiona con
  # i bordi invisibili (share/tod-edges.py)
  $q -c xfwm4 -p /general/frame_border_top -n -t int -s 0 || true
  # tasto Windows: apre e chiude lo Start
  $q -c xfce4-keyboard-shortcuts -p /commands/custom/Super_L -n -t string -s "$PREFIX/bin/tod-start" || true
  look_notifiche_registro
}

look_apply_current() { # passo dell'installer: l'aspetto DeX OS
  look_apply_windows11
}

look_cli() { # tod aspetto [tema|accento|puntatore] ...: senza argomenti riapplica DeX OS
  local v=${1:-} was=0
  case $v in
    tema | theme) look_theme_cli "${2:-}"; return 0 ;;
    accento | accent) look_accent_cli "${2:-}"; return 0 ;;
    puntatore | cursor) look_cursor_cli "${2:-}"; return 0 ;;
    pulizia | clean) conf_set LOOK_PULIZIA 0; look_pulizia; return 0 ;;
    sfondo | wallpaper) look_sfondo_cli "${2:-}"; return 0 ;;
    "" | dexos | windows11 | win11 | windows) ;;
    *) die "tod aspetto [tema chiaro|scuro] [accento NOME] [puntatore scuro|chiaro]" ;;
  esac
  detect_gpu
  if session_running; then was=1; session_stop >/dev/null; fi
  run_step "$(t s_look)" look_apply_windows11 || warn "$(t look_fail)"
  if ((was)); then session_start; fi
}
