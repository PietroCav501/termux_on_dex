# shellcheck shell=bash
# =============================================================================
#  Ambiente desktop nativo Termux: XFCE con DeX OS (barra, Start e pannelli nostri)
# =============================================================================

desktop_packages() { # il primo pacchetto è obbligatorio, gli altri facoltativi
  case $1 in
    xfce) echo "xfce4 xfce4-terminal xfce4-taskmanager xfce4-notifyd xfce4-screenshooter mousepad ristretto thunar-archive-plugin xarchiver" ;;
    *) return 1 ;;
  esac
}

desktop_start_cmd() {
  case $1 in
    xfce) echo xfce4-session ;;
    *) return 1 ;;
  esac
}

# Quello che usano le parti nostre del desktop, chiesto per nome (non come dipendenza di altro, che un
# giorno può cambiare): python + pygobject (Start, Impostazioni, Aggiornamenti, Spegnimento, ...: in
# Termux si chiama pygobject, non python-gobject), gvfs (dischi USB e rete in Esplora file),
# termux-api (batteria, rete, notifiche del telefono; con l'app Termux:API)
DESKTOP_TOD_PKGS="python pygobject gvfs termux-api"

desktop_install() { # desktop_install xfce
  local de=$1 list
  local -a pk=()
  list=$(desktop_packages "$de") || return 1
  read -ra pk <<<"$list"
  if ! pkg_has "${pk[0]}"; then err "$(t de_unavailable "$de")"; return 1; fi
  pkg_install "${pk[0]}" || return 1
  pkg_install_avail "${pk[@]:1}" || true
  pkg_install_avail dbus ttf-dejavu fontconfig-utils xdg-utils desktop-file-utils || true
  # shellcheck disable=SC2086
  pkg_install $DESKTOP_TOD_PKGS || return 1
  desktop_preconfigure "$de"
  desktop_install_entries
  files_setup
}

desktop_preconfigure() {
  local xml="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
  case $1 in
    xfce)
      mkdir -p "$xml"
      ;;
  esac
}

_ini_set() { # _ini_set file gruppo chiave valore
  local f=$1 g=$2 k=$3 v=$4
  touch "$f"
  if ! grep -qx "\[$g\]" "$f"; then printf '\n[%s]\n' "$g" >>"$f"; fi
  if awk -v g="[$g]" -v k="$k" '$0 == g {s = 1; next} /^\[/ {s = 0} s && index($0, k "=") == 1 {f = 1} END {exit !f}' "$f"; then
    awk -v g="[$g]" -v k="$k" -v v="$v" '$0 == g {s = 1; print; next} /^\[/ {s = 0}
      s && index($0, k "=") == 1 {print k "=" v; next} {print}' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
  else
    awk -v g="[$g]" -v k="$k" -v v="$v" '{print} $0 == g {print k "=" v}' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
  fi
}

desktop_entry() { # desktop_entry file nome nome_it comando icona terminale(true/false) [NoDisplay]
  cat >"$1" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Name[it]=$3
Exec=$4
Icon=$5
Terminal=$6
Categories=System;Settings;
${7:+NoDisplay=$7}
EOF
}

desktop_dischi_entry() { # "Dischi" nello Start (share/tod-dischi.py, via tod-usb dischi), con i dischi USB
  local f="$HOME/.local/share/applications/tod-dischi.desktop"
  if ! usb_on; then
    rm -f "$f"
    return 0
  fi
  desktop_entry "$f" "Disks" "Dischi" "bash $TOD_ROOT/share/usb/tod-usb dischi" org.gnome.DiskUtility false
  sed -i 's/^Categories=.*/Categories=System;Utility;/' "$f"
  printf 'StartupWMClass=tod-dischi\nComment=Formatta e partiziona chiavette, schede e dischi\n' >>"$f"
}

