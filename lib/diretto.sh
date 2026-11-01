# shellcheck shell=bash
# =============================================================================
#  App di Debian senza proot (23 ottobre 2026), come GameHub, GameNative e DroidDeck. proot ferma
#  il programma a ogni chiamata al sistema (ptrace): 200.000 stat 10 s invece di 0,13; glxgears
#  ~310 fotogrammi invece di ~650; un'app Electron -36% di processore e -20% di memoria.
#
#  Qui il programma parte con il caricatore di Debian (copia corretta da share/diretto/correggi.py:
#  Android vieta set_robust_list e chiudeva tutto) e due librerie precaricate: libfakechroot (del
#  container: fa vedere all'app /usr, /etc... del container) e tod-diretto.so (share/diretto: quello
#  che fakechroot non copre). proot resta per apt, dpkg, sudo, pkexec (vogliono root: tod-diretto.so
#  li rilancia in proot) e per i programmi che senza proot non partono: diretto_run lo capisce
#  (caricatore che non trova librerie, chiamata vietata, crash entro pochi secondi), segna il
#  programma in diretto-no e cx_run lo riavvia in proot. DIRETTO=0 spegne tutto.
# =============================================================================

DIRETTO_FC=/usr/lib/aarch64-linux-gnu/fakechroot/libfakechroot.so
DIRETTO_LIBC=/usr/lib/aarch64-linux-gnu/libc.so.6
DIRETTO_LD=/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
# percorsi di Android che l'app vede come sono (fakechroot non li porta nel container)
DIRETTO_FUORI=/proc:/dev:/sys:/data:/storage:/sdcard:/apex:/system:/vendor:/odm:/product
DIRETTO_ENTRO=15   # secondi: un crash prima di questo vuol dire "senza proot non va"

diretto_on() { [[ $(conf_get DIRETTO 1) == 1 ]]; }

diretto_dir() { printf '%s/.local/share/tod-diretto' "${TOD_TERMUX_HOME:-$HOME}"; }

diretto_no_file() { printf '%s/diretto-no' "$TOD_STATE_DIR"; }

diretto_firma() { # cambia con il glibc o fakechroot del container (aggiornamenti) e con i nostri sorgenti
  local root f
  root=$(cx_rootfs) || return 1
  for f in "$root$DIRETTO_LD" "$root$DIRETTO_LIBC" "$root$DIRETTO_FC"; do
    stat -L -c '%s:%Y' "$f" 2>/dev/null || echo -
  done | tr '\n' ' '
  cat "$TOD_ROOT/share/diretto/tod-diretto.c" "$TOD_ROOT/share/diretto/correggi.py" | cksum | cut -d' ' -f1
}

diretto_pronto() { # le copie ci sono e sono di questo glibc
  local d f
  d=$(diretto_dir)
  [[ -s $d/ld.so && -s $d/lib/libc.so.6 && -s $d/tod-diretto.so && -f $d/firma ]] || return 1
  f=$(diretto_firma) || return 1
  [[ $(cat "$d/firma") == "$f" ]]
}

diretto_prepara() { # copie corrette di ld.so e libc, tod-diretto.so; libfakechroot nel container
  diretto_on || return 0
  cx_installed || return 0
  local root d f
  root=$(cx_rootfs) || return 1
  # a ogni giro (anche dopo apt, da cx_sync_apps): i pacchetti nuovi portano collegamenti assoluti, che
  # senza proot escono dal container (certificati, /etc/alternatives, caratteri: 26 ottobre)
  python3 "$TOD_ROOT/share/diretto/collegamenti.py" "$root" 2>>"$TOD_LOG" | grep -v ': 0$' >>"$TOD_LOG" || true
  if diretto_pronto; then return 0; fi
  d=$(diretto_dir)
  if [[ ! -f $root$DIRETTO_FC ]]; then cx_pkg_install libfakechroot || return 1; fi
  if ! have clang; then pkg_install clang || return 1; fi
  mkdir -p "$d/lib"
  python3 "$TOD_ROOT/share/diretto/correggi.py" "$root$DIRETTO_LD" "$d/ld.so" "$root$DIRETTO_LIBC" "$d/lib/libc.so.6" \
    >>"$TOD_LOG" 2>&1 || return 1
  clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib -ffreestanding -fno-builtin -fuse-ld=lld \
    -o "$d/tod-diretto.so.$$" "$TOD_ROOT/share/diretto/tod-diretto.c" "$root$DIRETTO_LIBC" >>"$TOD_LOG" 2>&1 || return 1
  mv -f "$d/tod-diretto.so.$$" "$d/tod-diretto.so"
  f=$(diretto_firma) || return 1
  printf '%s\n' "$f" >"$d/firma"
  rm -f "$(diretto_no_file)"   # glibc o codice nuovi: si riprovano anche le app che non partivano
  log "diretto: pronto ($f)"
}

