# shellcheck shell=bash
# =============================================================================
#  File e cartelle "da PC": chi usa il desktop non deve accorgersi di Termux.
#
#  La home del desktop è <files>/<utente> (es. .../files/pietro), non la home di
#  Termux: dentro ci sono solo Desktop, Documenti, Download, Immagini, Musica e
#  Video, come la cartella utente di Windows. Documenti & co. sono le cartelle del
#  telefono (una sola memoria con Android); i file nascosti (.config, .local...) sono
#  collegamenti a quelli di Termux, quindi impostazioni e dati restano condivisi.
#  Le app del container Debian ricevono le stesse cartelle nella loro home.
#  Niente frecce o X rosse sui collegamenti, niente "Computer"/"File System" (la
#  radice di Android non è leggibile), niente percorsi /data/data in vista.
# =============================================================================

FILES_PHONE=${TOD_PHONE_STORAGE:-/storage/emulated/0}

files_phone_ok() { [[ -d $FILES_PHONE/Download && -r $FILES_PHONE/Download ]]; }

files_termux_home() { printf '%s' "${TOD_TERMUX_HOME:-$HOME}"; }

files_user_valid() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ && ! $1 =~ ^(home|usr|apps|cache)$ ]]; }

files_user_home() { # → <files>/<utente>, se è stato scelto un nome utente valido
  local u
  u=$(conf_get USER_NAME)
  files_user_valid "$u" || return 1
  printf '%s/%s' "$(dirname "$(files_termux_home)")" "$u"
}

# cartelle della home: nome nella home | cartella del telefono
files_user_folders() {
  printf '%s|%s\n' "$(t fm_documents)" Documents "$(t fm_downloads)" Download "$(t fm_pictures)" Pictures \
    "$(t fm_music)" Music "$(t fm_videos)" Movies
}

files_link() { # files_link collegamento destinazione: crea o aggiorna, mai sopra una cartella vera
  if [[ -L $1 ]]; then ln -sfn "$2" "$1"; elif [[ ! -e $1 ]]; then ln -s "$2" "$1"; fi
}

files_user_home_setup() {
  local uh th n sub f b
  uh=$(files_user_home) || return 0
  th=$(files_termux_home)
  mkdir -p "$uh" "$th/Desktop"
  files_link "$uh/Desktop" "$th/Desktop"   # i lanciatori: la memoria del telefono non li permette
  while IFS='|' read -r n sub; do
    if files_phone_ok; then
      mkdir -p "$FILES_PHONE/$sub" 2>/dev/null || true
      files_link "$uh/$n" "$FILES_PHONE/$sub"
    else
      mkdir -p "$uh/$n"
    fi
  done < <(files_user_folders)
  # impostazioni e dati dei programmi: gli stessi di Termux
  for f in "$th"/.[!.]*; do
    b=${f##*/}
    if [[ -e $f && ! -e $uh/$b && ! -L $uh/$b ]]; then ln -s "$f" "$uh/$b"; fi
  done
  # i collegamenti "Telefono" delle versioni precedenti
  if [[ -L $th/$(t fm_phone) ]]; then rm -f "${th:?}/$(t fm_phone)"; fi
}

files_sdcards() { # schede SD e chiavette: /storage/XXXX-XXXX
  local d
  for d in /storage/*; do
    if [[ ${d##*/} =~ ^[0-9A-F]{4}-[0-9A-F]{4}$ && -r $d ]]; then printf '%s\n' "$d"; fi
  done
}

files_user_dirs() { # ~/.config/user-dirs.dirs: le cartelle della home dell'utente
  local uh c n sub key hidden
  uh=$(files_user_home) || return 0
  c="$(files_termux_home)/.config"
  hidden="$(files_termux_home)/.local/share/tod-dirs"
  mkdir -p "$c" "$hidden"
  {
    echo "# Generato da Termux On DeX"
    echo "XDG_DESKTOP_DIR=\"$uh/Desktop\""
    while IFS='|' read -r n sub; do
      case $sub in Documents) key=DOCUMENTS ;; Download) key=DOWNLOAD ;; Pictures) key=PICTURES ;; Music) key=MUSIC ;; Movies) key=VIDEOS ;; esac
      echo "XDG_${key}_DIR=\"$uh/$n\""
    done < <(files_user_folders)
    echo "XDG_TEMPLATES_DIR=\"$hidden\""
    echo "XDG_PUBLICSHARE_DIR=\"$hidden\""
  } >"$c/user-dirs.dirs"
  printf 'enabled=False\n' >"$c/user-dirs.conf"   # xdg-user-dirs-update non deve cambiarle
  printf 'it_IT\n' >"$c/user-dirs.locale"
}

