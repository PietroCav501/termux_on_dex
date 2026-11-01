# shellcheck shell=bash
# =============================================================================
#  Un solo apt: chi usa il desktop scrive "apt install gimp" come in qualsiasi
#  distribuzione. Ogni pacchetto va dove gira meglio: prima Termux (nativo, più
#  veloce), poi il container Debian (proot) solo se Termux non ce l'ha.
#  Nel terminale del desktop apt, apt-get, sudo e dpkg -i passano da qui
#  (share/tod-shell.sh); il menu Start si aggiorna da solo.
# =============================================================================

cx_pkgnames() { # file con i nomi dei pacchetti del container, rifatto quando cambia "apt update"
  local root cache="$TOD_STATE_DIR/cx-pkgnames"
  root=$(cx_rootfs) || return 1
  if [[ ! -s $cache || $root/var/lib/apt/lists -nt $cache ]]; then
    mkdir -p "$TOD_STATE_DIR"
    proot-distro login "$(cx_distro)" -- apt-cache pkgnames 2>/dev/null | sort -u >"$cache.tmp" || true
    mv -f "$cache.tmp" "$cache"
  fi
  printf '%s' "$cache"
}

# grep sul file e non "cx_pkgnames | grep -q": con pipefail il SIGPIPE farebbe fallire il test
cx_has() { local f; cx_installed && f=$(cx_pkgnames) && grep -qxF "$1" "$f"; }
cx_pkg_installed() { local l; l=$(cx_pkg_list) && grep -qxF "$1" <<<"$l"; }