desktop_install_entries() {
  local apps="$HOME/.local/share/applications" auto="$HOME/.config/autostart" tod="$PREFIX/bin/tod"
  mkdir -p "$apps" "$auto"
  desktop_entry "$apps/tod-control.desktop" "Control center" \
    "Centro di controllo" "$tod menu" preferences-system true
  # come Windows: è un pannello di "Impostazioni", non una voce dello Start
  sed -i 's/^Categories=.*/Categories=Settings;X-XFCE-SettingsDialog;X-XFCE-SystemSettings;/' "$apps/tod-control.desktop"
  # Impostazioni come macOS (share/tod-settings.py): una finestra con barra laterale
  desktop_entry "$apps/tod-settings.desktop" "Settings" "Impostazioni" \
    "python3 $TOD_ROOT/share/tod-settings.py" preferences-system false
  sed -i 's/^Categories=.*/Categories=Settings;System;/' "$apps/tod-settings.desktop"
  # Aggiornamenti (come Windows Update): in Impostazioni; avvisa da solo (updates_start)
  desktop_entry "$apps/tod-updates.desktop" "Updates" "Aggiornamenti" \
    "python3 $TOD_ROOT/share/tod-updates.py" system-software-update false
  sed -i 's/^Categories=.*/Categories=Settings;X-XFCE-SettingsDialog;X-XFCE-SystemSettings;/' "$apps/tod-updates.desktop"
  desktop_dischi_entry
  # "Spegni": chiude desktop, audio e server X e torna ad Android. Nel menu no: c'è già il pulsante
  # di accensione dello Start
  desktop_entry "$apps/tod-stop.desktop" "Shut down" "Spegni" "$tod spegni" system-shutdown false true
  # menu Start (aspetto windows11): sempre in memoria, si apre all'istante
  ln -sfn "$TOD_ROOT/share/tod-start" "$PREFIX/bin/tod-start"
  desktop_entry "$apps/tod-start.desktop" "Start" "Start" "$PREFIX/bin/tod-start" tod-start false true
  # doppio clic su un .deb: finestra di installazione (Termux o Debian, deciso dal pacchetto)
  cat >"$apps/tod-deb.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Install package
Name[it]=Installa pacchetto
Exec=$tod installa %f
Icon=system-software-install
Terminal=false
NoDisplay=true
MimeType=application/vnd.debian.binary-package;application/x-deb;
EOF
  _ini_set "$HOME/.config/mimeapps.list" "Default Applications" application/vnd.debian.binary-package tod-deb.desktop
  _ini_set "$HOME/.config/mimeapps.list" "Default Applications" application/x-deb tod-deb.desktop
  desktop_entry "$auto/tod-hook.desktop" "Termux On DeX session hook" "Termux On DeX hook di sessione" \
    "$tod _hook" preferences-desktop-display false true
  desktop_tune_files
  desktop_refresh_caches
}

desktop_refresh_caches() {
  if have update-desktop-database; then update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true; fi
  if have gtk-update-icon-cache && [[ -d $HOME/.local/share/icons/hicolor ]]; then
    gtk-update-icon-cache -q -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
  fi
}