files_bookmarks() { # barra laterale: le cartelle dell'utente, le schede SD, poi i segnalibri suoi
  local f uh ours="" n sub d k=0 line uri real skip
  uh=$(files_user_home) || return 0
  f="$(files_termux_home)/.config/gtk-3.0/bookmarks"
  while IFS='|' read -r n sub; do ours+="file://$uh/$n"$'\n'; done < <(files_user_folders)
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    k=$((k + 1))
    ours+="file://$d $(t fm_sdcard)$( ((k > 1)) && printf ' %s' "$k")"$'\n'
  done < <(files_sdcards)
  # da togliere: i nostri (anche di versioni precedenti: Telefono, Fotocamera, Debian),
  # riconosciuti dal percorso reale
  skip=$(
    readlink -f "$FILES_PHONE" 2>/dev/null || true
    readlink -f "$FILES_PHONE/DCIM/Camera" 2>/dev/null || true
    r=$(cx_rootfs 2>/dev/null) && readlink -f "$r/home/$(cx_user)" 2>/dev/null || true
    cut -d' ' -f1 <<<"$ours" | sed '/^$/d; s|^file://||' | while IFS= read -r d; do readlink -f "$d" 2>/dev/null || printf '%s\n' "$d"; done
  )
  mkdir -p "${f%/*}"
  {
    printf '%s' "$ours"
    if [[ -f $f ]]; then
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        uri=${line%% *}
        real=$(readlink -f "${uri#file://}" 2>/dev/null) || real=${uri#file://}
        # anche quelli che passavano dal vecchio collegamento ~/Telefono (ormai tolto)
        case ${uri#file://} in "$(files_termux_home)/$(t fm_phone)" | "$(files_termux_home)/$(t fm_phone)"/*) continue ;; esac
        if ! grep -qxF "$real" <<<"$skip"; then printf '%s\n' "$line"; fi
      done <"$f"
    fi
  } | sed '/^$/d' >"$f.tmp"
  mv -f "$f.tmp" "$f"
}

files_hide_emblems() { # niente frecce né X rosse sulle cartelle che sono collegamenti
  # Android dice "non leggibile" anche dove si legge benissimo (FUSE): come Esplora file, nessun emblema
  local d="$(files_termux_home)/.local/share/icons" s e
  for s in 16x16 22x22 24x24 32x32 48x48 scalable; do
    mkdir -p "$d/hicolor/$s/emblems"
    for e in emblem-symbolic-link emblem-unreadable; do
      printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>\n' >"$d/hicolor/$s/emblems/$e.svg"
    done
  done
  # le icone DeX OS hanno già gli emblemi vuoti (dexos-icons.py, EMBLEMI_VUOTI); questi sono per hicolor
}

files_hide_technical() { # cartelle tecniche nascoste: nella home di Termux e nella radice del telefono
  local h n
  h="$(files_termux_home)/.hidden"
  for n in storage tod-istantanee; do
    if [[ -e $(files_termux_home)/$n ]] && ! grep -qxF "$n" "$h" 2>/dev/null; then printf '%s\n' "$n" >>"$h"; fi
  done
  # sopra la home dell'utente (.../files) si vede solo lui, come "Utenti" in Windows
  local up
  up=$(dirname "$(files_termux_home)")
  for n in "$(basename "$(files_termux_home)")" usr apps; do
    if [[ -e $up/$n ]] && ! grep -qxF "$n" "$up/.hidden" 2>/dev/null; then printf '%s\n' "$n" >>"$up/.hidden" 2>/dev/null || true; fi
  done
  # Android/data e Android/obb danno "accesso negato"
  if files_phone_ok && [[ -w $FILES_PHONE ]] && ! grep -qxF Android "$FILES_PHONE/.hidden" 2>/dev/null; then
    printf 'Android\n' >>"$FILES_PHONE/.hidden" 2>/dev/null || true
  fi
}

FILES_CSS_END="/* <<< Termux On DeX */"

gtk_css_block() { # gtk_css_block "titolo" < regole: un blocco nostro in gtk.css, rifatto a ogni chiamata
  local f begin="/* >>> Termux On DeX: $1 */" old="" rules
  rules=$(cat)
  f="$(files_termux_home)/.config/gtk-3.0/gtk.css"
  mkdir -p "${f%/*}"
  if [[ -f $f ]]; then old=$(sed "\|^${begin//\*/\\*}\$|,\|^${FILES_CSS_END//\*/\\*}\$|d" "$f"); fi
  {
    if [[ -n $old ]]; then printf '%s\n' "$old"; fi
    printf '%s\n%s\n%s\n' "$begin" "$rules" "$FILES_CSS_END"
  } >"$f.tmp"
  mv -f "$f.tmp" "$f"
}

files_gtk_css() { # Thunar come Esplora file di Windows 11 (solo .thunar: le altre app non cambiano)
  gtk_css_block "Esplora file" <<EOF
.thunar headerbar, .thunar toolbar { background: #f3f3f3; border-bottom: 1px solid #e5e5e5; box-shadow: none; }
.thunar headerbar { min-height: 46px; padding: 0 6px; }
.thunar .path-bar { background: #ffffff; border: 1px solid #e3e3e3; border-radius: 4px; padding: 0 2px; min-height: 30px; }
.thunar .path-bar-button { border: none; background: transparent; box-shadow: none; border-radius: 3px; padding: 2px 8px; font-weight: normal; }
.thunar .path-bar-button:hover { background: rgba(0,0,0,0.05); }
.thunar .path-bar-button:checked { background: transparent; }
.thunar .sidebar, .thunar .shortcuts-pane, .thunar .sidebar treeview.view, .thunar .shortcuts-pane treeview.view { background-color: #f9f9f9; }
.thunar .sidebar treeview.view, .thunar .shortcuts-pane treeview.view { -GtkTreeView-vertical-separator: 12; -GtkTreeView-horizontal-separator: 8; }
.thunar .sidebar treeview.view:selected, .thunar .shortcuts-pane treeview.view:selected { background-color: #e6e6e6; color: #1a1a1a; }
.thunar .standard-view, .thunar .standard-view iconview { background-color: #ffffff; }
.thunar .standard-view iconview:selected, .thunar .standard-view treeview.view:selected { background-color: #cce8ff; color: #1a1a1a; border-radius: 4px; }
.thunar paned > separator { background: #ebebeb; min-width: 1px; min-height: 1px; }
EOF
}

files_fs_map_dir() { printf '%s' "$PREFIX/share/tod-fs"; }

files_fs_map() { # strade "finte" per le cartelle di sistema che Android non lascia leggere (tod-gettext.c)
  local files app n map
  map=$(files_fs_map_dir)
  files=$(dirname "$(files_termux_home)")          # .../com.termux/files
  app=$(dirname "$files")                          # .../com.termux
  rm -rf "$map"
  mkdir -p "$map$app" "$map$FILES_PHONE"
  # dentro la cartella di Termux si vede solo "files" (cache, impostazioni dell'app... nascoste)
  for n in cache code_cache shared_prefs databases no_backup app_webview app_textures lib; do
    if ! grep -qxF "$n" "$app/.hidden" 2>/dev/null; then printf '%s\n' "$n" >>"$app/.hidden" 2>/dev/null || true; fi
  done
}

files_setup() { # fuori dalla sessione (installazione, tod cartelle)
  files_user_home_setup
  files_user_dirs
  files_bookmarks
  files_hide_emblems
  files_hide_technical
  files_gtk_css
  files_fs_map
  conf_set FILES_SESSION_SET 0
}

FILES_SESSION_VERSION=8

FILES_TOOLBAR="back:1,forward:1,open-parent:1,location-bar:1,search:1,view-switcher:1,menu:1,open-home:0,undo:0,redo:0,reload:0,toggle-split-view:0,zoom-in:0,zoom-out:0,view-as-icons:0,view-as-detailed-list:0,view-as-compact-list:0"

files_session() { # dentro la sessione, una volta: Thunar pulito e icone del desktop
  if [[ $(conf_get FILES_SESSION_SET 0) == "$FILES_SESSION_VERSION" ]] || ! have xfconf-query; then return 0; fi
  local q=xfconf-query k
  $q -c thunar -p /hidden-bookmarks -n -a -t string -s computer:/// -t string -s file:/// -t string -s network:/// || true
  $q -c thunar -p /last-location-bar -n -t string -s ThunarLocationButtons || true
  $q -c thunar -p /misc-folders-first -n -t bool -s true || true
  # come Esplora file: niente barra dei menu (resta il pulsante menu) né barra di stato, icone grandi
  $q -c thunar -p /last-menubar-visible -n -t bool -s false || true
  $q -c thunar -p /last-statusbar-visible -n -t bool -s false || true
  $q -c thunar -p /misc-small-toolbar-icons -n -t bool -s false || true
  $q -c thunar -p /last-icon-view-zoom-level -n -t string -s THUNAR_ZOOM_LEVEL_100_PERCENT || true
  $q -c thunar -p /last-separator-position -n -t int -s 210 || true
  $q -c thunar -p /last-window-width -n -t int -s 1100 || true
  $q -c thunar -p /last-window-height -n -t int -s 700 || true
  # barra del titolo come tutte le altre finestre (xfwm4, tema Fluent): niente barra "CSD" diversa
  $q -c thunar -p /misc-use-csd -n -t bool -s false || true
  $q -c thunar -p /last-toolbar-items -n -t string -s "$FILES_TOOLBAR" || true
  # barra laterale: icone a colori, niente emblemi (Android dice "non leggibile" anche dove si legge)
  $q -c thunar -p /misc-symbolic-icons-in-sidepane -n -t bool -s false || true
  $q -c thunar -p /shortcuts-icon-emblems -n -t bool -s false || true
  $q -c thunar -p /tree-icon-emblems -n -t bool -s false || true
  $q -c thunar -p /shortcuts-icon-size -n -t string -s THUNAR_ICON_SIZE_24 || true
  $q -c thunar -p /misc-thumbnail-mode -n -t string -s THUNAR_THUMBNAIL_MODE_ALWAYS || true
  # "Sposta nel cestino" chiede conferma (anche dalla scrivania, che lo chiede a Thunar); "Elimina" sulla
  # scrivania non c'è (tod-gettext.c): si cancella per sempre solo svuotando il Cestino
  $q -c thunar -p /misc-confirm-move-to-trash -n -t bool -s true || true
  # titolo della finestra: solo il nome della cartella, senza "- Thunar" (Pietro)
  $q -c thunar -p /misc-window-title-style -n -t string -s THUNAR_WINDOW_TITLE_STYLE_FOLDER_NAME_WITHOUT_THUNAR_SUFFIX || true
  $q -c xsettings -p /Gtk/DecorationLayout -n -t string -s ":minimize,maximize,close" || true
  # sul desktop Home, Cestino e i dischi USB collegati (come macOS); niente file system né dischi fissi
  for k in show-filesystem show-device-fixed; do
    $q -c xfce4-desktop -p "/desktop-icons/file-icons/$k" -n -t bool -s false || true
  done
  for k in show-home show-trash show-removable show-device-removable show-unknown-removable; do
    $q -c xfce4-desktop -p "/desktop-icons/file-icons/$k" -n -t bool -s true || true
  done
  # tasto destro sulla scrivania come in Windows: niente elenco delle app né delle finestre
  $q -c xfce4-desktop -p /desktop-menu/show -n -t bool -s false || true
  $q -c xfce4-desktop -p /windowlist-menu/show -n -t bool -s false || true
  conf_set FILES_SESSION_SET "$FILES_SESSION_VERSION"
}

files_cx_user_dirs() { # nel container: le stesse cartelle, per "Apri" e "Salva con nome"
  # collegamenti e non --bind: i bind di proot le facevano vedere come dischi "montati"
  local uh n sub key root h d
  uh=$(files_user_home) || return 0
  root=$(cx_rootfs) || return 0
  h="$root/home/$(cx_user)"
  [[ -d $h ]] || return 0
  d="$h/.config"
  mkdir -p "$d"
  {
    echo "# Generato da Termux On DeX: le stesse cartelle del desktop"
    echo 'XDG_DESKTOP_DIR="$HOME/Desktop"'
    while IFS='|' read -r n sub; do
      case $sub in Documents) key=DOCUMENTS ;; Download) key=DOWNLOAD ;; Pictures) key=PICTURES ;; Music) key=MUSIC ;; Movies) key=VIDEOS ;; esac
      echo "XDG_${key}_DIR=\"\$HOME/$n\""
      files_cx_link "$h/$n" "$(readlink -f "$uh/$n")"
    done < <(files_user_folders)
  } >"$d/user-dirs.dirs"
  files_cx_link "$h/Desktop" "$(readlink -f "$uh/Desktop")"
  printf 'enabled=False\n' >"$d/user-dirs.conf"
  # doppioni lasciati da versioni precedenti (Documents, Downloads... verso le stesse cartelle)
  local f ours
  ours=$(for f in "$uh"/*; do readlink -f "$f"; done)
  for f in "$h"/*; do
    if [[ -L $f && ! -e $uh/${f##*/} ]] && grep -qxF "$(readlink -f "$f")" <<<"$ours"; then rm -f "$f"; fi
  done
  if [[ -e $h/storage ]] && ! grep -qxF storage "$h/.hidden" 2>/dev/null; then printf 'storage\n' >>"$h/.hidden"; fi
}

files_cx_link() { # al posto del vecchio punto di montaggio (cartella vuota) un collegamento
  if [[ -d $1 && ! -L $1 ]]; then rmdir "$1" 2>/dev/null || return 0; fi   # cartella con file: non si tocca
  files_link "$1" "$2"
}

files_rename_css() { # rinomina in linea (tod-gettext.c), come Esplora file di Windows: riquadro squadrato
  # bordato d'accento, compatto. Angoli dritti: senza compositore quelli tondi resterebbero neri
  gtk_css_block "rinomina in linea" <<'EOF'
window.tod-rename { background-color: @theme_selected_bg_color; border: none; border-radius: 0; padding: 1px; }
window.tod-rename entry, iconview entry, treeview entry {
  min-height: 0; padding: 2px 5px; border-radius: 0; box-shadow: none;
  border: 1px solid @theme_selected_bg_color; background-color: @theme_base_color; color: @theme_text_color; }
window.tod-rename entry { border: none; }
EOF
}

# Collegamenti sulla scrivania: Thunar e la scrivania li mostrano con nome e icona dell'app solo se
# "fidati" (metadata::xfce-exe-checksum = sha256 del file, come fa "Rendi eseguibile/Fidati").
# Si segnano solo le copie di app installate (stesso nome di una voce del menu): mai un .desktop ignoto.
files_trust_launchers() {
  local desk f base sum
  have gio && have sha256sum || return 0
  desk=$(readlink -f "$HOME/Desktop" 2>/dev/null) || return 0
  for f in "$desk"/*.desktop; do
    [[ -f $f ]] || continue
    base=${f##*/}
    if [[ ! -f $HOME/.local/share/applications/$base && ! -f $PREFIX/share/applications/$base ]]; then continue; fi
    sum=$(sha256sum "$f" | cut -d' ' -f1)
    if [[ $(gio info -a metadata::xfce-exe-checksum "$f" 2>/dev/null | sed -n 's/.*xfce-exe-checksum: //p') == "$sum" ]]; then
      continue
    fi
    chmod +x "$f" 2>/dev/null || true
    gio set -t string "$f" metadata::xfce-exe-checksum "$sum" 2>/dev/null || true
    log "scrivania: collegamento fidato $base"
  done
}

files_cli() { # tod cartelle: rifà home, cartelle e barra laterale (es. dopo aver inserito una scheda SD)
  files_setup
  files_cx_user_dirs || true
  if [[ -n ${DISPLAY:-} ]]; then files_session; fi
  ok "$(t fm_done)"
}