# --- una app, un solo sistema ----------------------------------------------------------
# share/tod-app-keys.awk riduce ogni app a una chiave (firefox-esr → firefox, org.gimp.GIMP → gimp)
app_keys_termux() { # "chiave<TAB>pacchetto" delle app di Termux visibili nel menu
  grep -H '/share/applications/[^/]*\.desktop$' "$PREFIX"/var/lib/dpkg/info/*.list 2>/dev/null |
    awk -f "$TOD_ROOT/share/tod-app-keys.awk" -v mode=installed -v root= || true
}

app_keys_cx() {
  local root
  root=$(cx_rootfs) || return 0
  grep -H '/share/applications/[^/]*\.desktop$' "$root"/var/lib/dpkg/info/*.list 2>/dev/null |
    awk -f "$TOD_ROOT/share/tod-app-keys.awk" -v mode=installed -v root="$root" || true
}

app_key() { printf '%s\n' "$1" | awk -f "$TOD_ROOT/share/tod-app-keys.awk" -v mode=names; }

app_owner() { # app_owner nome → "pacchetto" già installato altrove con la stessa app (o niente)
  local k keys
  k=$(app_key "$1")
  keys=$(app_keys_termux; if cx_installed; then app_keys_cx; fi)
  awk -F '\t' -v k="$k" '$1 == k { print $2; exit }' <<<"$keys"
}

cx_apt() { # apt nel container, con l'output normale (il menu si aggiorna dopo, una volta sola)
  local rc=0
  proot-distro login --shared-tmp "$(cx_distro)" -- env TOD_MENU_SYNC=0 apt "$@" || rc=$?
  return "$rc"
}

apt_native() { local rc=0; command apt "$@" || rc=$?; return "$rc"; }

apt_split() { # apt_split argomenti... → opzioni in APT_OPTS, il resto in APT_ARGS
  APT_OPTS=() APT_ARGS=()
  local a
  for a in "$@"; do
    if [[ $a == -* ]]; then APT_OPTS+=("$a"); else APT_ARGS+=("$a"); fi
  done
}

apt_cli() { # tod apt <comando> [opzioni] [pacchetti]
  local rc=0 verb p
  local -a APT_OPTS APT_ARGS native=() cx=() debs=() miss=()
  apt_split "$@"
  verb=${APT_ARGS[0]:-}
  case $verb in
    install | reinstall)
      local owner k
      for p in "${APT_ARGS[@]:1}"; do
        if [[ $p == *.deb ]]; then debs+=("$p"); continue; fi
        # già installato: resta dov'è (apt install = aggiorna, come sempre)
        if pkg_installed "$p"; then native+=("$p"); continue; fi
        if cx_installed && cx_pkg_installed "$p"; then cx+=("$p"); continue; fi
        # la stessa app con un altro nome, in uno dei sistemi: mai due copie
        owner=$(app_owner "$p")
        if [[ -n $owner ]]; then info "$(t apt_already "$p" "$owner")"; continue; fi
        k=$(app_key "$p")
        if pkg_has "$p"; then native+=("$p")
        elif [[ $k != "$p" ]] && pkg_has "$k"; then   # firefox-esr → firefox di Termux
          info "$(t apt_same_app "$p" "$k")"
          native+=("$k")
        elif cx_has "$p"; then cx+=("$p")
        else miss+=("$p"); fi
      done
      if ((${#miss[@]})); then
        err "$(t apt_missing "${miss[*]}")"
        return 100
      fi
      if ((${#native[@]})); then apt_native "$verb" "${APT_OPTS[@]}" "${native[@]}" || return; fi
      if ((${#cx[@]})); then
        cx_apt "$verb" "${APT_OPTS[@]}" "${cx[@]}" || return
        cx_sync_apps || true
      fi
      local f name
      for p in "${debs[@]}"; do
        f=$(deb_resolve "$p") || f=$p
        name=$(deb_field "$f" Package)
        if [[ -n $name ]] && ! pkg_installed "$name" && ! { cx_installed && cx_pkg_installed "$name"; }; then
          owner=$(app_owner "$name")
          if [[ -n $owner ]]; then info "$(t apt_already "$name" "$owner")"; continue; fi
        fi
        deb_install "$f" || return
      done
      ;;
    remove | purge)
      for p in "${APT_ARGS[@]:1}"; do
        if pkg_installed "$p"; then native+=("$p")
        elif cx_installed && cx_pkg_installed "$p"; then cx+=("$p")
        else native+=("$p"); fi   # il messaggio d'errore lo dà apt, come al solito
      done
      if ((${#native[@]})); then apt_native "$verb" "${APT_OPTS[@]}" "${native[@]}" || return; fi
      if ((${#cx[@]})); then
        cx_apt "$verb" "${APT_OPTS[@]}" "${cx[@]}" || return
        cx_prune_exports || true
      fi
      ;;
    update | upgrade | full-upgrade | dist-upgrade | autoremove | clean | autoclean)
      apt_native "$@" || rc=$?
      if cx_installed; then
        cx_apt "$@" || rc=$?
        if [[ $verb != update ]]; then cx_sync_apps || true; fi
      fi
      return "$rc"
      ;;
    search)
      apt_native "$@" 2>/dev/null || true
      if cx_installed; then
        # senza i doppioni: quello che c'è in Termux è già sopra
        cx_apt "$@" 2>/dev/null | awk -v names="$(apt-cache pkgnames 2>/dev/null | tr '\n' ' ')" '
          BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) have[a[i]] = 1 }
          /^Sorting|^Full Text|^Ordinamento|^Ricerca/ { next }
          /^[^ ]/ { split($0, f, "/"); skip = (f[1] in have) }
          !skip { print }' || true
      fi
      ;;
    show | policy | showsrc | depends | rdepends | changelog)
      p=${APT_ARGS[1]:-}
      if [[ -n $p ]] && ! pkg_has "$p" && cx_has "$p"; then cx_apt "$@"; else apt_native "$@"; fi
      ;;
    list)
      apt_native "$@" 2>/dev/null || true
      if cx_installed; then cx_apt "$@" 2>/dev/null | sed '/^Listing\|^Elenco/d' || true; fi
      ;;
    *) apt_native "$@" ;;
  esac
}

apt_shell_setup() { # il terminale del desktop carica share/tod-shell.sh (una riga in ~/.bashrc)
  local h rc line
  h=$(files_user_home) || h=$HOME
  rc="$h/.bashrc"
  line="[ -r \"$TOD_ROOT/share/tod-shell.sh\" ] && . \"$TOD_ROOT/share/tod-shell.sh\"   # Termux On DeX: un solo apt"
  if grep -qxF "$line" "$rc" 2>/dev/null; then return 0; fi
  if [[ -f $rc ]]; then sed -i '/Termux On DeX: un solo apt$/d' "$rc"; fi   # percorso cambiato
  printf '%s\n' "$line" >>"$rc"
}