desktop_tune_files() { # file di sistema del desktop, idempotente (anche a ogni avvio)
  local kdir="$PREFIX/etc/xdg/xfce4/kiosk" krc first=""
  krc="$kdir/kioskrc"
  if [[ -f $krc ]]; then first=$(sed -n 1p "$krc" 2>/dev/null) || first=""; fi
  # "Spegni"/"Riavvia" non possono funzionare su Android: restano solo "Esci" e "Annulla"
  if [[ ! -f $krc || $first == *"Termux On DeX"* ]]; then
    mkdir -p "$kdir"
    # barra bloccata: niente "Nuovo pannello", "Aggiungi elementi", "Rimuovi" (la barra la gestisce
    # l'aspetto; un "Rimuovi" per sbaglio le aveva tolto le app il 14 ottobre)
    printf '%s\n' "# Termux On DeX: niente spegnimento/riavvio (Esci chiude tutto), barra bloccata" \
      "[xfce4-session]" "Shutdown=NONE" "" "[xfce4-panel]" "CustomizePanel=NONE" >"$krc"
  fi
  rm -f "$HOME/.local/share/applications/tod-gamenative.desktop"
  # chromium.desktop di Termux arriva con i segnaposto (@@desktop_exec): niente icona né avvio
  local cr="$PREFIX/share/applications/chromium.desktop"
  if [[ -f $cr ]] && grep -q '@@desktop_exec' "$cr"; then
    mkdir -p "$HOME/.local/share/applications"
    sed -e "s|@@desktop_exec|$PREFIX/bin/chromium-browser|g" -e 's|@@desktop_icon|chromium|g' \
      -e 's|@@startup_wm_class|Chromium-browser|g' "$cr" >"$HOME/.local/share/applications/chromium.desktop"
  fi
  # la voce "Esci" di XFCE sparisce dal menu: c'è "Spegni"
  local apps="$HOME/.local/share/applications"
  if [[ -f $PREFIX/share/applications/xfce4-session-logout.desktop && ! -f $apps/xfce4-session-logout.desktop ]]; then
    mkdir -p "$apps"
    printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=Log Out" "Exec=$PREFIX/bin/tod spegni" "NoDisplay=true" \
      >"$apps/xfce4-session-logout.desktop"
  fi
  desktop_hide_useless
}

# Voci del menu che non servono a chi usa il desktop (Pietro: "se non serve a niente va tolto"):
# demo, doppioni (Xarchiver = File Roller; "Browser web" e simili = scorciatoie ad app già nel menu),
# finestre che si aprono già da Thunar, e ciò che su Android non ha senso (energia, posta senza
# programma di posta, "Informazioni su Xfce").
DESKTOP_USELESS="org.gnome.Vte.App.Gtk3.desktop org.gnome.Vte.App.Gtk4.desktop org.kde.kwalletmanager.desktop
  xarchiver.desktop thunar-settings.desktop thunar-bulk-rename.desktop xfce4-web-browser.desktop
  xfce4-file-manager.desktop xfce4-terminal-emulator.desktop xfce4-mail-reader.desktop xfce4-about.desktop
  xfce4-power-manager-settings.desktop libreoffice-startcenter.desktop
  xfce-display-settings.desktop xfce-session-settings.desktop xfce-wmtweaks-settings.desktop
  xfce-workspaces-settings.desktop panel-preferences.desktop xfce4-clipman-settings.desktop"
# Pannelli di Impostazioni tolti, perché qui non servono o rompono qualcosa: Schermo (la risoluzione
# la decide Termux:X11, i DPI tod), Sessione e avvio (toglierebbe l'avvio di tod), Regolazioni del
# gestore delle finestre (il compositore dà lo schermo nero), Spazi di lavoro (uno solo, nessun
# selettore), Pannello (barra gestita dall'aspetto), Appunti (Clipman non è attivo).

