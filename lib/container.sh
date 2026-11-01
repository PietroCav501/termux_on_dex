# shellcheck shell=bash
# =============================================================================
#  Container "sidecar" (proot-distro): per le app che Termux nativo non ha
#  (LibreOffice, ecc.). Le app girano sul display del desktop nativo, con audio
#  e GPU (Freedreno-KGSL per container), e compaiono nel menu come app native.
#
#  Differenze rispetto alla v1:
#   - ambiente pulito (tod-run): niente PATH/LD_* di Termux dentro il container,
#     che causava errori tipo "libvulkan_freedreno.so is not accessible"
#   - script eseguiti da file (niente problemi di quoting con proot-distro)
#   - esportazione precisa: solo i .desktop e le icone dei pacchetti installati
# =============================================================================

cx_distro() { conf_get CX_DISTRO debian; }
cx_user() { conf_get CX_USER dex; }

cx_rootfs() { # proot-distro 5: containers/<nome>/rootfs · proot-distro 4: installed-rootfs/<nome>
  local base="$PREFIX/var/lib/proot-distro" d p
  d=$(cx_distro)
  for p in "$base/containers/$d/rootfs" "$base/installed-rootfs/$d"; do
    if [[ -d $p/etc ]]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

cx_installed() { cx_rootfs >/dev/null; }

cx_locale() { # it-IT → it_IT.UTF-8
  local l
  l=$(prop persist.sys.locale)
  if [[ -z $l ]]; then l=$(prop ro.product.locale); fi
  l=${l//-/_}
  if [[ $l =~ ^[a-z]{2}_[A-Z]{2}$ ]]; then printf '%s.UTF-8' "$l"; fi
}

cx_root() { # cx_root [argomenti...] < script   → bash come root nel container
  local f rc=0
  f=$(mktemp "$TMPDIR/tod-cx-XXXXXX")
  cat >"$f"
  chmod 700 "$f"
  proot-distro login --shared-tmp "$(cx_distro)" -- /bin/bash "/tmp/${f##*/}" "$@" || rc=$?
  rm -f "$f"
  return "$rc"
}

cx_write() { # cx_write /percorso/nel/container [permessi] < contenuto
  local dst=$1 mode=${2:-644} root
  root=$(cx_rootfs) || return 1
  mkdir -p "$root$(dirname "$dst")"
  cat >"$root$dst"
  chmod "$mode" "$root$dst"
}

cx_run() { # cx_run [--proot] [--raw] [comando...]  → utente normale, ambiente pulito, GPU del container
  cx_installed || die "$(t cx_missing)"
  # prima senza proot (lib/diretto.sh); --proot, --raw (prove della GPU) e la shell sempre in proot
  local proot=0
  if [[ ${1:-} == --proot ]]; then
    proot=1
    shift
    if [[ ${1:-} == -- ]]; then shift; fi
  fi
  # proot-distro 5 monta già /data/data/com.termux (quindi la home di Termux); la 4 no
  local -a bind=()
  if [[ $(cx_rootfs) == */installed-rootfs/* ]]; then bind=(--bind "$HOME:$HOME"); fi
  # cursore di attesa: l'id di avvio (startup notification) arriva fino all'app, che lo spegne
  # appena compare la sua finestra; proot-distro altrimenti parte con un ambiente pulito
  if [[ -n ${DESKTOP_STARTUP_ID:-} ]]; then
    bind+=(--env "DESKTOP_STARTUP_ID=$DESKTOP_STARTUP_ID")
    # molte app (Electron, WebKit) non lo spengono da sole: lo si spegne alla loro prima finestra
    cx_startup_watch "$DESKTOP_STARTUP_ID"
  fi
  local bus
  bus=$(cx_session_bus)
  if [[ -n $bus ]]; then bind+=(--env "DBUS_SESSION_BUS_ADDRESS=$bus"); fi
  # e il desktop (portachiavi di Chromium/Electron: vedi diretto_run)
  if [[ -n ${XDG_CURRENT_DESKTOP:-} ]]; then bind+=(--env "XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"); fi
  if ((!proot && $#)) && [[ $1 != --raw ]] && diretto_on; then
    local rc=0
    diretto_run "$@" || rc=$?
    if ((rc != 97)); then return "$rc"; fi
  fi
  proot-distro login --user "$(cx_user)" --shared-tmp "${bind[@]}" "$(cx_distro)" \
    -- /usr/local/bin/tod-run "$@"
}

cx_session_bus() { # indirizzo del D-Bus del desktop, se il socket c'è: proot-distro e diretto_run
  # partono con un ambiente pulito, e senza indirizzo le app si avviano un loro bus privato
  # (niente icona nel vassoio, niente notifiche: ArtCraft, 26 ottobre)
  local a=${DBUS_SESSION_BUS_ADDRESS:-} p
  if [[ $a != unix:path=* ]]; then return 0; fi
  p=${a#unix:path=}
  p=${p%%,*}
  if [[ -S $p ]]; then printf '%s\n' "$a"; fi
}

cx_startup_watch() { # in sottofondo: spegne il cursore di attesa alla prima finestra dell'app
  (setsid python3 "$TOD_ROOT/share/tod-startup-done.py" "$1" </dev/null >/dev/null 2>&1 &)
}

# Strumenti di servizio delle app del container, senza voce nel menu. zenity: le app Rust (rfd: la suite Craft,
# PdfCraft "Aggiungi immagine") aprono la finestra dei file con il portale del desktop o, se manca, con zenity;
# in Termux il portale non c'è, e senza zenity la finestra non si apriva affatto (31 ottobre).
CX_AIUTI="zenity"

cx_install() {
  local u loc
  u=$(cx_user)
  loc=$(cx_locale)
  pkg_install proot-distro || return 1
  progress_note 3 "$(t tui_rootfs)"
  if ! cx_installed; then
    if [[ -d $PREFIX/var/lib/proot-distro/containers/$(cx_distro) || -d $PREFIX/var/lib/proot-distro/installed-rootfs/$(cx_distro) ]]; then
      proot-distro remove "$(cx_distro)" || true   # residuo di un'installazione interrotta
    fi
    retry 2 10 proot-distro install "$(cx_distro)" || return 1
  fi
  progress_note 25 "$(t tui_cx_setup)"
  cx_root "$u" "$loc" "$CX_AIUTI" <<'EOF' || return 1
set -e
export DEBIAN_FRONTEND=noninteractive
APT="-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
if [ -e /tmp/tod-progress ]; then exec 3>>/tmp/tod-progress; APT="$APT -o APT::Status-Fd=3"; fi
apt-get update -q
apt-get $APT full-upgrade
want="sudo locales dbus-x11 xdg-utils ca-certificates mesa-utils vulkan-tools libgl1-mesa-dri
      mesa-vulkan-drivers libegl-mesa0 libglx-mesa0 libgbm1 mesa-libgallium pulseaudio-utils
      libpulse0 fonts-dejavu-core adwaita-icon-theme $3"
pk=""
for p in $want; do
  if apt-cache show "$p" >/dev/null 2>&1; then pk="$pk $p"; fi
done
apt-get $APT install --no-install-recommends $pk
u="$1"; loc="$2"
id -u "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
for g in sudo audio video; do
  if getent group "$g" >/dev/null; then usermod -aG "$g" "$u"; fi
done
echo "$u ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-tod
chmod 440 /etc/sudoers.d/90-tod
mkdir -p /etc/tod /etc/chromium.d
if [ -n "$loc" ] && grep -q "^# *$loc " /etc/locale.gen 2>/dev/null; then
  sed -i "s/^# *\($loc .*\)/\1/" /etc/locale.gen
  locale-gen >/dev/null
  echo "LANG=$loc" > /etc/tod/locale.env
else
  echo "LANG=C.UTF-8" > /etc/tod/locale.env
fi
# Chromium/Electron in proot: niente sandbox a namespace
echo 'export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox --test-type"' > /etc/chromium.d/tod
EOF
  cx_install_runner
  files_cx_user_dirs || true
}

cx_install_runner() {
  cx_write /usr/local/bin/tod-run 755 < <(sed "s|TOD_FS_SO_PLACEHOLDER|${TOD_TERMUX_HOME:-$HOME}/.local/share/tod-usb/tod-fs-glibc.so|" <<'EOF'
#!/bin/sh
# tod-run - generato da Termux On DeX.
# Avvia un programma del container con ambiente pulito (niente percorsi o
# librerie di Termux) e con il profilo GPU del container.
unset LD_PRELOAD LD_LIBRARY_PATH PREFIX TERMUX_VERSION
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# dischi USB letti da LKL: /media/usb/<nome> come cartelle vere anche qui (tod-fs.c per glibc; /tmp è $TMPDIR)
F=TOD_FS_SO_PLACEHOLDER
if [ -f "$F" ] && [ -f /tmp/tod-usb/lkl-attivo ]; then export LD_PRELOAD="$F" TOD_FS_RUN=/tmp/tod-usb; fi
E=${TOD_ETC:-/etc/tod}
for f in "$E/locale.env" "$E/session.env"; do
  if [ -f "$f" ]; then set -a; . "$f"; set +a; fi
done
if [ "${1:-}" = "--raw" ]; then
  shift
elif [ -f "$E/gpu.env" ]; then
  set -a; . "$E/gpu.env"; set +a
fi
export DISPLAY="${DISPLAY:-:0}" PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
export NO_AT_BRIDGE=1 MOZ_FAKE_NO_SANDBOX=1
# gli AppImage chiedono FUSE, che in proot non c'è: si estraggono e partono lo stesso
export APPIMAGE_EXTRACT_AND_RUN=1
export XDG_RUNTIME_DIR="/tmp/xdg-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
cd "$HOME" 2>/dev/null || true
if [ "$#" -eq 0 ]; then exec "${SHELL:-/bin/bash}" -l; fi
exec "$@"
EOF
)
  # una sola distribuzione: apt, dpkg e il doppio clic sui .deb aggiornano da soli il menu Start
  local tod_env
  tod_env="env -i HOME=\"$(files_termux_home)\" PREFIX=\"$PREFIX\" TMPDIR=\"$TMPDIR\" PATH=\"$PREFIX/bin\" LANG=\"\${LANG:-C.UTF-8}\" DISPLAY=\"\${DISPLAY:-:0}\""
  cx_write /usr/local/bin/tod-sync-menu 755 <<EOF
#!/bin/sh
# tod-sync-menu - generato da Termux On DeX: voci del menu Start allineate ai pacchetti (in sottofondo)
if [ "\${TOD_MENU_SYNC:-1}" != 0 ] && [ -x "$PREFIX/bin/tod" ]; then
  $tod_env setsid "$PREFIX/bin/bash" "$PREFIX/bin/tod" cx sync </dev/null >/dev/null 2>&1 &
fi
exit 0
EOF
  cx_write /etc/apt/apt.conf.d/99tod-menu 644 <<'EOF'
// Generato da Termux On DeX: dopo ogni installazione o rimozione il menu Start si aggiorna
DPkg::Post-Invoke { "if [ -x /usr/local/bin/tod-sync-menu ]; then /usr/local/bin/tod-sync-menu; fi"; };
EOF
  # una app, un solo sistema: apt di Debian rifiuta le app che Termux ha già (anche da
  # Synaptic, pkexec o un launcher). Contano i pacchetti chiesti, non le dipendenze.
  cx_write /usr/local/bin/tod-app-guard 755 <<EOF
#!/bin/sh
# tod-app-guard - generato da Termux On DeX (DPkg::Pre-Install-Pkgs, protocollo 2)
[ "\${TOD_MENU_SYNC:-1}" = 0 ] && exec cat >/dev/null   # tod apt ha già controllato
AWK="$TOD_ROOT/share/tod-app-keys.awk"
[ -r "\$AWK" ] || exec cat >/dev/null
cmd="" new=""
while IFS= read -r l; do
  case \$l in
    CommandLine::AsString=*) cmd=\$(printf '%s' "\${l#CommandLine::AsString=}" | sed 's/%20/ /g; s/%3[dD]/=/g; s/%25/%/g') ;;
    "") break ;;
  esac
done
while read -r pkg old dir ver act; do   # "nome - < versione file.deb": installazione nuova
  case \$act in *.deb) ;; *) continue ;; esac
  if [ "\$old" = - ] && [ "\$dir" = "<" ]; then new="\$new \$pkg"; fi
done
[ -n "\$cmd" ] && [ -n "\$new" ] || exit 0
asked="" skip=0
for w in \$cmd; do
  if [ \$skip = 1 ]; then skip=0; continue; fi
  case \$w in
    -o | -c | -t | --option | --config-file | --target-release) skip=1 ;;
    -* | apt | apt-get | aptitude | install | reinstall) ;;
    *.deb) asked="\$asked \$(dpkg-deb -f "\$w" Package 2>/dev/null)" ;;
    *) asked="\$asked \${w%%=*}" ;;
  esac
done
keys=\$(grep -H '/share/applications/[^/]*\.desktop\$' "$PREFIX"/var/lib/dpkg/info/*.list 2>/dev/null |
  awk -f "\$AWK" -v mode=installed -v root=)
rc=0
for p in \$new; do
  case " \$asked " in *" \${p%%:*} "*) ;; *) continue ;; esac
  k=\$(printf '%s\n' "\$p" | awk -f "\$AWK" -v mode=names)
  o=\$(printf '%s\n' "\$keys" | awk -F '\t' -v k="\$k" '\$1 == k { print \$2; exit }')
  if [ -n "\$o" ]; then
    echo "E: \${p%%:*}: $(t apt_already_short "\$o")" >&2
    rc=1
  fi
done
exit \$rc
EOF
  cx_write /etc/apt/apt.conf.d/98tod-app-guard 644 <<'EOF'
// Generato da Termux On DeX: la stessa app non si installa in due sistemi
DPkg::Pre-Install-Pkgs { "/usr/local/bin/tod-app-guard"; };
DPkg::Tools::Options::/usr/local/bin/tod-app-guard::Version "2";
EOF
  # link e file aperti dalle app di Debian (es. "Accedi con Google" delle app Electron): li apre il desktop,
  # con il suo browser, tramite share/tod-open-host (FIFO nella /tmp condivisa)
  cx_write /usr/local/bin/xdg-open 755 <<'EOF'
#!/bin/sh
# xdg-open - generato da Termux On DeX: apre con le app del desktop (servizio tod-open-host)
# in proot /tmp è la /tmp di Termux; senza proot (lib/diretto.sh) /tmp è quella del container e la
# /tmp di Termux arriva come TMPDIR
F=/tmp/tod-open.fifo
if [ ! -p "$F" ] && [ -p "${TMPDIR:-/tmp}/tod-open.fifo" ]; then F=$TMPDIR/tod-open.fifo; fi
if [ $# -eq 1 ] && [ -p "$F" ]; then
  x=$1
  case $x in
    *://* | mailto:*) ;;
    *) x=$(realpath -- "$x" 2>/dev/null) || x=$1 ;;
  esac
  if timeout 3 sh -c 'printf "%s\n" "$1" >"$2"' _ "$x" "$F" 2>/dev/null; then exit 0; fi
fi
exec /usr/bin/xdg-open "$@"
EOF
  cx_write "/home/$(cx_user)/.local/share/applications/tod-host-open.desktop" 644 <<'EOF'
[Desktop Entry]
Type=Application
Name=Browser del desktop
Exec=/usr/local/bin/xdg-open %u
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/mailto;text/html;
EOF
  local mime h
  h="$(cx_rootfs)/home/$(cx_user)/.config"
  mime="$h/mimeapps.list"
  if [[ -d $h ]] && ! grep -q '^x-scheme-handler/https=tod-host-open.desktop' "$mime" 2>/dev/null; then
    if ! grep -q '^\[Default Applications\]' "$mime" 2>/dev/null; then printf '[Default Applications]\n' >>"$mime"; fi
    sed -i '/^x-scheme-handler\/\(http\|https\|mailto\)=/d; /^text\/html=/d' "$mime"
    sed -i '/^\[Default Applications\]/a x-scheme-handler/http=tod-host-open.desktop\nx-scheme-handler/https=tod-host-open.desktop\nx-scheme-handler/mailto=tod-host-open.desktop\ntext/html=tod-host-open.desktop' "$mime"
  fi
  # tod anche dal terminale della distribuzione (gira nell'ambiente del desktop)
  cx_write /usr/local/bin/tod 755 <<EOF
#!/bin/sh
# tod - generato da Termux On DeX
exec $tod_env "$PREFIX/bin/bash" "$PREFIX/bin/tod" "\$@"
EOF
  # pkexec: nel container non c'è polkit, e l'utente ha già sudo senza password. Serve alle app
  # che si installano o aggiornano da sole (es. ArtCraft Launcher: senza, ripiegava su AppImage
  # che il desktop non usa). Dopo, le voci del menu di Termux si allineano (tod cx sync).
  # Acceso di serie (17 ottobre, Pietro): non dà niente in più del sudo che c'è già, e senza le app
  # grafiche che chiedono i permessi non funzionano. Si spegne con tod cx pkexec off (CX_PKEXEC=0).
  # ArtCraft Launcher 0.8.1 lo cerca solo in /usr/bin, /bin, /usr/sbin e /sbin (non nel PATH): senza
  # il collegamento in /usr/bin rimetteva le app come AppImage e i .deb restavano vecchi (26 ottobre).
  # Un pkexec vero (polkit installato) non si tocca. Collegamento relativo: senza proot il kernel
  # segue un /usr/local/... assoluto fuori dal container (fakechroot traduce solo il primo percorso)
  local root
  root=$(cx_rootfs) || return 0
  if [[ $(conf_get CX_PKEXEC 1) != 1 ]]; then
    if grep -q 'generato da Termux On DeX' "$root/usr/local/bin/pkexec" 2>/dev/null; then
      rm -f "$root/usr/local/bin/pkexec"
    fi
  fi
  case $(readlink "$root/usr/bin/pkexec" 2>/dev/null) in
    ../local/bin/pkexec | /usr/local/bin/pkexec) rm -f "$root/usr/bin/pkexec" ;;
  esac
  if [[ $(conf_get CX_PKEXEC 1) != 1 ]]; then return 0; fi
  if [[ -d $root/usr/bin && ! -e $root/usr/bin/pkexec && ! -L $root/usr/bin/pkexec ]]; then ln -s ../local/bin/pkexec "$root/usr/bin/pkexec"; fi
  cx_write /usr/local/bin/pkexec 755 <<EOF
#!/bin/sh
# pkexec - generato da Termux On DeX (sudo al posto di polkit)
while [ \$# -gt 0 ]; do
  case \$1 in
    --version) echo "pkexec version 126"; exit 0 ;;   # chi controlla che polkit ci sia
    --disable-internal-agent | --keep-cwd) shift ;;
    --user | -u) shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
sudo -n -- "\$@"
rc=\$?
/usr/local/bin/tod-sync-menu   # menu aggiornato in sottofondo: chi ha chiesto non aspetta
exit \$rc
EOF
}

cx_sync_look() { # le app Debian con lo stesso aspetto del desktop: tema, icone, puntatori e font di Termux
  local root d n src
  root=$(cx_rootfs) || return 0
  mkdir -p "$root/usr/share/themes" "$root/usr/share/icons" "$root/usr/local/share/fonts"
  # GTK le sceglie per nome (xsettings): basta che nel container esistano con lo stesso nome
  for d in "$PREFIX"/share/themes/Fluent* "$PREFIX"/share/icons/Fluent* "$PREFIX"/share/icons/.Fluent* \
    "$(files_termux_home)"/.local/share/icons/* "$(files_termux_home)"/.icons/* "$(files_termux_home)"/.themes/* \
    "$(files_termux_home)"/.local/share/themes/*; do
    [[ -d $d ]] || continue
    n=${d##*/}
    case $d in */themes/*) src="$root/usr/share/themes/$n" ;; *) src="$root/usr/share/icons/$n" ;; esac
    if [[ $n == hicolor ]]; then continue; fi
    if [[ -L $src || ! -e $src ]]; then ln -sfn "$d" "$src"; fi
  done
  for d in "$root"/usr/share/themes/DeX-OS* "$root"/usr/share/icons/DeX-OS* "$root"/usr/share/icons/Fluent*; do   # tolti da tod
    if [[ -L $d && ! -e $d ]]; then rm -f "$d"; fi
  done
  if [[ -d $PREFIX/share/fonts/tod-inter ]]; then ln -sfn "$PREFIX/share/fonts/tod-inter" "$root/usr/local/share/fonts/tod-inter"; fi
}

cx_sync_session_env() {
  printf 'DISPLAY=%s\nPULSE_SERVER=127.0.0.1\n' "${DISPLAY:-:0}" | cx_write /etc/tod/session.env 644
}

# ----------------------------------------------------------------------------
#  GPU nel container: Mesa con Freedreno-KGSL di lfdevs/mesa-for-android-container
# ----------------------------------------------------------------------------
cx_os() { # → "id codename"
  local root f id code
  root=$(cx_rootfs) || return 1
  f="$root/etc/os-release"
  if [[ ! -f $f ]]; then f="$root/usr/lib/os-release"; fi
  id=$(sed -n 's/^ID=//p' "$f" | tr -d '"')
  code=$(sed -n 's/^VERSION_CODENAME=//p' "$f" | tr -d '"')
  printf '%s %s' "$id" "$code"
}

cx_mesa_suffix() { # id codename → suffisso del pacchetto lfdevs
  case "$1:$2" in
    debian:trixie) echo debian_trixie_arm64 ;;
    ubuntu:noble) echo ubuntu_noble_arm64 ;;
    ubuntu:questing) echo ubuntu_questing_arm64 ;;
    ubuntu:resolute) echo ubuntu_resolute_arm64 ;;
    *) return 1 ;;
  esac
}

cx_gpu_install() {
  [[ $GPU_FAMILY == adreno ]] || return 0
  have jq || pkg_install jq || return 1
  local os id code suffix rel tag line url sha name
  os=$(cx_os) || return 1
  read -r id code <<<"$os"
  if ! suffix=$(cx_mesa_suffix "$id" "$code"); then
    warn "$(t cx_gpu_unsupported "$id $code")"
    return 0
  fi
  if rel=$(gh_release "$LFDEVS_CX_REPO" mesa-); then
    tag=$(jq -r .tag_name <<<"$rel")
    line=$(gh_asset "$rel" "_${suffix}\\.tar\\.gz\$")
    if [[ -z $line ]]; then err "$(t gpu_asset_missing "$suffix" "$tag")"; return 1; fi
    IFS='|' read -r url sha name <<<"$line"
    if [[ -z $sha ]]; then sha=$(gh_body_sha "$rel" "$name"); fi
  else
    tag=$LFDEVS_CX_FALLBACK_TAG
    warn "$(t gh_fallback "$tag")"
    name="mesa-for-android-container_${tag#mesa-}_${suffix}.tar.gz"
    url="https://github.com/$LFDEVS_CX_REPO/releases/download/$tag/$name"
    sha=${LFDEVS_CX_FALLBACK[$suffix]:-}
  fi
  net_download "$url" "$TOD_CACHE_DIR/$name" "$sha" || return 1
  cp -f "$TOD_CACHE_DIR/$name" "$TMPDIR/tod-mesa-cx.tar.gz"
  if ! cx_root /tmp/tod-mesa-cx.tar.gz <<'EOF'; then
set -e
tar --no-same-owner -xzf "$1" -C /
ldconfig
# apt non deve rimettere la Mesa di Debian sopra quella per Android
for p in libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers; do
  if dpkg -s "$p" >/dev/null 2>&1; then apt-mark hold "$p" >/dev/null; fi
done
EOF
    rm -f "$TMPDIR/tod-mesa-cx.tar.gz"
    return 1
  fi
  rm -f "$TMPDIR/tod-mesa-cx.tar.gz"
  conf_set CX_MESA_TAG "$tag"
}

cx_profile_env() {
  case $1 in
    kgsl) echo MESA_LOADER_DRIVER_OVERRIDE=kgsl ;;
    zink | zink-sw)
      printf '%s\n' MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink TU_DEBUG=noconform \
        VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
      # copia del fotogramma col processore: niente superfici incomplete (vedi gpu_glitchy)
      if [[ $1 == zink-sw ]]; then echo MESA_VK_WSI_DEBUG=sw; fi
      ;;
    # LIBGL_ALWAYS_SOFTWARE: virpipe è un driver "software" di Mesa (manda i comandi a virgl, cioè alla
    # GPU): senza, Mesa di Debian prova prima i driver via DRI3 e virgl non viene usato
    virgl) printf '%s\n' LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.0 ;;
    llvmpipe) echo LIBGL_ALWAYS_SOFTWARE=1 ;;
    *) return 1 ;;
  esac
}

cx_gpu_probe() { # sceglie il profilo GPU del container → /etc/tod/gpu.env
  local p out r best=""
  local -a cands=() envs=()
  if [[ $GPU_FAMILY == adreno && -n $(conf_get CX_MESA_TAG) ]]; then
    # Adreno 8xx: kgsl e zink diretto lasciano blocchi neri in Chromium/Electron (gpu_glitchy);
    # con glamor nel server X zink diretto (DRI3) è pulito e molto più fluido della copia software
    if gpu_glitchy kgsl; then
      if gpu_glamor; then cands+=(zink zink-sw kgsl); else cands+=(zink-sw kgsl zink); fi
    else
      cands+=(kgsl zink)
    fi
  fi
  if have virgl_test_server_android; then cands+=(virgl); fi
  cands+=(llvmpipe)
  : >"$TOD_STATE_DIR/cx-gpu-probe.txt"
  local k=0
  for p in "${cands[@]}"; do
    k=$((k + 1))
    progress_note "$((k * 90 / ${#cands[@]}))" "$(t tui_gpu_test "$p")"
    mapfile -t envs < <(cx_profile_env "$p")
    if [[ $p == virgl ]]; then virgl_start || continue; fi
    if out=$(cx_run --raw env "${envs[@]}" timeout 30 glxinfo -B 2>&1 </dev/null); then :; else out=""; fi
    r=$(sed -n 's/^[[:space:]]*OpenGL renderer string:[[:space:]]*//p' <<<"$out" | sed -n 1p)
    if [[ -z $r ]]; then
      # glxinfo non mostra mai la sua finestra, e con virpipe Mesa di Debian si ferma su X_GetImage
      # (BadMatch): virgl veniva scartato anche se funziona (S20+, 17 ottobre). Una finestra vera:
      out=$(cx_run --raw env "${envs[@]}" timeout -s INT 6 glxgears -info 2>&1 </dev/null) || true
      r=$(sed -n 's/^GL_RENDERER[[:space:]]*=[[:space:]]*//p' <<<"$out" | sed -n 1p)
    fi
    if [[ $p == virgl ]]; then virgl_stop; fi
    log "cx probe $p: ${r:-KO}"
    if [[ -n $r ]] && { [[ $p == llvmpipe ]] || [[ ! ${r,,} =~ llvmpipe|softpipe ]]; }; then
      printf '%s|ok|%s\n' "$p" "$r" >>"$TOD_STATE_DIR/cx-gpu-probe.txt"
      best=$p
      break
    fi
    printf '%s|ko|\n' "$p" >>"$TOD_STATE_DIR/cx-gpu-probe.txt"
  done
  best=${best:-llvmpipe}
  cx_profile_env "$best" | cx_write /etc/tod/gpu.env 644
  conf_set CX_GPU_PROFILE "$best"
}

cx_gpu_setup() { # passo dell'installer
  cx_gpu_install || warn "$(t cx_gpu_fail)"
  x11_with_server cx_gpu_probe
}

# ----------------------------------------------------------------------------
#  Pacchetti del container ed esportazione nel menu del desktop nativo
# ----------------------------------------------------------------------------
cx_pkg_list() {
  local root
  root=$(cx_rootfs) || return 0
  awk '/^Package: /{p = $2} /^Status: .* installed$/{print p}' "$root/var/lib/dpkg/status" | sort -u
}

cx_pkg_install() { # cx_pkg_install pacchetto...
  (($#)) || return 0
  cx_installed || { err "$(t cx_missing)"; return 1; }
  local before after p
  local -a new=()
  before=$(cx_pkg_list)
  cx_root "$@" <<'EOF' || return 1
set -e
export DEBIAN_FRONTEND=noninteractive
ST=""
if [ -e /tmp/tod-progress ]; then exec 3>>/tmp/tod-progress; ST="-o APT::Status-Fd=3"; fi
apt-get update -q || true
apt-get install -y -q $ST -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
EOF
  after=$(cx_pkg_list)
  mapfile -t new < <(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')
  # se erano già installati, esporto comunque quelli richiesti (per un .deb: il nome del pacchetto)
  if ((${#new[@]} == 0)); then
    if [[ -n ${CX_EXPORT_NAMES:-} ]]; then read -ra new <<<"$CX_EXPORT_NAMES"; else new=("$@"); fi
  fi
  cx_export_pkgs "${new[@]}"
  ok "$(t cx_installed_pkgs "${CX_EXPORT_NAMES:-$*}")"
}

cx_pkg_remove() {
  (($#)) || return 0
  cx_root "$@" <<'EOF' || return 1
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get remove -y -q "$@"
apt-get autoremove -y -q || true
EOF
  cx_prune_exports
}

cx_dpkg_list_file() { # file .list di dpkg per un pacchetto (anche multi-arch)
  local root=$1 pkg=$2 f
  for f in "$root/var/lib/dpkg/info/$pkg.list" "$root/var/lib/dpkg/info/$pkg:arm64.list"; do
    if [[ -f $f ]]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

cx_resolve() { # cx_resolve rootfs percorso → file reale sull'host (segue i link assoluti)
  local root=$1 src=$1$2 tgt i
  for ((i = 0; i < 8; i++)); do
    [[ -L $src ]] || break
    tgt=$(readlink "$src")
    if [[ $tgt == /* ]]; then src=$root$tgt; else src=$(dirname "$src")/$tgt; fi
  done
  printf '%s' "$src"
}

cx_export_pkgs() { # .desktop + icone dei pacchetti → ~/.local/share
  local root pkg list path src dst
  root=$(cx_rootfs) || return 0
  local share="$HOME/.local/share" exp="$TOD_STATE_DIR/cx-exports" native
  mkdir -p "$share/applications" "$exp"
  # una app sola nel menu: se Termux ha già la stessa app, quella del container non compare
  native=$(app_keys_termux | cut -f1 | sort -u)
  # nello Start solo ciò che l'utente ha scelto: le app arrivate come dipendenze no
  # (es. "Impostazioni di sistema KDE", il visualizzatore di ImageMagick)
  local auto
  auto=$(awk '/^Package: /{p = $2} /^Auto-Installed: 1/{print p}' "$root/var/lib/apt/extended_states" 2>/dev/null) || auto=""
  # pacchetti che tod usa per conto suo, con una voce propria: Dischi parla con la macchina dei
  # dischi USB (tod-dischi.desktop); la sua voce di Debian aprirebbe un Dischi senza dischi
  auto+=$'\ngnome-disk-utility'

  for pkg in "$@"; do
    list=$(cx_dpkg_list_file "$root" "$pkg") || continue
    if grep -qxF "$(app_key "$pkg")" <<<"$native" || grep -qxF "$pkg" <<<"$auto"; then
      log "menu: $pkg è un doppione di Termux o una dipendenza, niente voce"
      if [[ -f $exp/$pkg.files ]]; then
        while IFS= read -r path; do rm -f "$path"; done <"$exp/$pkg.files"
        rm -f "$exp/$pkg.files"
      fi
      continue
    fi
    # già esportato, e né il pacchetto né il codice che fa le voci sono cambiati da allora: niente da
    # rifare (dopo ogni installazione nel container si riallinea tutto lo Start: rifarle tutte costava
    # decine di secondi sul S20+, e l'app nuova compariva tardi)
    # E le voci devono esserci ancora: un AppImage dello stesso id (ArtCraft Launcher senza pkexec) usa
    # lo stesso nome di voce, e toglierlo la cancellava; il .deb restava senza voce (26 ottobre)
    if [[ ${CX_EXPORT_FORCE:-0} != 1 && -s $exp/$pkg.files && $exp/$pkg.files -nt $list &&
      $exp/$pkg.files -nt $TOD_ROOT/lib/container.sh ]] && cx_files_exist "$exp/$pkg.files"; then continue; fi
    : >"$exp/$pkg.files"
    # 1ª passata: icone e pixmap (i .desktop possono riferirsi ai pixmap copiati)
    while IFS= read -r path; do
      case $path in
        /usr/share/icons/* | /usr/share/pixmaps/*)
          src=$(cx_resolve "$root" "$path")
          [[ -f $src ]] || continue
          dst="$share${path#/usr/share}"
          mkdir -p "$(dirname "$dst")"
          cp -f "$src" "$dst" 2>/dev/null || continue
          printf '%s\n' "$dst" >>"$exp/$pkg.files"
          ;;
      esac
    done <"$list"
    # 2ª passata: voci del menu
    while IFS= read -r path; do
      case $path in
        /usr/share/applications/*.desktop)
          if grep -qxF "$(app_key "${path##*/}")" <<<"$native"; then continue; fi
          if dst=$(cx_export_desktop "$root" "$path"); then printf '%s\n' "$dst" >>"$exp/$pkg.files"; fi
          ;;
      esac
    done <"$list"
    if [[ ! -s $exp/$pkg.files ]]; then rm -f "$exp/$pkg.files"; fi
  done
  desktop_refresh_caches
}

cx_files_exist() { # cx_files_exist elenco → vero se ogni file dell'elenco c'è
  local f
  while IFS= read -r f; do
    if [[ ! -e $f ]]; then return 1; fi
  done <"$1"
}

cx_export_desktop() { # → stampa il percorso del .desktop creato
  local root=$1 path=$2 src base dst
  src=$(cx_resolve "$root" "$path")
  [[ -f $src ]] || return 1
  if grep -q '^NoDisplay=true' "$src"; then return 1; fi
  base=${path##*/}
  dst="$HOME/.local/share/applications/tod-cx-$base"
  awk -v run="$PREFIX/bin/tod cx run --" -v pix="$HOME/.local/share/pixmaps" -v tag="$(cx_distro)" '
    /^\[/ { sect = ($0 == "[Desktop Entry]" || $0 ~ /^\[Desktop Action /) }
    $0 == "[Desktop Entry]" { print; print "X-TOD-Container=" tag; main = 1; next }
    /^\[/ && main { if (!sn) print "StartupNotify=true"; main = 0 }   # app lente: cursore di attesa
    main && /^StartupNotify=/ { sn = 1 }
    sect && /^Exec=/ { sub(/^Exec=/, "Exec=" run " "); print; next }
    sect && /^(TryExec|DBusActivatable)=/ { next }
    sect && /^Icon=[^\/]/ {
      n = substr($0, 6)
      for (i = 1; i <= 3; i++) {
        e = (i == 1 ? ".png" : (i == 2 ? ".svg" : ".xpm"))
        if ((getline tmp < (pix "/" n e)) >= 0) { close(pix "/" n e); print "Icon=" pix "/" n e; done = 1; break }
      }
      if (done) { done = 0; next }
    }
    { print }
    END { if (main && !sn) print "StartupNotify=true" }' "$src" >"$dst"
  # app con nome "a dominio" ma StartupWMClass corto (ArtCraft Launcher: artcraft-launcher, mentre la
  # finestra si chiama ai.storyteller.artcraft-launcher): la barra non trovava l'icona (ingranaggio)
  local id=${base%.desktop} wm
  wm=$(sed -n 's/^StartupWMClass=//p' "$dst" | sed -n 1p)
  if [[ -n $wm && $wm != *.* && $id == *."$wm" ]]; then
    sed -i "s/^StartupWMClass=.*/StartupWMClass=$id/" "$dst"
  fi
  # app Electron (Code...): in proot la sandbox di Chromium non c'è e senza --no-sandbox
  # si chiudono appena partite (dal desktop un'app andava solo perché quella icona l'aveva)
  local cmd
  cmd=$(sed -n "s|^Exec=$PREFIX/bin/tod cx run -- \([^ ]*\).*|\1|p" "$dst" | sed -n 1p)
  if [[ -n $cmd ]] && cx_is_electron "$root" "$cmd"; then
    sed -i "/^Exec=/{/--no-sandbox/!s|\(cx run -- [^ ]*\)|\1 --no-sandbox|}" "$dst"
  fi
  printf '%s' "$dst"
}

cx_is_electron() { # cx_is_electron rootfs comando → vero se è un'app Electron/Chromium
  local root=$1 cmd=$2 real d
  if [[ $cmd != /* ]]; then
    for d in /usr/local/bin /usr/bin /bin /opt/bin; do
      if [[ -e $root$d/$cmd || -L $root$d/$cmd ]]; then cmd=$d/$cmd; break; fi
    done
  fi
  real=$(cx_resolve "$root" "$cmd")
  d=$(dirname "$real")
  [[ -e $d/chrome-sandbox || -e $d/resources/app.asar ]]
}

cx_sync_apps() { # voci del menu per tutte le app del container (anche installate da altri, es. dal launcher di ArtCraft)
  local root f pkg
  local -a pkgs=()
  root=$(cx_rootfs) || return 0
  while IFS= read -r f; do
    pkg=${f##*/}
    pkg=${pkg%.list}
    pkgs+=("${pkg%:*}")
  done < <(grep -l '^/usr/share/applications/.*\.desktop$' "$root"/var/lib/dpkg/info/*.list 2>/dev/null || true)
  if ((${#pkgs[@]})); then cx_export_pkgs "${pkgs[@]}"; fi
  cx_prune_exports
  cx_sync_home_apps
  desktop_refresh_caches
  diretto_prepara || true   # dopo apt nel container (hook): un glibc nuovo vuole copie nuove
}

# --- app installate nella cartella personale (AppImage dei launcher, installatori "per utente") ------
# Come su ogni distribuzione, una voce in ~/.local/share/applications dell'utente del container va nello
# Start (S20+, 17 ottobre: ArtCraft Launcher senza pkexec mette l'AppImage in ~/Applications e la voce lì).
# Registro: cx-exports/home-<voce>.files, con la voce esportata e "#exe <eseguibile nel container>".
cx_home_apps_dir() { local root; root=$(cx_rootfs) || return 1; printf '%s/home/%s/.local/share/applications' "$root" "$(cx_user)"; }

cx_home_icon() { # cx_home_icon rootfs nome-icona → percorso reale dell'icona nella home del container
  local root=$1 n=$2 h f
  h="$root/home/$(cx_user)/.local/share"
  if [[ $n == /* ]]; then f=$(cx_resolve "$root" "$n"); [[ -f $f ]] && printf '%s' "$f"; return 0; fi
  for f in "$h"/icons/hicolor/{scalable,512x512,256x256,128x128,64x64,48x48}/apps/"$n".{svg,png} "$h"/icons/"$n".{svg,png} \
    "$h"/pixmaps/"$n".{svg,png} "$h/$n".{svg,png}; do
    if [[ -f $f ]]; then printf '%s' "$f"; return 0; fi
  done
  return 0
}

cx_sync_home_apps() {
  local root dir src base id dst exp="$TOD_STATE_DIR/cx-exports" icon exe f
  root=$(cx_rootfs) || return 0
  dir=$(cx_home_apps_dir) || return 0
  mkdir -p "$exp" "$HOME/.local/share/applications"
  for src in "$dir"/*.desktop; do
    [[ -f $src ]] || continue
    base=${src##*/}
    case $base in tod-*) continue ;; esac   # le nostre (apertura dei link verso il desktop)
    id=${base%.desktop}
    if grep -qE '^(NoDisplay|Hidden)=true' "$src"; then continue; fi
    if [[ -f $exp/home-$id.files && $exp/home-$id.files -nt $src ]]; then continue; fi   # già fatta
    dst=$(cx_export_desktop "$root" "/home/$(cx_user)/.local/share/applications/$base") || continue
    icon=$(sed -n 's/^Icon=//p' "$src" | sed -n 1p)
    if [[ -n $icon ]]; then
      f=$(cx_home_icon "$root" "$icon")
      if [[ -n $f ]]; then sed -i "s|^Icon=.*|Icon=$f|" "$dst"; fi
    fi
    exe=$(sed -n 's/^Exec=//p' "$src" | sed -n 1p | awk '{print $1}' | tr -d "\"'")
    printf '%s\n#exe %s\n' "$dst" "$exe" >"$exp/home-$id.files"
    log "menu: app nella cartella personale del container: $id ($exe)"
  done
  # voci tolte (disinstallate dal launcher o a mano): via anche dallo Start
  for f in "$exp"/home-*.files; do
    [[ -f $f ]] || continue
    id=${f##*/home-}
    id=${id%.files}
    if [[ ! -f $dir/$id.desktop ]]; then
      while IFS= read -r x; do rm -f "$x"; done < <(grep -v '^#' "$f" || true)
      rm -f "$f"
    fi
  done
  return 0
}

cx_remove_home_app() { # tod cx remove-home <voce>: la voce e il suo eseguibile, solo se è un file nella home
  local id=$1 root dir exe real home
  root=$(cx_rootfs) || return 1
  dir=$(cx_home_apps_dir) || return 1
  home="/home/$(cx_user)/"
  exe=$(sed -n 's/^#exe //p' "$TOD_STATE_DIR/cx-exports/home-$id.files" 2>/dev/null | sed -n 1p) || exe=""
  # mai fuori dalla cartella personale, mai una cartella: un AppImage o un eseguibile singolo
  if [[ -n $exe && $exe == "$home"* && $exe != *..* ]]; then
    real=$root$exe
    if [[ -f $real && ! -L $real ]]; then rm -f "$real"; log "app tolta: $exe"; fi
  fi
  rm -f "$dir/$id.desktop"
  cx_sync_home_apps
  desktop_refresh_caches
}

cx_prune_exports() { # rimuove le voci dei pacchetti non più presenti
  local installed f pkg x
  installed=$(cx_pkg_list)
  for f in "$TOD_STATE_DIR"/cx-exports/*.files; do
    [[ -f $f ]] || continue
    pkg=${f##*/}
    pkg=${pkg%.files}
    case $pkg in home-*) continue ;; esac   # app nella cartella personale: le segue cx_sync_home_apps
    if ! grep -qxF "$pkg" <<<"$installed"; then
      while IFS= read -r x; do rm -f "$x"; done <"$f"
      rm -f "$f"
    fi
  done
  desktop_refresh_caches
}

cx_upgrade() {
  cx_root "$CX_AIUTI" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
ST=""
if [ -e /tmp/tod-progress ]; then exec 3>>/tmp/tod-progress; ST="-o APT::Status-Fd=3"; fi
apt-get update -q
apt-get -y -q $ST -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
# strumenti arrivati dopo l'installazione del container (CX_AIUTI)
manca=""
for p in $1; do dpkg -s "$p" >/dev/null 2>&1 || manca="$manca $p"; done
if [ -n "$manca" ]; then apt-get -y -q $ST --no-install-recommends install $manca || true; fi
apt-get autoremove -y -q || true
EOF
}

cx_cli() { # tod cx install|remove|export|run|shell|update|backup|restore|probe
  local sub=${1:-shell}
  if (($#)); then shift; fi
  detect_gpu
  case $sub in
    install | add) run_step "$(t s_cx_pkgs "$*")" cx_pkg_install "$@" ;;
    remove | rm) run_step "$(t s_cx_remove "$*")" cx_pkg_remove "$@" ;;
    export) CX_EXPORT_FORCE=1 cx_export_pkgs "$@"; ok "$(t cx_exported "$*")" ;;
    sync) cx_sync_apps ;;
    sync-home) cx_sync_home_apps; desktop_refresh_caches ;;
    remove-home) [[ -n ${1:-} ]] || die "tod cx remove-home <voce>"; cx_remove_home_app "$1" ;;
    pkexec)   # tod cx pkexec on|off: le app del container possono chiedere i permessi da amministratore
      case ${1:-} in on | si | sì) conf_set CX_PKEXEC 1 ;; off | no) conf_set CX_PKEXEC 0 ;; *) die "tod cx pkexec on|off" ;; esac
      cx_install_runner
      ok "pkexec: $(conf_get CX_PKEXEC 1)"
      ;;
    run)
      if [[ ${1:-} == -- ]]; then shift; fi
      cx_run "$@"
      ;;
    shell | sh | login) cx_run ;;
    update | upgrade) run_step "$(t s_cx_update)" cx_upgrade; diretto_prepara || true ;;
    probe) run_step "$(t s_cxgpu)" x11_with_server cx_gpu_probe && info "GPU container: $(conf_get CX_GPU_PROFILE)" ;;
    backup)
      local out=${1:-$HOME/tod-$(cx_distro)-$(date +%Y%m%d).tar.gz}
      run_step "$(t s_cx_backup "$out")" proot-distro backup --output "$out" "$(cx_distro)"
      ;;
    restore)
      [[ -f ${1:-} ]] || die "tod cx restore <file.tar.gz>"
      run_step "$(t s_cx_restore)" proot-distro restore "$1"
      ;;
    *) die "tod cx [install|remove|export|run|shell|update|probe|backup|restore] ..." ;;
  esac
}