diretto_trova() { # diretto_trova rootfs comando → percorso nel container (come lo cerca la shell)
  local root=$1 c=$2 p
  if [[ $c == */* ]]; then printf '%s' "$c"; return 0; fi
  for p in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin /usr/games; do
    if [[ -e $root$p/$c || -L $root$p/$c ]]; then printf '%s' "$p/$c"; return 0; fi
  done
  return 1
}

diretto_elf() { # diretto_elf file → vero se è un programma ELF con il caricatore di glibc (non statico)
  local m
  m=$(od -An -c -N4 "$1" 2>/dev/null | tr -d ' ')
  if [[ $m != 177ELF ]]; then return 1; fi
  grep -qa 'ld-linux-aarch64.so.1' <(head -c 4096 "$1")
}

diretto_librerie() { # cartelle delle librerie: le nostre copie, poi quelle di ld.so.conf del container
  local root=$1 d=$2 f l
  local out="$d/lib"
  for f in "$root"/etc/ld.so.conf.d/*.conf; do
    [[ -f $f ]] || continue
    while IFS= read -r l; do
      if [[ $l == /* && -d $root$l ]]; then out+=":$root$l"; fi
    done <"$f"
  done
  printf '%s:%s:%s' "$out" "$root/usr/lib/aarch64-linux-gnu" "$root/usr/lib"
}

diretto_segna() { # diretto_segna programma motivo → d'ora in poi in proot (fino a glibc nuovo o tod diretto riprova)
  printf '%s\n' "$1" >>"$(diretto_no_file)"
  log "diretto: $1 non parte senza proot ($2): d'ora in poi con proot"
}

diretto_resti() { # diretto_resti caricatore programma [proc] → pid ancora vivi di quel programma partito senza proot
  local ld=$1 prog=$2 p=${3:-/proc} f c
  for f in "$p"/[0-9]*/cmdline; do
    c=$(tr "\\0" " " <"$f" 2>/dev/null) || continue
    if [[ $c == "$ld "* && " $c " == *" $prog "* ]]; then f=${f%/cmdline}; printf "%s\\n" "${f##*/}"; fi
  done
  return 0
}

diretto_chiudi_resti() { # i resti di un avvio caduto (Electron si riavvia da sé: una copia viva tiene il
  # blocco di "istanza unica" e quella in proot le passava la mano e usciva; app Electron dal menu, 23 ottobre)
  local -a pid
  mapfile -t pid < <(diretto_resti "$1" "$2")
  if ((${#pid[@]})); then
    log "diretto: chiudo ${#pid[@]} processi rimasti di $2"
    kill "${pid[@]}" 2>/dev/null || true
    sleep 1
    kill -9 "${pid[@]}" 2>/dev/null || true
  fi
}

diretto_casa() { # diretto_casa rootfs utente → la home dell'utente del container, con un percorso vero e corto
  # $PREFIX/.cx-<utente> → <rootfs>/home/<utente>. Con il percorso lungo del container (117 caratteri) il
  # socket della "copia unica" di Electron (~/.config/<app>/SingletonSocket) superava il limite dei socket
  # Unix (108): la seconda copia dell'app, quella del link di ritorno da Chromium, non parlava con la prima,
  # aspettava, la chiudeva e ripartiva da zero (accesso con Google lentissimo, 28 ottobre)
  # Dentro $PREFIX: proot-distro collega solo files/usr e files/home, e apt (in proot) non trovava i .deb
  # scaricati in files/.cx-<utente> dal launcher di ArtCraft (errore 100, 28 ottobre)
  local root=$1 u=$2 c
  c="$PREFIX/.cx-$u"
  if [[ -e $c && ! -L $c ]]; then   # c'è già qualcos'altro con quel nome: il percorso lungo, che va comunque
    printf '%s/home/%s' "$root" "$u"
    return 0
  fi
  if [[ $(readlink "$c" 2>/dev/null) != "$root/home/$u" ]]; then ln -sfn "$root/home/$u" "$c"; fi
  printf '%s' "$c"
}

diretto_run() { # diretto_run comando [argomenti] → esce come l'app; 97 = senza proot non si può (usare proot)
  local root d c real prog line u uid n zona rc=0 t0
  root=$(cx_rootfs) || return 97
  d=$(diretto_dir)
  diretto_pronto || return 97
  c=$(diretto_trova "$root" "$1") || return 97
  if [[ -f $(diretto_no_file) ]] && grep -qxF "$c" "$(diretto_no_file)"; then return 97; fi
  real=$(cx_resolve "$root" "$c")
  [[ -f $real && -x $real ]] || return 97
  local -a args=("${@:2}")
  prog=$c
  # script (#!): parte l'interprete del container, con lo script come argomento
  IFS= read -r line <"$real" 2>/dev/null || true
  if [[ $line == '#!'* ]]; then
    local -a sb
    read -r -a sb <<<"${line#\#!}"
    ((${#sb[@]})) || return 97
    if [[ ${sb[0]##*/} == env && ${#sb[@]} -ge 2 ]]; then
      prog=$(diretto_trova "$root" "${sb[1]}") || return 97
      args=("${sb[@]:2}" "$c" "${args[@]}")
    else
      prog=${sb[0]}
      args=("${sb[@]:1}" "$c" "${args[@]}")
    fi
    real=$(cx_resolve "$root" "$prog")
  fi
  real=$(realpath -m -s "$real")   # /usr/bin/../lib/x → /usr/lib/x (senza seguire i link: sono del container)
  diretto_elf "$real" || return 97
  # Chromium ed Electron: /dev/shm su Android non c'è (memoria condivisa in TMPDIR)
  local dir=${real%/*}
  if [[ -e $dir/chrome-sandbox || -e $dir/resources/app.asar || -e $dir/resources.pak ]]; then
    if [[ " ${args[*]} " != *" --disable-dev-shm-usage "* ]]; then args=(--disable-dev-shm-usage "${args[@]}"); fi
  fi
  u=$(cx_user)
  uid=$(awk -F: -v u="$u" '$1 == u { print $3 }' "$root/etc/passwd")
  n=${DISPLAY:-:0}
  n=${n#*:}
  n=${n%%.*}
  local pre="$d/tod-diretto.so $root$DIRETTO_FC" fuori=$DIRETTO_FUORI
  # dischi USB (tod-fs, come in tod-run): DOPO fakechroot. tod-fs ha i suoi execvp e posix_spawn che
  # chiamano quelli del glibc: davanti a fakechroot ogni programma lanciato così saltava fakechroot e
  # tod-diretto.so (app Electron dal menu, 23 ottobre: i processi figli partivano dal caricatore e morivano).
  # /media/usb resta fuori da fakechroot: lo traduce tod-fs
  if [[ -f $TMPDIR/tod-usb/lkl-attivo && -f $(usb_data)/tod-fs-glibc.so ]]; then
    pre+=" $(usb_data)/tod-fs-glibc.so"
    fuori+=:/media/usb
  fi
  local -a amb=(
    GLIBC_TUNABLES=glibc.pthread.rseq=0
    FAKECHROOT_BASE="$root" FAKECHROOT_ELFLOADER="$d/ld.so" FAKECHROOT_ELFLOADER_OPT_ARGV0=--argv0
    FAKECHROOT_EXCLUDE_PATH="$fuori"
    LD_PRELOAD="$pre" LD_LIBRARY_PATH="$(diretto_librerie "$root" "$d")"
    TOD_FS_RUN="$TMPDIR/tod-usb"
    TOD_DIRETTO_PROOT="$TOD_ROOT/share/diretto/tod-proot" TOD_DIRETTO_THOME="${TOD_TERMUX_HOME:-$HOME}"
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    # la home con un percorso vero: chi apre i file senza il glibc (i programmi fatti con Bun, rustix
    # nelle app Rust come ArtCraft) non passa da fakechroot, e /home/dex per lui non esiste. I
    # programmi Bun non salvavano più i loro dati, gli aggiornamenti di ArtCraft nemmeno (26 ottobre).
    # E corto (diretto_casa): i socket Unix stanno sotto i 108 caratteri. Lo stesso percorso va anche in proot
    HOME="$(diretto_casa "$root" "$u")" USER="$u" LOGNAME="$u" SHELL=/bin/bash
    TMPDIR="$TMPDIR" XDG_RUNTIME_DIR="$TMPDIR/xdg-${uid:-$u}"
    GCONV_PATH="$root/usr/lib/aarch64-linux-gnu/gconv"
    PULSE_SERVER=127.0.0.1 NO_AT_BRIDGE=1 MOZ_FAKE_NO_SANDBOX=1 APPIMAGE_EXTRACT_AND_RUN=1
  )
  local f l
  for f in locale session gpu; do
    [[ -f $root/etc/tod/$f.env ]] || continue
    while IFS= read -r l; do
      case $l in DISPLAY=* | PULSE_SERVER=*) ;; [A-Za-z_]*=*) amb+=("$l") ;; esac
    done <"$root/etc/tod/$f.env"
  done
  # il socket di X per intero: /tmp per l'app è quello del container, e il nome resta sotto i 108 caratteri
  amb+=(DISPLAY="$TMPDIR/.X11-unix/X${n:-0}")
  zona=$(prop persist.sys.timezone)
  if [[ -n $zona && -f $root/usr/share/zoneinfo/$zona ]]; then amb+=(TZDIR="$root/usr/share/zoneinfo" TZ="$zona"); fi
  if [[ -n ${DESKTOP_STARTUP_ID:-} ]]; then amb+=(DESKTOP_STARTUP_ID="$DESKTOP_STARTUP_ID"); fi
  local bus
  bus=$(cx_session_bus)
  if [[ -n $bus ]]; then amb+=(DBUS_SESSION_BUS_ADDRESS="$bus"); fi
  # il desktop: Chromium ed Electron scelgono da qui dove tenere le password. Senza, "desktop sconosciuto"
  # → basic_text: le app Electron non salvavano l'accesso e a ogni avvio chiedevano di rifarlo (28 ottobre)
  if [[ -n ${XDG_CURRENT_DESKTOP:-} ]]; then amb+=(XDG_CURRENT_DESKTOP="$XDG_CURRENT_DESKTOP"); fi
  mkdir -p "$TMPDIR/xdg-${uid:-$u}" && chmod 700 "$TMPDIR/xdg-${uid:-$u}"
  # librerie che il caricatore non trova (RPATH assoluti, cartelle fuori da ld.so.conf): subito in proot
  if env -i "${amb[@]}" "$d/ld.so" --list "$real" 2>&1 | grep -q 'not found'; then
    diretto_segna "$c" "librerie mancanti"
    return 97
  fi
  t0=$SECONDS
  env -i "${amb[@]}" "$d/ld.so" --argv0 "$prog" "$real" "${args[@]}" || rc=$?
  # caduto subito (chiamata vietata 159, crash): segnato, si riparte in proot. 127 no: lo dà anche
  # un comando che non trova un altro comando (sh -c ...)
  case $rc in
    132 | 133 | 134 | 135 | 139 | 159)
      if ((SECONDS - t0 < DIRETTO_ENTRO)); then
        diretto_segna "$c" "uscita $rc"
        diretto_chiudi_resti "$d/ld.so" "$real"
        return 97
      fi
      ;;
  esac
  return "$rc"
}

diretto_cli() { # tod diretto [stato|on|off|prepara|riprova]
  case ${1:-stato} in
    on | si | sì) conf_set DIRETTO 1; diretto_prepara ;;
    off | no) conf_set DIRETTO 0 ;;
    prepara) conf_set DIRETTO 1; diretto_prepara || die "$(t dir_no_prep)" ;;
    riprova) rm -f "$(diretto_no_file)" ;;   # le app segnate si riprovano senza proot
    stato | status) ;;
    *) die "tod diretto stato|on|off|prepara|riprova" ;;
  esac
  local s
  if ! diretto_on; then s=$(t dir_spento); elif diretto_pronto; then s=$(t dir_pronto); else s=$(t dir_non_pronto); fi
  ok "$(t dir_state "$s")"
  if [[ -s $(diretto_no_file) ]]; then info "$(t dir_proot "$(sort -u "$(diretto_no_file)" | tr '\n' ' ')")"; fi
}