desktop_hide_useless() { # copia con NoDisplay=true: restano usabili (es. per aprire un tipo di file)
  local apps="$HOME/.local/share/applications" id src dst
  local auto="$HOME/.config/autostart" send="$HOME/.local/share/Thunar/sendto"
  # gestore dell'energia: su Android batteria e schermo li governa il telefono (e la barra la mostra)
  if [[ -f $PREFIX/etc/xdg/autostart/xfce4-power-manager.desktop && ! -f $auto/xfce4-power-manager.desktop ]]; then
    mkdir -p "$auto"
    printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=Power Manager" "Hidden=true" "X-TOD-Hidden=true" \
      >"$auto/xfce4-power-manager.desktop"
  fi
  # "Invia a → Destinatario di posta": non c'è un programma di posta
  if [[ -f $PREFIX/share/Thunar/sendto/thunar-sendto-email.desktop && ! -f $send/thunar-sendto-email.desktop ]]; then
    mkdir -p "$send"
    printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=Mail" "Hidden=true" "X-TOD-Hidden=true" \
      >"$send/thunar-sendto-email.desktop"
  fi
  # azione di Thunar "Open Terminal Here" senza traduzione
  local uca="$HOME/.config/Thunar/uca.xml"
  if [[ -f $uca ]] && grep -q '<name>Open Terminal Here</name>' "$uca" && ! grep -q 'Apri terminale qui' "$uca"; then
    sed -i 's|^\([[:space:]]*\)<name>Open Terminal Here</name>|&\n\1<name xml:lang="it">Apri terminale qui</name>|' "$uca"
  fi
  for id in $DESKTOP_USELESS; do
    src="$PREFIX/share/applications/$id" dst="$apps/$id"
    [[ -f $src ]] || continue
    if [[ -f $dst ]] && ! grep -q '^X-TOD-Hidden=true' "$dst"; then continue; fi   # scelta dell'utente
    if [[ -f $dst && $dst -nt $src ]]; then continue; fi
    mkdir -p "$apps"
    awk '{ print } $0 == "[Desktop Entry]" && !d { print "NoDisplay=true"; print "X-XfceSettingsManagerHidden=true"; print "X-TOD-Hidden=true"; d = 1 }' \
      "$src" | awk '(!/^NoDisplay=/ || !s++) && (!/^X-XfceSettingsManagerHidden=/ || !h++)' >"$dst"
  done
}

xfconf_values() { # valori di una proprietà (anche array), uno per riga
  xfconf-query -c "$1" -p "$2" 2>/dev/null | sed '/^Value is an array/d; /^$/d' || true
}

# Su Android spegnere, riavviare, sospendere o cambiare utente non ha senso: resta solo "Spegni"
# (tod spegni = tod stop staccato dalla sessione), nello Start e su Ctrl+Alt+Canc e sul tasto di accensione.
xfce_power_button() {
  local cmd="$PREFIX/bin/tod spegni" k
  for k in "<Primary><Alt>Delete" "XF86PowerOff"; do
    xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$k" -n -t string -s "$cmd" || true
  done
}

xfwm_shadows() { # ombre morbide come macOS: finestre e menu sì, barra delle app no
  local kv k v
  for kv in show_frame_shadow=true show_popup_shadow=true show_dock_shadow=false; do
    xfconf-query -c xfwm4 -p "/general/${kv%%=*}" -n -t bool -s "${kv#*=}" || true
  done
  for kv in shadow_opacity=38 shadow_delta_x=0 shadow_delta_y=-4 shadow_delta_width=8 shadow_delta_height=8; do
    k=${kv%%=*} v=${kv#*=}
    xfconf-query -c xfwm4 -p "/general/$k" -n -t int -s "$v" || true
  done
}

xfce_first_run() { # ritocchi una tantum, eseguiti dentro la sessione
  have xfconf-query || return 0
  local comp=true k
  # compositore di xfwm4 acceso (15 ottobre, provato da Pietro: fluido, ~1% di CPU a riposo): angoli
  # lisci e ombre del tema DeX OS. Mai la sincronizzazione via GLX: con la GPU dà schermo nero o bianco
  # (come nella configurazione della v1). Si spegne con tod tweak compositor off.
  if [[ $(conf_get COMPOSITOR on) == off ]]; then comp=false; fi
  xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s "$comp" || true
  xfconf-query -c xfwm4 -p /general/vblank_mode -n -t string -s off || true
  xfwm_shadows
  xfconf-query -c xfce4-session -p /general/SaveOnExit -n -t bool -s false || true
  for k in ShowSuspend ShowHibernate ShowHybridSleep ShowSwitchUser; do
    xfconf-query -c xfce4-session -p "/shutdown/$k" -n -t bool -s false || true
  done
  xfce_power_button
}
