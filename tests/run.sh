#!/usr/bin/env bash
# =============================================================================
#  Test di Termux On DeX — girano su qualsiasi Linux (anche in CI), con mock di
#  getprop, adb, proot-distro, apt e un finto rootfs Debian.
#  Ogni test è in una subshell con `set -Eeuo pipefail`, come il codice vero:
#  un errore non gestito dentro una funzione fa fallire il test.
#
#  bash tests/run.sh            tutti i test
#  bash tests/run.sh gpu        solo quelli che contengono "gpu" nel nome
# =============================================================================
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FILTER=${1:-}

export HOME="$WORK/home" PREFIX="$WORK/usr" TMPDIR="$WORK/usr/tmp" NO_COLOR=1
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME
mkdir -p "$HOME" "$PREFIX/bin" "$TMPDIR"

# --- isolamento dal sistema vero ---------------------------------------------
# I test possono girare sul telefono, nel proot accanto al desktop vero: lì
# pgrep/pkill vedono i processi di Termux (stesso UID) e il PATH può contenere
# i programmi veri di Termux (am, pulseaudio, termux-x11…). Un session_stop di
# prova ha chiuso così il desktop di Pietro. Quindi:
#  - via dal PATH ogni cartella di Termux: restano solo i mock dei test;
#  - pgrep/pkill vedono solo i processi nati dai test (TOD_TEST_RUN ereditata).
PATH=$(tr ':' '\n' <<<"$PATH" | grep -v '^/data/data/com\.termux/' | paste -sd:)
# strumenti innocui che nel proot esistono solo in Termux: questi sì
mkdir -p "$WORK/safe-bin"
for _t in curl jq python3 sha256sum unzip zip clang git; do
  if ! command -v "$_t" >/dev/null && [[ -x /data/data/com.termux/files/usr/bin/$_t ]]; then
    ln -s "/data/data/com.termux/files/usr/bin/$_t" "$WORK/safe-bin/$_t"
  fi
done
unset _t
PATH="$PATH:$WORK/safe-bin"
export PATH TOD_TEST_RUN=$WORK TOD_PM=false
unset DISPLAY PULSE_SERVER XDG_RUNTIME_DIR

_test_pids() { # pgrep vero, filtrato sui processi che hanno TOD_TEST_RUN=$WORK
  local p
  for p in $(command pgrep "$@" 2>/dev/null); do
    if tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qxF "TOD_TEST_RUN=$WORK"; then echo "$p"; fi
  done
}
pgrep() {
  local out
  out=$(_test_pids "$@")
  [[ -n $out ]] || return 1
  printf '%s\n' "$out"
}
pkill() {
  local sig=TERM p found=1
  if [[ ${1:-} =~ ^-([0-9]+|[A-Z]+)$ ]]; then sig=${1#-}; shift; fi
  for p in $(_test_pids "$@"); do kill -s "$sig" "$p" 2>/dev/null || kill "-$sig" "$p" 2>/dev/null || true; found=0; done
  return "$found"
}
export -f _test_pids pgrep pkill

getprop() {
  case $1 in
    persist.sys.locale) echo it-IT ;;
    ro.soc.model) echo SM8850 ;;
    ro.hardware.egl) echo adreno ;;
    *) echo "" ;;
  esac
}

TOD_ROOT=$ROOT
for m in core i18n detect pkgs x11 api usb gpu desktop session container diretto apt apps disinstalla games phantom shizuku lingua look files maint menu tui benvenuto installer; do
  # shellcheck source=/dev/null
  . "$ROOT/lib/$m.sh"
done
tod_init

fresh_env() { # HOME/PREFIX nuovi per ogni test
  export HOME="$WORK/h_$1" PREFIX="$WORK/p_$1"
  export TMPDIR="$PREFIX/tmp"
  mkdir -p "$HOME" "$PREFIX/bin" "$TMPDIR"
  TOD_CONF_DIR="$HOME/.config/tod" TOD_STATE_DIR="$HOME/.local/state/tod" TOD_CACHE_DIR="$HOME/.cache/tod"
  TOD_CONF="$TOD_CONF_DIR/tod.conf" TOD_GPU_ENV="$TOD_CONF_DIR/gpu.env" TOD_LOG="$TOD_STATE_DIR/tod.log"
  TOD_GPU_PROBE="$TOD_STATE_DIR/gpu-probe.txt" TOD_X11_APK="$TMPDIR/termux-x11.apk" TOD_X11_DEB="$TMPDIR/termux-x11-nightly.deb"
  LINGUA_SO="$PREFIX/lib/tod-gettext.so" LINGUA_DIR="$PREFIX/share/tod-locale"
  mkdir -p "$PREFIX/lib"
  TOD_YES=1
  tod_init
}

# --- asserzioni (ritornano 1 → con set -e il test fallisce) ------------------
eq() {
  if [[ $2 == "$3" ]]; then return 0; fi
  printf '  ✘ %s\n    atteso:   %q\n    ottenuto: %q\n' "$1" "$2" "$3"
  return 1
}
has() {
  if grep -qF -- "$2" <<<"$3"; then return 0; fi
  printf '  ✘ %s: manca %q in:\n%s\n' "$1" "$2" "$3"
  return 1
}
hasnt() {
  if ! grep -qF -- "$2" <<<"$3"; then return 0; fi
  printf '  ✘ %s: non doveva contenere %q:\n%s\n' "$1" "$2" "$3"
  return 1
}
fails() { # in una subshell: anche le funzioni che fanno die/exit si possono provare
  if ( "$@" ) >/dev/null 2>&1; then printf '  ✘ doveva fallire: %s\n' "$*"; return 1; fi
  return 0
}

# =============================================================================
test_i18n_keys_complete() {
  local k missing=""
  local keys
  keys=$(grep -ohE '(\$\(|&& |\|\| )t [a-z_0-9]+' "$ROOT"/tod "$ROOT"/lib/*.sh | awk '{print $NF}' | sort -u)
  for k in $keys; do
    [[ -n ${TOD_MSG_it[$k]-} ]] || missing+=" it:$k"
    [[ -n ${TOD_MSG_en[$k]-} ]] || missing+=" en:$k"
  done
  eq "chiavi usate nel codice ma non tradotte" "" "$missing"
}

test_i18n_same_keys_and_placeholders() {
  local k a b diffs=""
  eq "stesse chiavi it/en" "$(printf '%s\n' "${!TOD_MSG_it[@]}" | sort)" "$(printf '%s\n' "${!TOD_MSG_en[@]}" | sort)"
  for k in "${!TOD_MSG_it[@]}"; do
    a=$(awk -v s="${TOD_MSG_it[$k]}" 'BEGIN{print gsub(/%s/, "", s)}')
    b=$(awk -v s="${TOD_MSG_en[$k]-}" 'BEGIN{print gsub(/%s/, "", s)}')
    [[ $a == "$b" ]] || diffs+=" $k($a/$b)"
  done
  eq "numero di %s uguale in it/en" "" "$diffs"
}

test_i18n_t_and_lang() {
  TOD_LANG=it
  eq "it" "Desktop xfce" "$(t s_desktop xfce)"
  TOD_LANG=en
  eq "en" "xfce desktop" "$(t s_desktop xfce)"
  eq "chiave ignota → chiave" "chiave_che_non_esiste" "$(t chiave_che_non_esiste)"
  conf_set UI_LANG en
  i18n_init
  eq "UI_LANG forza la lingua" en "$TOD_LANG"
}

test_conf_roundtrip() {
  conf_set DE kde
  conf_set APPS "firefox libreoffice"
  conf_load
  eq "DE" kde "$(conf_get DE)"
  eq "valore con spazi" "firefox libreoffice" "$(conf_get APPS)"
  eq "predefinito" xyz "$(conf_get NON_ESISTE xyz)"
  conf_set DE xfce
  conf_load
  eq "sovrascrittura" xfce "$(conf_get DE)"
  eq "una riga per chiave" 2 "$(wc -l <"$TOD_CONF" | tr -d ' ')"
}

test_steps_resume() {
  fails step_done base
  step_mark base
  step_mark base
  step_done base
  eq "nessun duplicato" 1 "$(grep -c '^base$' "$TOD_STATE_DIR/steps")"
  step_reset
  fails step_done base
}

test_display_classify() {
  eq "S26U QHD+ orizzontale" "200 1 phone" "$(display_classify 3120 1440)"
  eq "S26U QHD+ verticale" "200 1 phone" "$(display_classify 1440 3120)"
  eq "S26U FHD+" "160 1 phone" "$(display_classify 2340 1080)"
  eq "monitor 1080p" "108 1 fhd" "$(display_classify 1920 1080)"
  eq "monitor 1440p" "120 1 qhd" "$(display_classify 2560 1440)"
  eq "ultrawide 3440x1440" "120 1 qhd" "$(display_classify 3440 1440)"
  eq "16:10 2560x1600" "144 1 hidpi" "$(display_classify 2560 1600)"
  eq "4K" "96 2 uhd" "$(display_classify 3840 2160)"
  eq "zero" "96 1 unknown" "$(display_classify 0 0)"
}

test_gpu_classify() {
  gpu_classify "Adreno840v2" adreno adreno SM8850 QTI
  eq "famiglia" adreno "$GPU_FAMILY"
  eq "modello" 840 "$GPU_ADRENO"
  eq "revisione" 2 "$GPU_REV"
  eq "etichetta" "Adreno 840 v2" "$GPU_LABEL"
  gpu_classify "" adreno "" SM8750 QTI
  eq "da SoC" 830 "$GPU_ADRENO"
  gpu_classify "Adreno (TM) 840" "" "" "" ""
  eq "nome con (TM)" 840 "$GPU_ADRENO"
  eq "senza revisione" "" "$GPU_REV"
  if [[ ! -e /dev/kgsl-3d0 ]]; then
    gpu_classify "" mali mali MT6989 Mediatek
    eq "mali" mali "$GPU_FAMILY"
    gpu_classify "" "" "" S5E9965 Samsung
    eq "exynos" xclipse "$GPU_FAMILY"
  fi
  eq "One UI" 8.5 "$(oneui_version 80500)"
  eq "One UI vuota" "" "$(oneui_version "")"
}

test_x11_prefs_filter() {
  local list out
  list=$'"fullscreen"="false"\n"keepScreenOn"="true"\ndisplayResolutionMode=scaled\n"dexMetaKeyCapture": "false"'
  out=$(x11_prefs_filter "$list" fullscreen=true keepScreenOn=true displayResolutionMode=native \
    dexMetaKeyCapture=true chiaveInventata=1 hideCutout=true)
  eq "solo le chiavi esistenti" $'fullscreen=true\nkeepScreenOn=true\ndisplayResolutionMode=native\ndexMetaKeyCapture=true' "$out"
}

test_gpu_profiles_env() {
  mkdir -p "$PREFIX/share/vulkan/icd.d"
  touch "$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json"
  local out
  out=$(gpu_profile_env zink-turnip)
  has "ICD fissato" "VK_ICD_FILENAMES=$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json" "$out"
  has "zink" "MESA_LOADER_DRIVER_OVERRIDE=zink" "$out"
  hasnt "senza WSI sw" "MESA_VK_WSI_DEBUG" "$out"
  has "variante sw" "MESA_VK_WSI_DEBUG=sw" "$(gpu_profile_env zink-turnip-sw)"
  eq "kgsl" "MESA_LOADER_DRIVER_OVERRIDE=kgsl" "$(gpu_profile_env kgsl)"
  fails gpu_profile_env zink-wrapper
  fails gpu_profile_env inventato
  touch "$PREFIX/share/vulkan/icd.d/wrapper_icd.aarch64.json"
  has "wrapper" "wrapper_icd.aarch64.json" "$(gpu_profile_env zink-wrapper)"
}

test_gpu_env_write_export_reset() {
  conf_set VSYNC off
  gpu_write_env kgsl
  export MESA_VK_WSI_DEBUG=sw GALLIUM_DRIVER=zink   # avanzi di un altro profilo
  gpu_env_export
  eq "profilo" kgsl "${TOD_GPU_PROFILE:-}"
  eq "override" kgsl "${MESA_LOADER_DRIVER_OVERRIDE:-}"
  eq "vsync off" 0 "${vblank_mode:-}"
  eq "avanzi ripuliti (WSI)" "" "${MESA_VK_WSI_DEBUG:-}"
  eq "avanzi ripuliti (gallium)" "" "${GALLIUM_DRIVER:-}"
  eq "config" kgsl "$(conf_get GPU_PROFILE)"
  conf_set VSYNC tearfree
  gpu_write_env llvmpipe
  has "tearfree" "MESA_VK_WSI_PRESENT_MODE=mailbox" "$(cat "$TOD_GPU_ENV")"
  local -a clean=()
  mapfile -t clean < <(gpu_unset_args)
  eq "coppie -u VAR" "-u MESA_LOADER_DRIVER_OVERRIDE" "${clean[0]} ${clean[1]}"
  eq "env -u funziona" "" "$(MESA_LOADER_DRIVER_OVERRIDE=x env "${clean[@]}" printenv MESA_LOADER_DRIVER_OVERRIDE || true)"
}

test_gpu_adreno8xx_avoids_glitchy_profiles() {
  mkdir -p "$TOD_STATE_DIR"
  GPU_ADRENO=840
  printf '%s\n' 'kgsl|ok|Adreno (TM) 840|' 'zink-turnip|ok|zink|' 'zink-turnip-sw|ok|zink|' 'llvmpipe|ok|llvmpipe|' >"$TOD_GPU_PROBE"
  eq "840: per rango vince la copia software" zink-turnip-sw "$(gpu_pick_best)"
  printf '%s\n' 'kgsl|ok|FD840|4753' 'zink-turnip|ok|zink|1434' 'zink-turnip-sw|ok|zink|897' 'llvmpipe|ok|llvmpipe|500' >"$TOD_GPU_PROBE"
  eq "840: il punteggio non premia chi sporca il desktop" zink-turnip-sw "$(gpu_pick_best)"
  printf '%s\n' 'kgsl|ok|FD840|' 'llvmpipe|ok|llvmpipe|' >"$TOD_GPU_PROBE"
  eq "840: meglio software pulito che GPU con i blocchi neri" llvmpipe "$(gpu_pick_best)"
  GPU_ADRENO=740
  printf '%s\n' 'kgsl|ok|FD740|' 'zink-turnip-sw|ok|zink|' >"$TOD_GPU_PROBE"
  eq "740: nessun cambiamento" kgsl "$(gpu_pick_best)"
  GPU_ADRENO=840
  eq "container 840: env zink-sw" "MESA_VK_WSI_DEBUG=sw" "$(cx_profile_env zink-sw | grep WSI)"
  hasnt "container: zink normale senza WSI software" "WSI" "$(cx_profile_env zink)"
}

test_gpu_adreno8xx_glamor_prefers_dri3() { # 30 ottobre: con glamor nel server X zink diretto è pulito e più fluido
  mkdir -p "$TOD_STATE_DIR"
  GPU_ADRENO=840
  conf_set X11_GLAMOR 1
  printf '%s\n' 'kgsl|ok|Adreno (TM) 840|' 'zink-turnip|ok|zink|' 'zink-turnip-sw|ok|zink|' 'llvmpipe|ok|llvmpipe|' >"$TOD_GPU_PROBE"
  eq "840 con glamor: vince la presentazione diretta" zink-turnip "$(gpu_pick_best)"
  eq "con glamor zink-turnip non sporca il desktop" no "$(if gpu_glitchy zink-turnip; then echo si; else echo no; fi)"
  eq "kgsl resta da evitare anche con glamor (non riprovato)" si "$(if gpu_glitchy kgsl; then echo si; else echo no; fi)"
  printf '%s\n' 'kgsl|ok|FD840|' 'zink-turnip-sw|ok|zink|' 'llvmpipe|ok|llvmpipe|' >"$TOD_GPU_PROBE"
  eq "840 con glamor senza zink-turnip: la copia software va ancora" zink-turnip-sw "$(gpu_pick_best)"
  conf_set X11_GLAMOR 0
  printf '%s\n' 'zink-turnip|ok|zink|' 'zink-turnip-sw|ok|zink|' >"$TOD_GPU_PROBE"
  eq "840 senza glamor: come prima" zink-turnip-sw "$(gpu_pick_best)"
}

test_gpu_pick_best() {
  mkdir -p "$TOD_STATE_DIR"
  printf '%s\n' 'kgsl|ko||' 'zink-turnip|ok|zink Vulkan 1.4(Turnip Adreno (TM) 840)|' 'llvmpipe|ok|llvmpipe|' >"$TOD_GPU_PROBE"
  eq "per rango" zink-turnip "$(gpu_pick_best)"
  printf '%s\n' 'kgsl|ok|FD840|900' 'zink-turnip|ok|zink|1400' 'virgl|ok|virgl|300' >"$TOD_GPU_PROBE"
  eq "per punteggio" zink-turnip "$(gpu_pick_best)"
  eq "punteggio registrato" 900 "$(gpu_score_of kgsl)"
  eq "punteggio assente" 0 "$(gpu_score_of virgl-inventato)"
  : >"$TOD_GPU_PROBE"
  eq "niente funziona" llvmpipe "$(gpu_pick_best)"
  rm -f "$TOD_GPU_PROBE"
  eq "file assente" llvmpipe "$(gpu_pick_best)"
}

test_gpu_candidates() {
  GPU_FAMILY=adreno
  mkdir -p "$PREFIX/share/vulkan/icd.d"
  touch "$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json"
  printf '#!/bin/sh\n' >"$PREFIX/bin/virgl_test_server_android"
  chmod +x "$PREFIX/bin/virgl_test_server_android"
  PATH="$PREFIX/bin:$PATH"
  gpu_set_stack official
  eq "official" "zink-turnip zink-turnip-sw virgl llvmpipe" "$(gpu_candidates | tr '\n' ' ' | sed 's/ $//')"
  gpu_set_stack lfdevs
  eq "lfdevs: kgsl per primo" "kgsl zink-turnip zink-turnip-sw virgl llvmpipe" "$(gpu_candidates | tr '\n' ' ' | sed 's/ $//')"
  GPU_FAMILY=mali
  eq "mali" "virgl llvmpipe" "$(gpu_candidates | tr '\n' ' ' | sed 's/ $//')"
}

# --- logica di gpu_setup con driver finti -------------------------------------
_gpu_mocks() { # $1 = risultato official, $2 = risultato lfdevs (righe probe separate da ;)
  OFF_RES=$1 LF_RES=$2
  mkdir -p "$PREFIX/share/vulkan/icd.d"
  touch "$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json"
  GPU_FAMILY=adreno
  gpu_install_base() { return 0; }
  x11_with_server() { "$@"; }
  gpu_install_lfdevs() { gpu_set_stack lfdevs; }
  gpu_restore_official() { gpu_set_stack official; }
  pkg_has() { return 1; }
  gpu_probe_all() {
    if [[ $(gpu_stack) == lfdevs ]]; then tr ';' '\n' <<<"$LF_RES" >"$TOD_GPU_PROBE"
    else tr ';' '\n' <<<"$OFF_RES" >"$TOD_GPU_PROBE"; fi
  }
}

test_gpu_setup_keeps_kgsl_when_better() {
  _gpu_mocks 'zink-turnip|ok|zink|' 'kgsl|ok|FD840|'
  gpu_setup
  eq "profilo" kgsl "$(conf_get GPU_PROFILE)"
  eq "stack" lfdevs "$(gpu_stack)"
}

test_gpu_setup_reverts_when_not_better() {
  _gpu_mocks 'zink-turnip|ok|zink|' 'kgsl|ko||;zink-turnip|ok|zink|'
  gpu_setup
  eq "profilo" zink-turnip "$(conf_get GPU_PROFILE)"
  eq "torna ai driver ufficiali" official "$(gpu_stack)"
  eq "risultati ripristinati" 'zink-turnip|ok|zink|' "$(cat "$TOD_GPU_PROBE")"
}

test_gpu_setup_respects_no_experimental() {
  _gpu_mocks 'zink-turnip|ok|zink|' 'kgsl|ok|FD840|'
  conf_set GPU_EXPERIMENTAL no
  gpu_setup
  eq "profilo" zink-turnip "$(conf_get GPU_PROFILE)"
  eq "stack" official "$(gpu_stack)"
}

test_gpu_setup_bench_compares_scores() {
  _gpu_mocks 'zink-turnip|ok|zink|1500' 'kgsl|ok|FD840|1200;zink-turnip|ok|zink|1100'
  gpu_setup --bench
  eq "vince il punteggio ufficiale" zink-turnip "$(conf_get GPU_PROFILE)"
  eq "stack" official "$(gpu_stack)"
}

test_gpu_setup_wrapper_last_resort() {
  _gpu_mocks 'llvmpipe|ok|llvmpipe|' 'kgsl|ko||;llvmpipe|ok|llvmpipe|'
  pkg_has() { [[ $1 == vulkan-wrapper-android ]]; }
  pkg_installed() { return 1; }
  apt-get() { touch "$PREFIX/share/vulkan/icd.d/wrapper_icd.aarch64.json"; WRAPPED=1; }
  gpu_probe_all() {
    if [[ -n ${WRAPPED:-} ]]; then echo 'zink-wrapper|ok|zink Vulkan (Adreno (TM) 840 (QUALCOMM_PROPRIETARY))|' >"$TOD_GPU_PROBE"
    else echo 'llvmpipe|ok|llvmpipe|' >"$TOD_GPU_PROBE"; fi
  }
  gpu_setup
  eq "Zink sul driver Qualcomm" zink-wrapper "$(conf_get GPU_PROFILE)"
}

test_gpu_probe_all_adreno8xx_order() { # 30 ottobre: senza benchmark con lfdevs vinceva sempre kgsl (sporca il desktop)
  mkdir -p "$TOD_STATE_DIR"
  GPU_FAMILY=adreno
  GPU_ADRENO=840
  gpu_stack() { echo lfdevs; }
  gpu_icd() { echo /x/freedreno_icd.json; }
  have() { [[ $1 != virgl_test_server_android ]] && command -v "$1" >/dev/null 2>&1; }
  gpu_probe_one() { echo "renderer $1"; }
  conf_set X11_GLAMOR 0
  gpu_probe_all
  eq "840 senza glamor: provato e scelto per primo zink-turnip-sw" "zink-turnip-sw|ok|renderer zink-turnip-sw|" "$(sed -n 1p "$TOD_GPU_PROBE")"
  eq "840 senza glamor: scelta" zink-turnip-sw "$(gpu_pick_best)"
  conf_set X11_GLAMOR 1
  gpu_probe_all
  eq "840 con glamor: scelta" zink-turnip "$(gpu_pick_best)"
  GPU_ADRENO=740
  gpu_probe_all
  eq "740: ordine di prima, vince kgsl" kgsl "$(gpu_pick_best)"
}

test_gpu_probe_one_rejects_fallbacks() {
  mkdir -p "$PREFIX/share/vulkan/icd.d"
  touch "$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json"
  # vulkaninfo/glxinfo finti come *programmi*: gpu_vk_ok li lancia tramite timeout(1)
  cat >"$PREFIX/bin/vulkaninfo" <<'EOF'
#!/bin/sh
if [ -f "$HOME/vk_fail" ]; then echo "TU: error: device (chip_id = 44050A21, gpu_id = 6860) is unsupported"; exit 1; fi
echo "deviceName = Adreno (TM) 840"
EOF
  chmod +x "$PREFIX/bin/vulkaninfo"
  # glxinfo finto: con kgsl risponde Freedreno, con zink ricade su llvmpipe
  cat >"$PREFIX/bin/glxinfo" <<'EOF'
#!/bin/sh
case "${MESA_LOADER_DRIVER_OVERRIDE:-}" in
  kgsl) echo "OpenGL renderer string: FD840" ;;
  zink) echo "OpenGL renderer string: llvmpipe (LLVM 19, 128 bits)" ;;
  *) echo "OpenGL renderer string: llvmpipe (LLVM 19, 128 bits)" ;;
esac
EOF
  chmod +x "$PREFIX/bin/glxinfo"
  PATH="$PREFIX/bin:$PATH"
  eq "kgsl ok" FD840 "$(gpu_probe_one kgsl)"
  fails gpu_probe_one zink-turnip
  eq "llvmpipe ammesso solo come software" "llvmpipe (LLVM 19, 128 bits)" "$(gpu_probe_one llvmpipe)"
  # chip non supportato (Adreno 840v2 con Turnip ufficiale)
  touch "$HOME/vk_fail"
  fails gpu_probe_one zink-turnip
  has "motivo nel log" "unsupported" "$(cat "$TOD_LOG")"
}

test_virgl_profile_needs_server_flag() {
  has "flag virgl" "TOD_NEEDS_VIRGL=1" "$(gpu_profile_env virgl)"
}

# --- rete e GitHub --------------------------------------------------------------
test_download_checksum() {
  echo ciao >"$WORK/sorgente.txt"
  local sha
  sha=$(sha256sum "$WORK/sorgente.txt" | cut -d' ' -f1)
  net_download "file://$WORK/sorgente.txt" "$TOD_CACHE_DIR/x/a.txt" "$sha"
  eq "contenuto" ciao "$(cat "$TOD_CACHE_DIR/x/a.txt")"
  sha256_ok "$TOD_CACHE_DIR/x/a.txt" "${sha^^}"   # maiuscole accettate
  fails net_download "file://$WORK/sorgente.txt" "$TOD_CACHE_DIR/x/b.txt" "$(printf '0%.0s' {1..64})"
  eq "file con checksum errato scartato" no "$([[ -e $TOD_CACHE_DIR/x/b.txt ]] && echo si || echo no)"
}

test_github_release_parsing() {
  if ! command -v jq >/dev/null; then echo "  (jq assente: salto)"; return 0; fi
  cat >"$WORK/rel.json" <<'EOF'
[
 {"tag_name":"turnip-weekly","draft":false,"published_at":"2026-10-01T00:00:00Z","body":"","assets":[]},
 {"tag_name":"freedreno-26.1.0-devel","draft":false,"published_at":"2026-05-01T00:00:00Z","body":"","assets":[]},
 {"tag_name":"freedreno-26.2.0-devel-20260709","draft":false,"published_at":"2026-07-12T18:01:00Z",
  "body":"## Checksums\r\n```\r\nf22d1258f28d71f38ce4e39e67f251565f1f1df57ccb4c046698e6e853aa5aca  mesa-vulkan-icd-freedreno_26.2.0-1_aarch64.deb\r\n5adfa7b3000bdce3ff660afb40e069e95508b0ab5c54c29dd9732111a548cfeb  mesa_26.2.0-1_aarch64.deb\r\n```",
  "assets":[
   {"name":"mesa_26.2.0-1_aarch64.deb","browser_download_url":"https://example.invalid/mesa.deb","digest":null},
   {"name":"mesa-vulkan-icd-freedreno_26.2.0-1_aarch64.deb","browser_download_url":"https://example.invalid/icd.deb","digest":"sha256:abc123"}]},
 {"tag_name":"freedreno-99-draft","draft":true,"published_at":"2026-12-01T00:00:00Z","body":"","assets":[]}
]
EOF
  net_get() { cat "$WORK/rel.json"; }
  local rel url sha name
  rel=$(gh_release lfdevs/termux-packages freedreno-)
  eq "release più recente (no draft, no altri prefissi)" freedreno-26.2.0-devel-20260709 "$(jq -r .tag_name <<<"$rel")"
  IFS='|' read -r url sha name <<<"$(gh_asset "$rel" '^mesa_.*_aarch64\.deb$')"
  eq "url" https://example.invalid/mesa.deb "$url"
  eq "digest assente → vuoto" "" "$sha"
  eq "nome" mesa_26.2.0-1_aarch64.deb "$name"
  eq "sha dalle note" 5adfa7b3000bdce3ff660afb40e069e95508b0ab5c54c29dd9732111a548cfeb "$(gh_body_sha "$rel" "$name")"
  IFS='|' read -r url sha name <<<"$(gh_asset "$rel" '^mesa-vulkan-icd-freedreno_.*\.deb$')"
  eq "digest di GitHub" abc123 "$sha"
  eq "nessun asset" "" "$(gh_asset "$rel" 'inesistente')"
  fails gh_release lfdevs/termux-packages prefisso-inesistente-
}

# --- container ------------------------------------------------------------------
_fake_rootfs() {
  R="$PREFIX/var/lib/proot-distro/installed-rootfs/debian"
  mkdir -p "$R/etc" "$R/usr/lib" "$R/usr/share/applications" "$R/usr/share/icons/hicolor/48x48/apps" \
    "$R/usr/share/pixmaps" "$R/var/lib/dpkg/info"
  printf 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nID=debian\nVERSION_CODENAME=trixie\n' >"$R/usr/lib/os-release"
  ln -sf ../usr/lib/os-release "$R/etc/os-release"
  cat >"$R/usr/share/applications/libreoffice-writer.desktop" <<'EOF'
[Desktop Entry]
Name=LibreOffice Writer
TryExec=libreoffice
Exec=libreoffice --writer %U
Icon=libreoffice-writer
Type=Application
Actions=NewDocument;

[Desktop Action NewDocument]
Name=New Document
Exec=libreoffice --writer
EOF
  printf '[Desktop Entry]\nName=Hidden\nExec=x\nNoDisplay=true\n' >"$R/usr/share/applications/hidden.desktop"
  printf '[Desktop Entry]\nName=Lo\nExec=lo\nIcon=lo\n' >"$R/usr/share/applications/lo.desktop"
  echo PNG >"$R/usr/share/icons/hicolor/48x48/apps/real.png"
  ln -sf /usr/share/icons/hicolor/48x48/apps/real.png "$R/usr/share/icons/hicolor/48x48/apps/libreoffice-writer.png"
  echo XPM >"$R/usr/share/pixmaps/lo.xpm"
  printf '%s\n' /usr/share/applications/libreoffice-writer.desktop /usr/share/applications/hidden.desktop \
    /usr/share/icons/hicolor/48x48/apps/libreoffice-writer.png /usr/bin/libreoffice >"$R/var/lib/dpkg/info/libreoffice-writer.list"
  printf '%s\n' /usr/share/applications/lo.desktop /usr/share/pixmaps/lo.xpm >"$R/var/lib/dpkg/info/lo:arm64.list"
  printf 'Package: libreoffice-writer\nStatus: install ok installed\n\nPackage: lo\nStatus: install ok installed\n\nPackage: rimosso\nStatus: deinstall ok config-files\n' \
    >"$R/var/lib/dpkg/status"
}

test_cx_detection_and_suffix() {
  fails cx_installed
  _fake_rootfs
  cx_installed
  eq "os-release (link relativo)" "debian trixie" "$(cx_os)"
  eq "trixie" debian_trixie_arm64 "$(cx_mesa_suffix debian trixie)"
  eq "noble" ubuntu_noble_arm64 "$(cx_mesa_suffix ubuntu noble)"
  fails cx_mesa_suffix debian bookworm
  eq "pacchetti installati" $'libreoffice-writer\nlo' "$(cx_pkg_list)"
  eq "locale da Android" it_IT.UTF-8 "$(cx_locale)"
}

test_cx_export_and_prune() {
  _fake_rootfs
  local apps="$HOME/.local/share/applications" d
  cx_export_pkgs lo libreoffice-writer
  d=$(cat "$apps/tod-cx-libreoffice-writer.desktop")
  has "Exec riscritto" "Exec=$PREFIX/bin/tod cx run -- libreoffice --writer %U" "$d"
  has "azione riscritta" "Exec=$PREFIX/bin/tod cx run -- libreoffice --writer" "$d"
  hasnt "TryExec tolto" "TryExec" "$d"
  eq "marcatore subito dopo [Desktop Entry]" "X-TOD-Container=debian" "$(sed -n 2p "$apps/tod-cx-libreoffice-writer.desktop")"
  eq "voce nascosta non esportata" no "$([[ -e $apps/tod-cx-hidden.desktop ]] && echo si || echo no)"
  eq "icona (link assoluto risolto)" PNG "$(cat "$HOME/.local/share/icons/hicolor/48x48/apps/libreoffice-writer.png")"
  has "pixmap → percorso assoluto" "Icon=$HOME/.local/share/pixmaps/lo.xpm" "$(cat "$apps/tod-cx-lo.desktop")"
  # rimozione: il pacchetto sparisce dallo status → spariscono le sue voci
  sed -i 's/^Package: lo$/Package: lo-rimosso/' "$R/var/lib/dpkg/status"
  cx_prune_exports
  eq "voce rimossa" no "$([[ -e $apps/tod-cx-lo.desktop ]] && echo si || echo no)"
  eq "l'altra resta" si "$([[ -e $apps/tod-cx-libreoffice-writer.desktop ]] && echo si || echo no)"
}

test_cx_gpu_probe_choice() {
  _fake_rootfs
  GPU_FAMILY=adreno
  conf_set CX_MESA_TAG mesa-26.2.0-devel-20260709
  have() { [[ $1 != virgl_test_server_android ]] && command -v "$1" >/dev/null 2>&1; }
  cx_run() { # cx_run --raw env VAR=... timeout 30 glxinfo -B
    local a o=""
    for a in "$@"; do case $a in MESA_LOADER_DRIVER_OVERRIDE=*) o=${a#*=} ;; esac; done
    case $o in
      kgsl) echo "${KGSL_OUT:-OpenGL renderer string: FD840}" ;;
      zink) echo "OpenGL renderer string: zink Vulkan 1.4(Turnip Adreno (TM) 840 (MESA_TURNIP))" ;;
      *) echo "OpenGL renderer string: llvmpipe (LLVM 19)" ;;
    esac
  }
  cx_gpu_probe
  eq "kgsl nel container" kgsl "$(conf_get CX_GPU_PROFILE)"
  eq "gpu.env del container" MESA_LOADER_DRIVER_OVERRIDE=kgsl "$(cat "$R/etc/tod/gpu.env")"
  KGSL_OUT="OpenGL renderer string: llvmpipe (LLVM 19)"
  cx_gpu_probe
  eq "ripiego su zink" zink "$(conf_get CX_GPU_PROFILE)"
}

test_cx_gpu_probe_glamor_adreno8xx() { # con glamor il container passa a zink diretto (DRI3), senza resta zink-sw
  _fake_rootfs
  GPU_FAMILY=adreno
  GPU_ADRENO=840
  conf_set CX_MESA_TAG mesa-26.2.0-devel-20260709
  have() { [[ $1 != virgl_test_server_android ]] && command -v "$1" >/dev/null 2>&1; }
  cx_run() {
    local a o=""
    for a in "$@"; do case $a in MESA_LOADER_DRIVER_OVERRIDE=*) o=${a#*=} ;; esac; done
    case $o in
      kgsl) echo "OpenGL renderer string: FD840" ;;
      zink) echo "OpenGL renderer string: zink Vulkan 1.4(Turnip Adreno (TM) 840 (MESA_TURNIP))" ;;
      *) echo "OpenGL renderer string: llvmpipe (LLVM 19)" ;;
    esac
  }
  conf_set X11_GLAMOR 0
  cx_gpu_probe
  eq "senza glamor: copia software" zink-sw "$(conf_get CX_GPU_PROFILE)"
  has "senza glamor: WSI software" MESA_VK_WSI_DEBUG=sw "$(cat "$R/etc/tod/gpu.env")"
  conf_set X11_GLAMOR 1
  cx_gpu_probe
  eq "con glamor: zink diretto" zink "$(conf_get CX_GPU_PROFILE)"
  hasnt "con glamor: niente WSI software" MESA_VK_WSI_DEBUG "$(cat "$R/etc/tod/gpu.env")"
}

test_cx_aiuti_zenity() { # 31 ottobre: senza zenity le app Rust (rfd, PdfCraft) non aprivano la finestra dei file
  has "zenity tra gli strumenti del container" zenity "$CX_AIUTI"
  cx_root() { printf '%s\n' "$*" >"$WORK/cxa_args_$$"; cat >"$WORK/cxa_script_$$"; }
  cx_upgrade
  has "tod update: strumenti passati al container" zenity "$(cat "$WORK/cxa_args_$$")"
  has "tod update: installa quelli che mancano" 'install $manca' "$(cat "$WORK/cxa_script_$$")"
  # lo script vero, con dpkg e apt-get finti: zenity manca → si installa
  mkdir -p "$WORK/cxa_bin_$$"
  printf '#!/bin/sh\nexit 1\n' >"$WORK/cxa_bin_$$/dpkg"
  printf '#!/bin/sh\necho "apt-get $*" >>"%s"\n' "$WORK/cxa_apt_$$" >"$WORK/cxa_bin_$$/apt-get"
  chmod +x "$WORK/cxa_bin_$$/dpkg" "$WORK/cxa_bin_$$/apt-get"
  PATH="$WORK/cxa_bin_$$:$PATH" sh "$WORK/cxa_script_$$" "$CX_AIUTI"
  has "zenity installato" "install zenity" "$(cat "$WORK/cxa_apt_$$")"
}

test_cx_gpu_probe_virgl_mali() { # Mali: glxinfo con virpipe dà BadMatch, ma con una finestra vera virgl va
  _fake_rootfs
  GPU_FAMILY=mali
  conf_set CX_MESA_TAG ""
  have() { [[ $1 == virgl_test_server_android ]] || command -v "$1" >/dev/null 2>&1; }
  virgl_start() { return 0; }
  virgl_stop() { :; }
  cx_run() {
    local a v=0
    for a in "$@"; do [[ $a == GALLIUM_DRIVER=virpipe ]] && v=1; done
    if ((v)) && [[ " $* " == *" glxinfo "* ]]; then echo "X Error of failed request:  BadMatch"; return 1; fi
    if ((v)) && [[ " $* " == *" glxgears "* ]]; then echo "GL_RENDERER   = virgl (Mali-G77)"; return 124; fi
    echo "OpenGL renderer string: llvmpipe (LLVM 19)"
  }
  cx_gpu_probe
  eq "virgl scelto" virgl "$(conf_get CX_GPU_PROFILE)"
  has "percorso di virpipe forzato" LIBGL_ALWAYS_SOFTWARE=1 "$(cat "$R/etc/tod/gpu.env")"
}

test_cx_runner_script() {
  _fake_rootfs
  mkdir -p "$R/usr/bin"
  cx_install_runner
  local f="$R/usr/local/bin/tod-run"
  [[ -x $f ]]
  bash -n "$f"
  has "pulizia ambiente" "unset LD_PRELOAD LD_LIBRARY_PATH" "$(cat "$f")"
  # eseguito "fuori" dal container: deve almeno funzionare come sh POSIX
  eq "esegue il comando" ok "$(TOD_ETC=$R/etc/tod DISPLAY=:5 sh "$f" --raw sh -c 'echo ok')"
  eq "DISPLAY rispettato" :5 "$(TOD_ETC=$R/etc/tod DISPLAY=:5 sh "$f" --raw sh -c 'echo $DISPLAY')"
  eq "AppImage senza FUSE" 1 "$(TOD_ETC=$R/etc/tod sh "$f" --raw sh -c 'echo $APPIMAGE_EXTRACT_AND_RUN')"
  # pkexec: acceso di serie (le app grafiche che chiedono i permessi), spento solo se scelto
  local p="$R/usr/local/bin/pkexec"
  [[ -x $p ]]
  # ArtCraft Launcher 0.8.1 lo cerca solo in /usr/bin, /bin, /usr/sbin, /sbin (26 ottobre)
  # relativo: senza proot il kernel seguirebbe un /usr/local assoluto fuori dal container
  eq "anche in /usr/bin" ../local/bin/pkexec "$(readlink "$R/usr/bin/pkexec")"
  ln -sf /usr/local/bin/pkexec "$R/usr/bin/pkexec"
  cx_install_runner
  eq "il collegamento assoluto di prima si rifà" ../local/bin/pkexec "$(readlink "$R/usr/bin/pkexec")"
  conf_set CX_PKEXEC 0
  cx_install_runner
  eq "spento a richiesta: niente pkexec" no:no "$([[ -e $p ]] && echo si || echo no):$([[ -L $R/usr/bin/pkexec ]] && echo si || echo no)"
  printf '#!/bin/sh\n# polkit vero\n' >"$R/usr/bin/pkexec"
  conf_set CX_PKEXEC 1
  cx_install_runner
  has "un pkexec vero non si tocca" "polkit vero" "$(cat "$R/usr/bin/pkexec")"
  rm -f "$R/usr/bin/pkexec"
  [[ -x $p ]]
  sh -n "$p"
  eq "risponde a --version come polkit" "pkexec version 126" "$(sh "$p" --version)"
  mkdir -p "$WORK/fb_$$"
  printf '#!/bin/sh\nshift; [ "$1" = -- ] && shift; echo "sudo:$*"\n' >"$WORK/fb_$$/sudo"
  chmod +x "$WORK/fb_$$/sudo"
  eq "pkexec → sudo, opzioni di polkit tolte" "sudo:apt install ./x.deb" \
    "$(PATH="$WORK/fb_$$:$PATH" sh "$p" --disable-internal-agent apt install ./x.deb)"
  has "poi il menu" "tod-sync-menu" "$(cat "$p")"
  # ogni apt/dpkg del container aggiorna il menu Start (tranne quando lo fa già tod apt)
  has "menu: tod cx sync" "tod\" cx sync" "$(cat "$R/usr/local/bin/tod-sync-menu")"
  has "hook di apt" "tod-sync-menu" "$(cat "$R/etc/apt/apt.conf.d/99tod-menu")"
  eq "TOD_MENU_SYNC=0: niente doppio aggiornamento" "" "$(TOD_MENU_SYNC=0 PREFIX=/nessuno sh -x "$R/usr/local/bin/tod-sync-menu" 2>&1 | grep -c setsid | sed 's/^0$//')"
}

test_cx_sync_apps() {
  _fake_rootfs
  export TOD_TERMUX_HOME=$HOME
  mkdir -p "$R/var/lib/dpkg/info"
  printf '/usr\n/usr/share/applications/ai.storyteller.soundcraft.desktop\n' >"$R/var/lib/dpkg/info/soundcraft:arm64.list"
  printf '[Desktop Entry]\nName=SoundCraft\nExec=soundcraft %%F\nIcon=soundcraft\nStartupWMClass=soundcraft\n' >"$R/usr/share/applications/ai.storyteller.soundcraft.desktop"
  printf 'Package: soundcraft\nStatus: install ok installed\n\n' >>"$R/var/lib/dpkg/status"
  desktop_refresh_caches() { :; }
  cx_sync_apps
  has "app installata dal launcher: nel menu" "Exec=$PREFIX/bin/tod cx run -- soundcraft %F" \
    "$(cat "$HOME/.local/share/applications/tod-cx-ai.storyteller.soundcraft.desktop")"
  has "nome della finestra giusto (icona nella barra)" "StartupWMClass=ai.storyteller.soundcraft" \
    "$(cat "$HOME/.local/share/applications/tod-cx-ai.storyteller.soundcraft.desktop")"
  has "cursore di attesa" "StartupNotify=true" \
    "$(cat "$HOME/.local/share/applications/tod-cx-ai.storyteller.soundcraft.desktop")"
  # la voce sparita (tolto un AppImage con lo stesso id, 26 ottobre): si rifà anche se il pacchetto non è cambiato
  rm -f "$HOME/.local/share/applications/tod-cx-ai.storyteller.soundcraft.desktop"
  cx_sync_apps
  eq "voce cancellata: rifatta" si "$([[ -f $HOME/.local/share/applications/tod-cx-ai.storyteller.soundcraft.desktop ]] && echo si || echo no)"
  # app Electron: --no-sandbox in automatico (senza, in proot si chiudono subito)
  mkdir -p "$R/usr/lib/app-electron" "$R/usr/bin"
  : >"$R/usr/lib/app-electron/chrome-sandbox"
  ln -sf /usr/lib/app-electron/app-electron "$R/usr/bin/app-electron"
  printf '/usr/share/applications/org.esempio.App.desktop\n' >"$R/var/lib/dpkg/info/app-electron.list"
  printf '[Desktop Entry]\nName=App\nExec=app-electron %%U\n\n[Desktop Action NewChat]\nExec=app-electron "app://new"\n' \
    >"$R/usr/share/applications/org.esempio.App.desktop"
  printf 'Package: app-electron\nStatus: install ok installed\n\n' >>"$R/var/lib/dpkg/status"
  cx_sync_apps
  local cl="$HOME/.local/share/applications/tod-cx-org.esempio.App.desktop"
  eq "Electron: --no-sandbox su ogni Exec" 2 "$(grep -c "cx run -- app-electron --no-sandbox" "$cl")"
  cx_sync_apps
  eq "una volta sola" 0 "$(grep -c -- "--no-sandbox --no-sandbox" "$cl")"
  eq "le altre app no" 0 "$(grep -c -- "--no-sandbox" "$HOME/.local/share/applications/tod-cx-ai.storyteller.soundcraft.desktop")"
  # l'id di avvio arriva dentro il container (è lui che spegne il cursore di attesa)
  proot-distro() { printf '%s\n' "$@" >"$WORK/pd_$$"; }
  cx_installed() { return 0; }
  cx_startup_watch() { echo "watch:$1" >>"$WORK/pd_watch_$$"; }
  DESKTOP_STARTUP_ID=abc_TIME1 cx_run soundcraft
  has "DESKTOP_STARTUP_ID passato" "DESKTOP_STARTUP_ID=abc_TIME1" "$(cat "$WORK/pd_$$")"
  eq "e chi spegne il cursore alla prima finestra" "watch:abc_TIME1" "$(cat "$WORK/pd_watch_$$")"
}

test_apt_unified() { # un solo apt: prima Termux, poi il container; il menu si aggiorna
  pkg_has() { [[ $1 == gimp || $1 == htop ]]; }
  pkg_installed() { [[ $1 == htop ]]; }
  cx_installed() { return 0; }
  printf '%s\n' gparted gimp htop >"$WORK/names_$$"
  cx_pkgnames() { printf '%s' "$WORK/names_$$"; }
  cx_pkg_list() { printf '%s\n' gparted; }
  apt_native() { echo "termux:$*" >>"$WORK/apt_$$"; }
  cx_apt() { echo "debian:$*" >>"$WORK/apt_$$"; }
  cx_sync_apps() { echo "menu" >>"$WORK/apt_$$"; }
  cx_prune_exports() { echo "menu-" >>"$WORK/apt_$$"; }
  apt_cli install -y gimp gparted
  eq "gimp da Termux, gparted dal container" $'termux:install -y gimp\ndebian:install -y gparted\nmenu' "$(cat "$WORK/apt_$$")"
  : >"$WORK/apt_$$"
  apt_cli remove htop gparted
  eq "rimuove da dove sta" $'termux:remove htop\ndebian:remove gparted\nmenu-' "$(cat "$WORK/apt_$$")"
  : >"$WORK/apt_$$"
  local rc=0
  apt_cli install nonesiste 2>"$WORK/err_$$" || rc=$?
  eq "pacchetto inesistente: errore come apt" 100 "$rc"
  has "messaggio" "nonesiste" "$(cat "$WORK/err_$$")"
  eq "nessuna installazione" "" "$(cat "$WORK/apt_$$")"
  apt_cli update
  eq "update su entrambi" $'termux:update\ndebian:update' "$(cat "$WORK/apt_$$")"
  # il terminale del desktop carica tod-shell.sh una volta sola
  files_user_home() { printf '%s' "$HOME/u"; }
  mkdir -p "$HOME/u"
  apt_shell_setup; apt_shell_setup
  eq "riga in .bashrc" 1 "$(grep -c 'un solo apt' "$HOME/u/.bashrc")"
  has "funzione apt" 'tod" apt' "$(cat "$ROOT/share/tod-shell.sh")"
}

test_look_sfondo() { # sfondo DeX OS: famiglia nella variante del tema, oppure un'immagine dell'utente
  export TOD_TERMUX_HOME=$HOME
  local d="$HOME/.local/share/backgrounds/dexos"
  mkdir -p "$d"
  : >"$d/fiore-chiaro.jpg"; : >"$d/fiore-scuro.jpg"; : >"$d/vetro-chiaro.png"
  eq "di serie: fiore chiaro" "$d/fiore-chiaro.jpg" "$(look_sfondo_path)"
  conf_set TEMA scuro
  eq "tema scuro: la variante scura" "$d/fiore-scuro.jpg" "$(look_sfondo_path)"
  conf_set TEMA chiaro; conf_set SFONDO vetro
  eq "anche in PNG" "$d/vetro-chiaro.png" "$(look_sfondo_path)"
  : >"$HOME/mia.jpg"; conf_set SFONDO "$HOME/mia.jpg"
  eq "un'immagine dell'utente" "$HOME/mia.jpg" "$(look_sfondo_path)"
  rm -f "$HOME/mia.jpg"
  eq "immagine sparita: si torna al fiore" "$d/fiore-chiaro.jpg" "$(look_sfondo_path)"
  fails look_sfondo_cli arcobaleno
}

test_look_pulizia() { # via temi e icone di XFCE, GNOME, KDE, LXDE, v1 e Fluent; restano hicolor, Fluent-Light/Dark e i nostri
  pkg_installed() { return 1; }   # mai apt vero nei test
  local h=$HOME n
  export TOD_TERMUX_HOME=$HOME
  cx_installed() { return 1; }
  for n in Daloa Kokodi Adwaita Fluent Fluent-Light Fluent-Dark Default/xfwm4 Default/gtk-3.0 PiXflat; do mkdir -p "$PREFIX/share/themes/$n"; done
  for n in Adwaita breeze nuoveXT2 hicolor Fluent; do mkdir -p "$PREFIX/share/icons/$n"; done
  mkdir -p "$h/.icons/PiXflat" "$h/.themes/Windows-10-3.2.1" "$h/.local/share/icons/DeX-OS-Cursors-x-v2"
  : >"$h/.local/share/icons/DeX-OS-Cursors-x-v2/index.theme"
  conf_set DEXOS_NAMES "g gs w ws i DeX-OS-Cursors-x-v2 DeX-OS-Cursors-Light-x-v2"
  mkdir -p "$PREFIX/share/backgrounds/xfce"; : >"$PREFIX/share/backgrounds/wallpaper4.jpg"
  look_sfondi_ensure() { :; }
  look_pulizia
  eq "sfondi di XFCE e della v1 via" "" "$(ls "$PREFIX/share/backgrounds")"
  eq "temi rimasti" "Default Fluent-Dark Fluent-Light" "$(ls "$PREFIX/share/themes" | tr '\n' ' ' | sed 's/ $//')"
  eq "di Default resta solo la parte di GTK" gtk-3.0 "$(ls "$PREFIX/share/themes/Default")"
  eq "icone rimaste" "hicolor" "$(ls "$PREFIX/share/icons" | tr '\n' ' ' | sed 's/ $//')"
  eq "v1 via" "no no" "$([[ -e $h/.icons/PiXflat ]] && echo si || echo no) $([[ -e $h/.themes/Windows-10-3.2.1 ]] && echo si || echo no)"
  has "dpkg non li rimette" "path-exclude=$PREFIX/share/themes/Daloa/*" "$(cat "$PREFIX/etc/dpkg/dpkg.cfg.d/tod-pulizia")"
  has "nemmeno le cartelle vuote" "path-exclude=$PREFIX/share/themes/Daloa
" "$(cat "$PREFIX/etc/dpkg/dpkg.cfg.d/tod-pulizia")"
  has "puntatore di X: il nostro" "Inherits=DeX-OS-Puntatore" "$(cat "$h/.icons/default/index.theme")"
  eq "con nome fisso" DeX-OS-Cursors-x-v2 "$(readlink "$h/.local/share/icons/DeX-OS-Puntatore")"
  mkdir -p "$PREFIX/share/themes/Daloa"
  look_pulizia
  eq "una volta sola" yes "$([[ -d $PREFIX/share/themes/Daloa ]] && echo yes)"
}

test_dexos_puntatore() { # puntatore DeX OS: variante scura di serie, chiara a scelta, niente se manca il tema
  local i="$HOME/.local/share/icons" n
  conf_set DEXOS_NAMES "g gs w ws DeX-OS-Icons-x DeX-OS-Cursors-x-v1 DeX-OS-Cursors-Light-x-v1"
  eq "senza tema: niente" "" "$(look_dexos_cursor)"
  for n in DeX-OS-Cursors-x-v1 DeX-OS-Cursors-Light-x-v1; do mkdir -p "$i/$n"; : >"$i/$n/index.theme"; done
  eq "di serie: corpo scuro" DeX-OS-Cursors-x-v1 "$(look_dexos_cursor)"
  conf_set PUNTATORE chiaro
  eq "chiaro a scelta" DeX-OS-Cursors-Light-x-v1 "$(look_dexos_cursor)"
}

test_phantom_riprova() { # associazione ADB fallita (Annulla per sbaglio, codice scaduto): si riprova, mai avanti da soli
  local n="$WORK/ph_$$"
  echo 0 >"$n"
  priv_ready() { return 1; }
  adb_connect_local() { local k; k=$(($(cat "$n") + 1)); echo "$k" >"$n"; ((k >= 2)); }
  phantom_apply() { :; }
  phantom_verify() { :; }
  dev_settings_open() { :; }
  ui_msg() { :; }
  ui_menu() { if [[ $1 == "$(t ph_title)" && $2 == "$(t ph_intro)" ]]; then echo adb; else echo "${RISPOSTA:-retry}"; fi; }
  phantom_fix 2>/dev/null
  eq "riuscita al secondo tentativo" 2 "$(cat "$n")"
  eq "fatto con ADB" adb "$(conf_get PHANTOM_FIX)"
  echo -9 >"$n"
  if RISPOSTA=skip phantom_fix 2>/dev/null; then n=fatto; else n=saltato; fi
  eq "salta solo se lo sceglie l'utente" saltato "$n"
}

test_diretto_run() { # app di Debian senza proot: programma, script, Electron, ripiego su proot
  local r="$WORK/dr_root_$$" d="$WORK/dr_dir_$$" o="$WORK/dr_out_$$" out rc DBUS_SESSION_BUS_ADDRESS= XDG_CURRENT_DESKTOP=
  mkdir -p "$r/etc/tod" "$r/etc/ld.so.conf.d" "$r/usr/bin" "$r/usr/lib/editor" "$r/usr/lib/aarch64-linux-gnu" \
    "$r/usr/share/zoneinfo/Europe" "$d/lib"
  : >"$r/usr/share/zoneinfo/Europe/Rome"
  echo 'dex:x:1000:1000::/home/dex:/bin/bash' >"$r/etc/passwd"
  echo '/usr/local/lib' >"$r/etc/ld.so.conf.d/x.conf"
  printf 'GALLIUM_DRIVER=zink\n' >"$r/etc/tod/gpu.env"
  printf 'DISPLAY=:0.0\nPULSE_SERVER=127.0.0.1\n' >"$r/etc/tod/session.env"
  elf() { printf '\177ELF....../lib/ld-linux-aarch64.so.1\n' >"$1"; chmod +x "$1"; }
  elf "$r/usr/bin/app"; elf "$r/usr/bin/python3"; elf "$r/usr/lib/editor/editor"; : >"$r/usr/lib/editor/chrome-sandbox"
  ln -s ../lib/editor/editor "$r/usr/bin/editor"
  printf '#!/usr/bin/env python3\nprint(1)\n' >"$r/usr/bin/script"; chmod +x "$r/usr/bin/script"
  printf '\177ELF statico\n' >"$r/usr/bin/statico"; chmod +x "$r/usr/bin/statico"
  # il caricatore finto: --list risponde, il resto lo scrive ed esce con DR_RC
  {
    echo "#!$(command -v bash)"
    echo "if [[ \$1 == --list ]]; then [[ -f '$WORK/dr_manca_$$' ]] && echo 'libx.so => not found'; exit 0; fi"
    echo "{ echo \"argomenti: \$*\"; echo \"DISPLAY=\$DISPLAY\"; echo \"TZ=\$TZ\"; echo \"GPU=\$GALLIUM_DRIVER\"; echo \"LIB=\$LD_LIBRARY_PATH\"; echo \"HOME=\$HOME\"; echo \"BUS=\${DBUS_SESSION_BUS_ADDRESS:-nessuno}\"; echo \"DE=\${XDG_CURRENT_DESKTOP:-nessuno}\"; } >>'$o'"
    echo "exit \$(cat '$WORK/dr_rc_$$' 2>/dev/null || echo 0)"
  } >"$d/ld.so"
  chmod +x "$d/ld.so"
  # (i nomi r e d li usa anche diretto_run: qui i percorsi per intero)
  cx_rootfs() { printf '%s' "$WORK/dr_root_$$"; }
  diretto_dir() { printf '%s' "$WORK/dr_dir_$$"; }
  diretto_pronto() { return 0; }
  cx_user() { echo dex; }
  prop() { if [[ $1 == persist.sys.timezone ]]; then echo Europe/Rome; fi; }
  rm -f "$TOD_STATE_DIR/diretto-no"
  : >"$o"
  # il bus del desktop: un socket vero (python crea un socket unix), qui uno finto
  local bus="$WORK/dr_bus_$$"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$bus"
  DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS="unix:path=$bus,guid=1" diretto_run app uno "due tre"
  out=$(cat "$o"); : >"$o"
  # senza, le app si avviano un loro bus privato: niente icona nel vassoio né notifiche (26 ottobre)
  has "D-Bus del desktop" "BUS=unix:path=$bus,guid=1" "$out"
  DBUS_SESSION_BUS_ADDRESS="unix:path=$WORK/non-c-e,guid=1" diretto_run app
  has "socket che non c'è: niente indirizzo" "BUS=nessuno" "$(cat "$o")"; : >"$o"
  DBUS_SESSION_BUS_ADDRESS=disabled: diretto_run app
  has "bus spento (disabled:, da Electron): non si passa" "BUS=nessuno" "$(cat "$o")"; : >"$o"
  # il desktop: Electron sceglie da qui il portachiavi (senza, le app Electron non salvavano l'accesso: 28 ottobre)
  XDG_CURRENT_DESKTOP=XFCE diretto_run app
  has "desktop passato all'app" "DE=XFCE" "$(cat "$o")"; : >"$o"
  has "programma ELF dal caricatore, con il suo nome" "argomenti: --argv0 /usr/bin/app $r/usr/bin/app uno due tre" "$out"
  has "socket di X per intero" "DISPLAY=$TMPDIR/.X11-unix/X0" "$out"
  has "ora del telefono" "TZ=Europe/Rome" "$out"
  has "profilo GPU del container" "GPU=zink" "$out"
  # i programmi Bun e le app Rust (rustix) aprono i file senza il glibc: /home/dex non lo vedrebbero
  # vero e corto: i socket Unix stanno sotto i 108 caratteri (la copia unica di Electron, 28 ottobre)
  local casa
  casa="$PREFIX/.cx-dex"   # dentro $PREFIX: proot vede solo files/usr e files/home
  has "home col percorso vero e corto" "HOME=$casa" "$out"
  eq "porta alla home del container" "$r/home/dex" "$(readlink "$casa")"
  rm -f "$casa"; mkdir -p "$casa"
  : >"$o"; diretto_run app
  has "nome già occupato da altro: il percorso lungo" "HOME=$r/home/dex" "$(cat "$o")"
  rmdir "$casa"; : >"$o"
  has "librerie: copie nostre, poi ld.so.conf (solo cartelle che ci sono)" "LIB=$d/lib:$r/usr/lib/aarch64-linux-gnu:$r/usr/lib" "$out"
  diretto_run script x
  has "script: l'interprete del container, lo script come argomento" "--argv0 /usr/bin/python3 $r/usr/bin/python3 /usr/bin/script x" "$(cat "$o")"; : >"$o"
  diretto_run editor --no-sandbox
  has "Electron: niente /dev/shm" "$r/usr/lib/editor/editor --disable-dev-shm-usage --no-sandbox" "$(cat "$o")"; : >"$o"
  rc=0; diretto_run statico || rc=$?
  eq "programma statico: in proot" 97 "$rc"
  rc=0; diretto_run nonce || rc=$?
  eq "programma che non c'è: in proot (lo dice proot)" 97 "$rc"
  echo 127 >"$WORK/dr_rc_$$"; rc=0; diretto_run app || rc=$?
  eq "127 è dell'app (sh -c comando-che-non-c'è): non si riparte" 127 "$rc"
  eq "e non si segna" "" "$(cat "$TOD_STATE_DIR/diretto-no" 2>/dev/null)"
  rm -f "$WORK/dr_rc_$$"; : >"$WORK/dr_manca_$$"; rc=0; diretto_run app || rc=$?; rm -f "$WORK/dr_manca_$$"
  eq "librerie mancanti: in proot" 97 "$rc"
  rm -f "$TOD_STATE_DIR/diretto-no"
  echo 139 >"$WORK/dr_rc_$$"; rc=0; diretto_run app || rc=$?; rm -f "$WORK/dr_rc_$$"
  eq "crash appena partito: in proot" 97 "$rc"
  has "e segnato" "/usr/bin/app" "$(cat "$TOD_STATE_DIR/diretto-no")"
  : >"$o"
  rc=0; diretto_run app || rc=$?
  eq "segnato: subito in proot, senza riprovare" "97:" "$rc:$(cat "$o")"
  rm -f "$TOD_STATE_DIR/diretto-no"
  # cx_run: prima senza proot; 97 → proot; --proot, --raw e la shell sempre in proot
  cx_installed() { return 0; }
  proot-distro() { echo "proot $*" >>"$o"; }
  diretto_run() { echo "diretto $*" >>"$o"; return "${DR_FINTO:-0}"; }
  : >"$o"
  cx_run app a; cx_run --proot -- app b; cx_run --raw glxinfo; cx_run; DR_FINTO=97 cx_run app c
  out=$(cat "$o")
  hasnt "senza bus del desktop: nessun --env" "DBUS_SESSION_BUS_ADDRESS" "$out"
  : >"$o"
  DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" cx_run --proot -- app e
  has "proot: il D-Bus del desktop passa" "--env DBUS_SESSION_BUS_ADDRESS=unix:path=$bus" "$(cat "$o")"
  : >"$o"
  XDG_CURRENT_DESKTOP=XFCE cx_run --proot -- app f
  has "proot: anche il desktop" "--env XDG_CURRENT_DESKTOP=XFCE" "$(cat "$o")"
  rm -f "$bus"
  has "app: senza proot" "diretto app a" "$out"
  hasnt "app partita: niente proot" "tod-run app a" "$out"
  has "--proot: in proot" "tod-run app b" "$out"
  has "--raw (prove GPU): in proot" "tod-run --raw glxinfo" "$out"
  has "shell: in proot" "-- /usr/local/bin/tod-run" "$out"
  has "97: si riparte in proot" "tod-run app c" "$out"
  : >"$o"
  conf_get() { if [[ $1 == DIRETTO ]]; then echo 0; else echo "${2:-}"; fi; }
  cx_run app d
  hasnt "DIRETTO=0: tutto in proot" "diretto app d" "$(cat "$o")"
}

test_diretto_collegamenti() { # collegamenti assoluti → relativi: senza proot il kernel li seguirebbe su Android
  local r="$WORK/dl_$$"
  mkdir -p "$r/etc/ssl/certs" "$r/usr/lib/ssl" "$r/usr/bin" "$r/etc/alternatives" "$r/home/dex"
  ln -s usr/bin "$r/bin"
  echo cert >"$r/etc/ssl/certs/ca.crt"
  echo awk >"$r/usr/bin/mawk"
  ln -s /etc/ssl/certs/ca.crt "$r/usr/lib/ssl/cert.pem"
  ln -s /usr/bin/mawk "$r/etc/alternatives/awk"
  ln -s /etc/alternatives/awk "$r/usr/bin/awk"
  ln -s /data/data/com.termux/files/home/Documenti "$r/home/dex/Documenti"
  ln -s /proc/self/mounts "$r/etc/mtab"
  ln -s mawk "$r/usr/bin/nawk"
  python3 "$TOD_ROOT/share/diretto/collegamenti.py" "$r" >/dev/null
  eq "certificati" ../../../etc/ssl/certs/ca.crt "$(readlink "$r/usr/lib/ssl/cert.pem")"
  eq "stesso file" cert "$(cat "$r/usr/lib/ssl/cert.pem")"
  eq "alternative" ../../usr/bin/mawk "$(readlink "$r/etc/alternatives/awk")"
  eq "catena" awk "$(cat "$r/usr/bin/awk")"
  eq "verso Android: com'era" /proc/self/mounts "$(readlink "$r/etc/mtab")"
  eq "la home dell'utente non si tocca" /data/data/com.termux/files/home/Documenti "$(readlink "$r/home/dex/Documenti")"
  eq "relativi già giusti" mawk "$(readlink "$r/usr/bin/nawk")"
  has "un secondo giro non fa niente" ": 0" "$(python3 "$TOD_ROOT/share/diretto/collegamenti.py" "$r")"
}

test_diretto_correggi() { # la copia del glibc: set_robust_list → -ENOSYS, file interni → /dev/fd/NN
  local f="$WORK/glibc_$$" out
  python3 -c '
import struct, sys
b = struct.pack("<IIII", 0x52800C68, 0xD503201F, 0xD4000001, 0xD4000001)   # mov w8,#99; nop; svc; svc
b += struct.pack("<II", 0x52800B08, 0xD4000001)                            # mov w8,#88; svc (altra chiamata)
b += b"\0/etc/hosts\0/etc/hosts.allow\0/etc/resolv.conf\0"
open(sys.argv[1], "wb").write(b)' "$f"
  python3 "$TOD_ROOT/share/diretto/correggi.py" "$f" "$f.ok" >/dev/null
  out=$(python3 -c '
import struct, sys
b = open(sys.argv[1], "rb").read()
w = struct.unpack_from("<6I", b)
print(hex(w[2]), hex(w[5]), [x for x in b[24:].split(b"\0") if x])' "$f.ok")
  eq "svc di set_robust_list → movn x0,#37; l'altra chiamata resta" "0x928004a0 0xd4000001" "$(cut -d' ' -f1,2 <<<"$out")"
  has "file interni sui descrittori, gli altri intatti" "[b'/dev/fd/96', b'/etc/hosts.allow', b'/dev/fd/97']" "$out"
  eq "stessa lunghezza" "$(stat -c %s "$f")" "$(stat -c %s "$f.ok")"
  # le azioni di posix_spawn le fa il glibc senza fakechroot: ArtCraft Launcher avviava le app in /usr/bin
  # e il figlio usciva con 127 (26 ottobre). tod-diretto.c non si compila qui: si controlla che ci siano
  has "cartella di partenza tradotta" "posix_spawn_file_actions_addchdir_np" "$(cat "$ROOT/share/diretto/tod-diretto.c")"
  has "file da aprire tradotti" "posix_spawn_file_actions_addopen" "$(cat "$ROOT/share/diretto/tod-diretto.c")"
  # elenchi di argomenti senza limite: con 1024 il collegatore di cargo perdeva metà dei file (26 ottobre)
  eq "nessun elenco fisso" 0 "$(grep -c '\[1024\]' "$ROOT/share/diretto/tod-diretto.c")"
  has "argomenti troppo lunghi per fakechroot: E2BIG come il kernel (rustc riprova con @file)" "EINVAL → E2BIG" "$(cat "$ROOT/share/diretto/tod-diretto.c")"
  # la "seconda copia" di Electron riconosce la prima da /proc/<pid>/exe (link di ritorno da Chromium, 28 ottobre)
  has "/proc/<pid>/exe delle altre app" "altro_exe(path, buf, len, vero(path, buf, len))" "$(cat "$ROOT/share/diretto/tod-diretto.c")"
  eq "readlink e readlinkat non si chiamano a vicenda (giro senza fine)" 0 "$(grep -c 'return readlink(' "$ROOT/share/diretto/tod-diretto.c")"
  # accept è vietata da Android (solo accept4): senza, Electron non accettava la seconda copia (28 ottobre)
  has "accept del glibc → accept4" "return accept4(fd, indirizzo, lunghezza, 0);" "$(cat "$ROOT/share/diretto/tod-diretto.c")"
  has "accept diretta al kernel → accept4" "syscall(NR_ACCEPT4, x[0], x[1], x[2], 0, 0, 0)" "$(cat "$ROOT/share/diretto/tod-diretto.c")"
}

test_diretto_usb_e_resti() { # app Electron dal menu (23 ottobre): dischi USB accesi e resti di un avvio caduto
  local r="$WORK/du_root_$$" d="$WORK/du_dir_$$" o="$WORK/du_out_$$" p="$WORK/du_proc_$$" out
  mkdir -p "$r/etc/tod" "$r/usr/bin" "$d/lib" "$TMPDIR/tod-usb" "$HOME/.local/share/tod-usb"
  echo 'dex:x:1000:1000::/home/dex:/bin/bash' >"$r/etc/passwd"
  printf '\177ELF....../lib/ld-linux-aarch64.so.1\n' >"$r/usr/bin/app"; chmod +x "$r/usr/bin/app"
  {
    echo "#!$(command -v bash)"
    echo 'if [[ $1 == --list ]]; then exit 0; fi'
    echo "{ echo \"PRE=\$LD_PRELOAD\"; echo \"FUORI=\$FAKECHROOT_EXCLUDE_PATH\"; } >>'$o'"
  } >"$d/ld.so"
  chmod +x "$d/ld.so"
  cx_rootfs() { printf '%s' "$WORK/du_root_$$"; }
  diretto_dir() { printf '%s' "$WORK/du_dir_$$"; }
  diretto_pronto() { return 0; }
  cx_user() { echo dex; }
  usb_data() { printf '%s' "$HOME/.local/share/tod-usb"; }
  : >"$TMPDIR/tod-usb/lkl-attivo"; : >"$HOME/.local/share/tod-usb/tod-fs-glibc.so"
  : >"$o"
  diretto_run app
  out=$(cat "$o")
  has "tod-fs dopo fakechroot (i suoi execvp saltavano fakechroot)" \
    "PRE=$d/tod-diretto.so $r$DIRETTO_FC $HOME/.local/share/tod-usb/tod-fs-glibc.so" "$out"
  has "/media/usb lo traduce tod-fs, non fakechroot" ":/media/usb" "$out"
  rm -f "$TMPDIR/tod-usb/lkl-attivo"; : >"$o"
  diretto_run app
  hasnt "senza dischi: niente tod-fs" "tod-fs-glibc" "$(cat "$o")"
  # resti: solo i processi partiti dal nostro caricatore con quel programma
  mkdir -p "$p/11" "$p/12" "$p/13" "$p/14"
  printf '%s\0--argv0\0/usr/bin/app\0%s\0' "$d/ld.so" "$r/usr/bin/app" >"$p/11/cmdline"
  printf '%s\0--argv0\0/usr/bin/app\0%s\0--type=gpu\0' "$d/ld.so" "$r/usr/bin/app" >"$p/12/cmdline"
  printf '%s\0--argv0\0/usr/bin/altra\0%s\0' "$d/ld.so" "$r/usr/bin/altra" >"$p/13/cmdline"
  printf 'proot\0%s\0' "$r/usr/bin/app" >"$p/14/cmdline"
  eq "resti: l'app e i suoi figli, non altre app né proot" "11 12" "$(diretto_resti "$d/ld.so" "$r/usr/bin/app" "$p" | sort | tr '\n' ' ' | sed 's/ $//')"
}

test_usb_lkl_accanto() { # il pacchetto dei dischi portato con il progetto (dist/): si usa, se l'impronta torna
  local r="$WORK/lklroot_$$"
  mkdir -p "$r/dist" "$TOD_CACHE_DIR"
  echo pacchetto >"$r/dist/tod-lkl-aarch64.tar.xz"
  net_download() { [[ -f $2 ]] && echo "in cache" || echo "da internet"; return 1; }
  local giusta
  giusta=$(sha256sum "$r/dist/tod-lkl-aarch64.tar.xz" | cut -d' ' -f1)
  eq "impronta giusta: copiato e usato" "in cache" "$(TOD_ROOT=$r LKL_SHA256=$giusta usb_lkl_scarica 2>/dev/null)"
  rm -f "$TOD_CACHE_DIR"/tod-lkl-*.tar.xz
  eq "impronta sbagliata: ignorato" "da internet" "$(TOD_ROOT=$r LKL_SHA256=0000 usb_lkl_scarica 2>/dev/null)"
}

test_usb_install() { # l'installazione: pacchetti, tod-lkl (scaricato o compilato), ntfs-3g nel container
  local d="$HOME/.local/share/tod-usb" f out
  export TOD_TERMUX_HOME=$HOME
  mkdir -p "$d"
  pkg_install() { echo "pkg $*" >>"$WORK/u_$$"; }
  net_download() { echo "scarica $1 $3" >>"$WORK/u_$$"; return "${SCARICA_RC:-0}"; }
  tar() { local f d=${!#}; for f in $LKL_FILE; do echo x >"$d/$f"; done; }   # l'ultimo argomento è la cartella
  bash() { echo "bash ${*: -1}" >>"$WORK/u_$$"; }
  cx_installed() { return 0; }
  cx_pkg_installed() { [[ $1 == gnome-disk-utility ]]; }
  cx_pkg_install() { echo "debian $*" >>"$WORK/u_$$"; }
  cx_root() { echo "debian via $*" >>"$WORK/u_$$"; }
  pkg_installed() { [[ $1 == qemu-utils ]]; }
  apt-get() { echo "termux $*" >>"$WORK/u_$$"; }
  desktop_dischi_entry() { echo "voce" >>"$WORK/u_$$"; }
  : >"$d/disco.img"; mkdir -p "$d/stato"; : >"$d/stato/memoria"
  usb_install
  out=$(cat "$WORK/u_$$")
  has "ncat, flock, libusb, termux-usb e gli strumenti dei dischi" "pkg nmap util-linux libusb termux-api fdisk dosfstools exfatprogs e2fsprogs" "$out"
  has "file compilati dalla release, con l'impronta" "scarica $LKL_URL $LKL_SHA256" "$out"
  for f in $LKL_FILE; do [[ -s $d/$f ]] || out+=" manca:$f"; done
  eq "file al loro posto" "" "$(grep -o 'manca:.*' <<<"$out")"
  has "NTFS dal container" "debian ntfs-3g" "$out"
  has "dischi in Esplora file già dal primo avvio" "bash monitor" "$out"
  has "voce Dischi" "voce" "$out"
  eq "la vecchia macchina via" "no" "$([[ -e $d/disco.img || -e $d/stato ]] && echo si || echo no)"
  has "GNOME Disks via dal container" "debian via gnome-disk-utility" "$out"
  has "QEMU via da Termux" "termux remove -y qemu-utils" "$out"
  : >"$WORK/u_$$"
  usb_install
  if grep -q '^scarica' "$WORK/u_$$"; then out=si; else out=no; fi
  eq "già pronti: niente download" no "$out"
  : >"$WORK/u_$$"; rm -f "$d/lkl-versione"
  SCARICA_RC=1 usb_install 2>/dev/null
  has "download fallito: si compila qui" "bash $ROOT/share/usb/lkl/costruisci.sh" "$(cat "$WORK/u_$$")"
  : >"$WORK/u_$$"
  conf_set USB_DISCHI 0
  usb_install
  eq "dischi spenti: niente" "" "$(cat "$WORK/u_$$")"
}

test_bv_answers() { # le scelte della schermata di benvenuto finiscono nella configurazione, controllate
  command -v jq >/dev/null || return 0
  BV_DIR="$WORK/bv_$$"; mkdir -p "$BV_DIR"
  bv_app_list >"$BV_DIR/app"
  has "catalogo per la schermata" "firefox|Firefox|on" "$(cat "$BV_DIR/app")"
  sleep 30 & BV_PID=$!; BV_ON=1
  printf '%s' '{"lingua":"es","nome":"Ada Rossi","utente":"ada","tema":"scuro","accento":"verde","app":["vlc","rm -rf","gimp"]}' >"$BV_DIR/risposte.json"
  bv_answers
  eq "utente" ada "$(conf_get USER_NAME)"
  eq "nome completo" "Ada Rossi" "$(conf_get USER_FULLNAME)"
  eq "lingua" es "$(conf_get LINGUA)"
  eq "tema" scuro "$(conf_get TEMA)"
  eq "accento in esadecimale" "#107c10" "$(conf_get ACCENTO)"
  eq "solo app del catalogo" "vlc gimp " "$(conf_get APPS)"
  eq "risposte segnate" 1 "$(conf_get BV_RISPOSTE)"
  conf_set BV_RISPOSTE 0
  printf '%s' '{"lingua":"xx-evil","nome":"","utente":"Root/../x","tema":"viola","accento":"nero","app":[]}' >"$BV_DIR/risposte.json"
  bv_answers
  eq "utente non valido ignorato" ada "$(conf_get USER_NAME)"
  eq "lingua non valida ignorata" es "$(conf_get LINGUA)"
  eq "tema non valido ignorato" scuro "$(conf_get TEMA)"
  kill "$BV_PID" 2>/dev/null; wait "$BV_PID" 2>/dev/null || true
  BV_ON=0 BV_PID=""
}

test_bv_note_e_comandi() { # stato per la schermata (solo l'id del passo) e Riprova/Esci da lì
  BV_DIR="$WORK/bvn_$$"; mkdir -p "$BV_DIR"; BV_LAST=""
  BV_ON=0; bv_note 10 desktop
  eq "spenta: niente stato" "" "$(cat "$BV_DIR/stato" 2>/dev/null)"
  BV_ON=1; bv_note 42 look
  has "percentuale" "pct=42" "$(cat "$BV_DIR/stato")"
  has "solo l'id del passo (i nomi li ha la schermata)" "passo=look" "$(cat "$BV_DIR/stato")"
  sleep 30 & BV_PID=$!
  ( sleep 1; echo riprova >"$BV_DIR/comando" ) &
  eq "Riprova dalla schermata" retry "$(bv_error_choice cx "Container debian" 50)"
  has "errore mostrato con l'id" "errore=cx" "$(cat "$BV_DIR/stato")"
  ( sleep 1; echo esci >"$BV_DIR/comando" ) &
  eq "Esci dalla schermata" quit "$(bv_error_choice cx "Container debian" 50)"
  kill "$BV_PID" 2>/dev/null; wait "$BV_PID" 2>/dev/null || true
  BV_ON=0 BV_PID=""
}

test_bv_nomi_dei_passi() { # la schermata ha un nome comprensibile per ogni passo dopo di lei (niente "v1", "xfce"...)
  local id ids
  ids=$(python3 -c 'import ast,sys; t=ast.parse(open(sys.argv[1]).read()); print(" ".join(k.value for n in ast.walk(t) if isinstance(n,ast.Assign) and getattr(n.targets[0],"id","")=="PASSI" for k in n.value.keys))' "$TOD_ROOT/share/tod-benvenuto.py")
  for id in desktop gpu cx cxgpu apps look lingua usbvm dischi integrate; do
    has "nome per $id" " $id " " $ids "
  done
}

test_bv_domande() { # con la schermata di benvenuto nel terminale si chiede solo ADB
  TUI_ON=1 TOD_YES=0 GPU_FAMILY=mali
  conf_set INSTALLED 0
  ui_yesno() { echo "si/no:$1" >>"$WORK/q_$$"; return 0; }
  ui_input() { echo "input:$1" >>"$WORK/q_$$"; echo utente; }
  ui_menu() { echo "menu:$1" >>"$WORK/q_$$"; echo xfce; }
  ui_checklist() { echo "lista:$1" >>"$WORK/q_$$"; }
  ui_msg() { :; }
  installer_questions
  eq "solo la domanda su ADB" "si/no:$(t q_ph_title)" "$(cat "$WORK/q_$$")"
  : >"$WORK/q_$$"; conf_set BENVENUTO 0
  installer_questions
  has "senza schermata: anche il nome utente" "input:$(t q_user_title)" "$(cat "$WORK/q_$$")"
  TUI_ON=0
}

test_preseed() { # primo avvio preparato: xfconfd privato, programmi di XFCE finti (niente barra sullo schermo)
  local f="$WORK/ps_$$"
  conf_set DE xfce
  have() { return 0; }
  x11_running() { return 1; }
  dbus-run-session() { { echo "PATH=$PATH"; command -v xfce4-panel; xfce4-panel -r && echo "finto ok"; echo "cmd ${*: -1}"; } >"$f"; }
  session_preseed
  has "comando interno" "cmd _preseed" "$(cat "$f")"
  has "xfce4-panel finto" "tod-preseed." "$(grep -v PATH= "$f")"
  has "e non fa niente" "finto ok" "$(cat "$f")"
  eq "cartella dei finti tolta" "" "$(compgen -G "$TMPDIR/tod-preseed.*" || true)"
  : >"$f"; conf_set DE kde
  session_preseed
  eq "KDE: niente" "" "$(cat "$f")"
}

test_cx_home_apps() { # app installate nella cartella personale del container (AppImage dei launcher)
  HR_ROOT="$WORK/hr_$$"; local h
  h="$HR_ROOT/home/dex"
  mkdir -p "$HR_ROOT/etc" "$h/.local/share/applications" "$h/.local/share/icons/hicolor/256x256/apps" "$h/Applications" "$HR_ROOT/usr/bin"
  cx_rootfs() { printf '%s' "$HR_ROOT"; }
  cx_distro() { echo debian; }
  desktop_refresh_caches() { :; }
  printf '[Desktop Entry]\nType=Application\nName=PDFCraft\nExec=/home/dex/Applications/pdfcraft.AppImage %%U\nIcon=pdfcraft\n' \
    >"$h/.local/share/applications/ai.storyteller.pdfcraft.desktop"
  printf '[Desktop Entry]\nType=Application\nName=Nostra\nExec=true\n' >"$h/.local/share/applications/tod-host-open.desktop"
  printf '[Desktop Entry]\nType=Application\nName=Fuori\nExec=/usr/bin/fuori\n' >"$h/.local/share/applications/fuori.desktop"
  : >"$h/.local/share/icons/hicolor/256x256/apps/pdfcraft.png"
  : >"$h/Applications/pdfcraft.AppImage"; : >"$HR_ROOT/usr/bin/fuori"
  cx_sync_home_apps
  local e="$HOME/.local/share/applications/tod-cx-ai.storyteller.pdfcraft.desktop"
  has "nello Start" "Exec=$PREFIX/bin/tod cx run -- /home/dex/Applications/pdfcraft.AppImage" "$(cat "$e")"
  has "con la sua icona" "Icon=$h/.local/share/icons/hicolor/256x256/apps/pdfcraft.png" "$(cat "$e")"
  eq "le voci nostre no" no "$([[ -e $HOME/.local/share/applications/tod-cx-tod-host-open.desktop ]] && echo si || echo no)"
  cx_remove_home_app ai.storyteller.pdfcraft
  eq "disinstallata: via l'AppImage" no "$([[ -e $h/Applications/pdfcraft.AppImage ]] && echo si || echo no)"
  eq "e la voce dello Start" no "$([[ -e $e ]] && echo si || echo no)"
  cx_remove_home_app fuori
  eq "mai file fuori dalla cartella personale" si "$([[ -e $HR_ROOT/usr/bin/fuori ]] && echo si || echo no)"
}

test_cartelle_dopo_risposte() { # nome utente scelto nella schermata dopo il desktop: barra laterale rifatta
  local bm
  cx_installed() { return 1; }
  conf_set USER_NAME ""
  files_setup
  bm="$(files_termux_home)/.config/gtk-3.0/bookmarks"
  eq "senza nome utente: niente cartelle" "" "$(cat "$bm" 2>/dev/null)"
  conf_set USER_NAME ada
  installer_user_folders
  has "Download nella barra laterale" "/ada/$(t fm_downloads)" "$(cat "$bm")"
  has "e in user-dirs" "XDG_DOWNLOAD_DIR=" "$(cat "$(files_termux_home)/.config/user-dirs.dirs")"
}

test_telefono_spente() { # app del telefono spente: il generatore toglie le voci e si ferma, "aggiorna" non le rifà
  local th="$WORK/tel_$$"
  mkdir -p "$th/.config/tod" "$th/.local/share/applications"
  printf 'ANDROID_APPS=0\n' >"$th/.config/tod/tod.conf"
  : >"$th/.local/share/applications/tod-android-com.esempio.desktop"
  : >"$th/.local/share/applications/firefox.desktop"
  TOD_TERMUX_HOME="$th" python3 "$ROOT/share/tod-android-apps.py"
  eq "voci del telefono tolte" no "$([[ -e $th/.local/share/applications/tod-android-com.esempio.desktop ]] && echo si || echo no)"
  eq "le altre restano" si "$([[ -e $th/.local/share/applications/firefox.desktop ]] && echo si || echo no)"
  conf_set ANDROID_APPS 0
  python3() { echo "generatore partito" >>"$WORK/tel_$$.log"; }
  android_apps_cli aggiorna
  eq "spente: aggiorna non le rifà" "" "$(cat "$WORK/tel_$$.log" 2>/dev/null)"
}

test_lavoro_in_sottofondo() { # il sottofondo non toglie fluidità: priorità minima, controlli meno frequenti
  eq "priorità minima" 19 "$(low_prio sh -c 'ps -o ni= -p $$' | tr -d ' ')"
  has "app del telefono" "low_prio setsid python3" "$(declare -f android_apps_sync)"
  has "stato del telefono" "low_prio setsid python3" "$(declare -f phone_status_start)"
  has "aggiornamenti" "low_prio setsid python3" "$(declare -f updates_start)"
  has "primo controllo aggiornamenti dopo 10 minuti" "FIRST_CHECK, EVERY = 600" "$(cat "$ROOT/share/tod-updates.py")"
}

test_prestazioni() { # tod prestazioni: resoconto leggibile in Download
  local out
  mkdir -p "$HOME/storage/downloads"
  out=$(TOD_TERMUX_HOME="$HOME" LANGUAGE=it python3 "$ROOT/share/tod-prestazioni.py" 1 2>&1)
  has "processore" "Processore usato da noi" "$out"
  has "memoria" "Memoria libera" "$out"
  eq "salvato in Download" 1 "$(ls "$HOME"/storage/downloads/tod-prestazioni-*.txt | wc -l)"
  # app di Debian senza proot: il nome vero, non il caricatore (prima tutte insieme sotto "ld.so")
  out=$(python3 - "$ROOT/share/tod-prestazioni.py" <<'PYEOF2'
import re, sys
src = open(sys.argv[1]).read()
def T(it, en): return it
exec(re.search(r"^def gruppo\(.*?(?=^\S)", src, re.S | re.M).group(0))
ld, r = "/h/.local/share/tod-diretto/ld.so", "/rootfs"
print(gruppo("\0".join([ld, "--argv0", "/usr/lib/app-electron/app-electron", r + "/usr/lib/app-electron/app-electron", "--type=zygote"]), "ld.so"))
print(gruppo("\0".join([ld, "--argv0", "/usr/bin/python3", r + "/usr/bin/python3", "/usr/bin/wordcraft"]), "ld.so"))
PYEOF2
)
  eq "senza proot: nomi veri" "app-electron|python3 wordcraft" "$(echo "$out" | paste -sd'|')"
}

test_apk_adb() { # con ADB collegato Termux:X11 e Termux:API si installano da sole, sennò a mano
  TOD_X11_APK="$WORK/x11_$$.apk"; TOD_X11_DEB="$WORK/x11_$$.deb"; TOD_API_APK="$WORK/api_$$.apk"
  have() { [[ $1 == adb ]] || command -v "$1" >/dev/null; }
  shizuku_ready() { return 1; }
  timeout() { shift; "$@"; }
  run_step() { shift; "$@"; }
  x11_variant() { echo shareduid; }
  x11_uid_status() { echo shared; }
  api_from_github() { return 0; }
  api_permissions() { :; }
  x11_app_download() { echo apk >"$TOD_X11_APK"; }
  api_app_download() { echo apk >"$TOD_API_APK"; }
  x11_app_installed() { [[ -f $WORK/inst_x11_$$ ]]; }
  api_app_installed() { [[ -f $WORK/inst_api_$$ ]]; }
  ui_msg() { echo "msg $2" >>"$WORK/a_$$"; }
  termux-open() { echo "apri" >>"$WORK/a_$$"; touch "$WORK/inst_x11_$$" "$WORK/inst_api_$$"; }
  am() { :; }
  adb() {
    case $1 in
      devices) printf 'List of devices attached\n127.0.0.1:40123\tdevice\n' ;;
      -s) case $3 in
            push) echo "${4##*/}" >"$WORK/push_$$" ;;
            shell) if [[ $4 == settings ]]; then
                     echo "impostazione $5 ${*:7}" >>"$WORK/set_$$"
                     if [[ $5 == get ]]; then echo 1; fi
                   elif [[ $4 == pm ]]; then
                     echo "adb install $(cat "$WORK/push_$$")" >>"$WORK/a_$$"
                     case $(cat "$WORK/push_$$") in x11*) touch "$WORK/inst_x11_$$" ;; api*) touch "$WORK/inst_api_$$" ;; esac
                     echo Success
                   fi ;;
          esac ;;
    esac
  }
  x11_app_ensure >/dev/null 2>&1; api_app_ensure >/dev/null 2>&1
  eq "con ADB: installate da sole, nessuna finestra" "adb install x11_$$.apk"$'\n'"adb install api_$$.apk" "$(cat "$WORK/a_$$")"
  eq "verifica di Play Protect spenta e poi rimessa com'era" "impostazione get verifier_verify_adb_installs"$'\n'"impostazione put verifier_verify_adb_installs 0"$'\n'"impostazione put verifier_verify_adb_installs 1" "$(sed -n 1,3p "$WORK/set_$$")"
  rm -f "$WORK/a_$$" "$WORK/inst_x11_$$" "$WORK/inst_api_$$"
  adb() { [[ $1 == devices ]] && echo "List of devices attached"; }
  x11_app_ensure >/dev/null 2>&1
  has "senza ADB: lo dice" "ADB non è collegato" "$(cat "$WORK/a_$$")"
  has "senza ADB: si apre l'installazione" "apri" "$(cat "$WORK/a_$$")"
}

test_api_app_download() { # Termux:API dalla release di GitHub, l'APK "github", controllato con lo sha256
  command -v jq >/dev/null && command -v sha256sum >/dev/null || return 0
  local sum
  net_get() {
    case $1 in
      *releases/latest) printf '%s' '{"tag_name":"v0.53.0","assets":[
        {"name":"termux-api-app_v0.53.0+fdroid.apk","browser_download_url":"https://x/fdroid.apk"},
        {"name":"termux-api-app_v0.53.0+github.debug.apk","browser_download_url":"https://x/termux-api-app_v0.53.0%2Bgithub.debug.apk"},
        {"name":"checksums-sha256.txt","browser_download_url":"https://x/sums"}]}' ;;
      */sums) printf '%s  termux-api-app_v0.53.0+github.debug.apk\n' "$sum" ;;
    esac
  }
  net_download() { echo "$1" >"$WORK/url_$$"; printf 'apk vero' >"$2"; }
  sum=$(printf 'apk vero' | sha256sum | cut -d' ' -f1)
  TOD_API_APK="$WORK/api_$$.apk"
  api_app_download
  eq "l'APK della build GitHub" "https://x/termux-api-app_v0.53.0%2Bgithub.debug.apk" "$(cat "$WORK/url_$$")"
  eq "checksum giusto: si tiene" "apk vero" "$(cat "$TOD_API_APK")"
  sum=0000
  local rc=0
  api_app_download 2>/dev/null || rc=$?
  eq "checksum sbagliato: errore" 1 "$rc"
  eq "e il file non resta" "" "$(ls "$TOD_API_APK" 2>/dev/null)"
}

test_desktop_pacchetti_nostri() { # i pacchetti delle parti nostre, chiesti per nome e con il nome giusto
  pkg_has() { return 0; }
  pkg_install() { echo "$*" >>"$WORK/pk_$$"; }
  pkg_install_avail() { echo "$*" >>"$WORK/pk_$$"; }
  desktop_preconfigure() { :; }
  desktop_install xfce
  local tutto; tutto=$(cat "$WORK/pk_$$")
  has "pygobject (Start, Impostazioni...)" "pygobject" "$tutto"
  has "gvfs (dischi in Esplora file)" "gvfs" "$tutto"
  has "termux-api (batteria, notifiche)" "termux-api" "$tutto"
  # in Termux "python-gobject" non esiste: chiederlo non installava niente, e su un telefono nuovo
  # le nostre finestre non partivano
  eq "nessuno chiede python-gobject" "" "$(grep -rn 'install[a-z_]* .*python-gobject' "$ROOT/lib" "$ROOT/tod" || true)"
  local base
  base=$(desktop_packages xfce)
  has "Fluent GTK: la base di DeX OS" "fluent-gtk-theme" "$(grep -A5 '^look_apply_windows11()' "$ROOT/lib/look.sh")"
  local p
  for p in xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin xfce4-clipman-plugin xfce4-docklike-plugin \
    xfce4-genmon-plugin fluent-icon-theme; do   # la barra di XFCE non c'è più: niente plugin né icone Fluent
    hasnt "niente $p" "$p" "$base $(grep -A5 '^look_apply_windows11()' "$ROOT/lib/look.sh")"
  done
}

test_spegni_subito() { # "tod spegni --subito" (dalla finestrella dello spegnimento) spegne davvero,
  # non riapre la finestrella: prima "--subito" si cercava al posto sbagliato e le due si richiamavano
  eval "$(sed -n '/^tod_main() {/,/^}/p' "$ROOT/tod")"   # solo la funzione, senza eseguire tod
  setsid() { echo "$*" >>"$WORK/spegni_$$"; }
  have() { return 0; }
  local DISPLAY=:9
  # tod spegni lancia in sottofondo (&): si aspetta prima di leggere, sennò è una gara
  tod_main spegni --subito; wait
  has "--subito: servizi e desktop" "tod stop" "$(cat "$WORK/spegni_$$")"
  : >"$WORK/spegni_$$"
  TOD_SPEGNIMENTO=1 tod_main spegni; wait
  has "lanciato dalla finestrella: mai di nuovo la finestrella" "tod stop" "$(cat "$WORK/spegni_$$")"
  : >"$WORK/spegni_$$"
  tod_main spegni; wait
  has "dal desktop: prima le app" "tod-spegni.py" "$(cat "$WORK/spegni_$$")"
}

test_apt_strumenti_dischi() { # gli strumenti dei dischi sono pacchetti come gli altri: Termux, sennò il container
  pkg_has() { [[ $1 == e2fsprogs || $1 == htop ]]; }
  pkg_installed() { return 1; }
  cx_installed() { return 0; }
  cx_pkg_list() { :; }
  cx_has() { [[ $1 == ntfs-3g ]]; }
  apt_native() { echo "termux:$*" >>"$WORK/aptd_$$"; }
  cx_apt() { echo "debian:$*" >>"$WORK/aptd_$$"; }
  cx_sync_apps() { :; }
  : >"$WORK/aptd_$$"
  apt_cli install e2fsprogs ntfs-3g htop >/dev/null
  eq "Termux per quel che ha, NTFS dal container" $'termux:install e2fsprogs htop\ndebian:install ntfs-3g' "$(cat "$WORK/aptd_$$")"
}

test_app_one_system() { # la stessa app non si installa né compare in due sistemi
  command -v awk >/dev/null || return 0
  eq "chiavi" "firefox vlc vscode gimp obs libreoffice-writer" \
    "$(printf 'firefox-esr\nvlc-qt\ncode-oss\norg.gimp.GIMP.desktop\ncom.obsproject.Studio.desktop\nlibreoffice-writer\n' |
      awk -f "$ROOT/share/tod-app-keys.awk" -v mode=names | tr '\n' ' ' | sed 's/ $//')"
  # Termux finto: firefox installato, con la sua voce di menu; una nascosta non conta
  local info="$PREFIX/var/lib/dpkg/info" apps="$PREFIX/share/applications"
  mkdir -p "$info" "$apps"
  printf '%s\n' "$apps/firefox.desktop" >"$info/firefox.list"
  printf '[Desktop Entry]\nName=Firefox\n' >"$apps/firefox.desktop"
  printf '%s\n' "$apps/gcr-viewer.desktop" >"$info/gcr.list"
  printf '[Desktop Entry]\nName=Gcr\nNoDisplay=true\n' >"$apps/gcr-viewer.desktop"
  cx_installed() { return 1; }
  pkg_installed() { return 1; }
  eq "firefox-esr è già firefox" firefox "$(app_owner firefox-esr)"
  eq "componente nascosto: non è un'app" "" "$(app_owner gcr)"
  pkg_has() { return 0; }
  apt_native() { echo "termux:$*" >>"$WORK/one_$$"; }
  apt_cli install firefox-esr >"$WORK/one_err_$$" 2>&1
  eq "niente seconda copia" "" "$(cat "$WORK/one_$$" 2>/dev/null)"
  has "spiega perché" "già installata (firefox)" "$(cat "$WORK/one_err_$$")"
  # menu: la voce del container non compare se Termux ha già l'app
  _fake_rootfs
  export TOD_TERMUX_HOME=$HOME
  mkdir -p "$R/var/lib/dpkg/info" "$R/usr/share/applications"
  printf '/usr/share/applications/firefox-esr.desktop\n' >"$R/var/lib/dpkg/info/firefox-esr.list"
  printf '[Desktop Entry]\nName=Firefox ESR\nExec=firefox-esr\n' >"$R/usr/share/applications/firefox-esr.desktop"
  desktop_refresh_caches() { :; }
  cx_export_pkgs firefox-esr
  eq "niente doppione nello Start" no "$([[ -e $HOME/.local/share/applications/tod-cx-firefox-esr.desktop ]] && echo si || echo no)"
  # il controllo dentro apt di Debian
  conf_set CX_PKEXEC 0
  cx_install_runner
  local g="$R/usr/local/bin/tod-app-guard" rc=0
  sh -n "$g"
  printf 'VERSION 2\nCommandLine::AsString=apt-get%%20install%%20-o%%20Debug::X=1%%20-y%%20firefox-esr\n\nfirefox-esr - < 128.0 /var/cache/apt/archives/f.deb\nlibfoo - < 1.0 /x/l.deb\n' |
    sh "$g" 2>"$WORK/guard_$$" || rc=$?
  eq "apt di Debian si ferma" 1 "$rc"
  has "e lo dice" "firefox-esr" "$(cat "$WORK/guard_$$")"
  rc=0
  printf 'VERSION 2\nCommandLine::AsString=apt install foo\n\nfirefox-esr - < 128.0 /x/f.deb\nfoo - < 1.0 /x/foo.deb\n' | sh "$g" || rc=$?
  eq "le dipendenze passano" 0 "$rc"
  rc=0
  printf 'VERSION 2\nCommandLine::AsString=apt install firefox-esr\n\nfirefox-esr - < 128.0 /x/f.deb\n' | TOD_MENU_SYNC=0 sh "$g" || rc=$?
  eq "da tod apt: già controllato" 0 "$rc"
  # la stessa app, se Termux ce l'ha con un altro nome, viene da Termux
  rm -f "$info/firefox.list"
  pkg_has() { [[ $1 == firefox ]]; }
  : >"$WORK/one_$$"
  apt_cli install firefox-esr >/dev/null 2>&1
  eq "firefox-esr → firefox di Termux" "termux:install firefox" "$(cat "$WORK/one_$$")"
}

test_menu_only_useful() { # nello Start solo ciò che serve: niente demo, doppioni, dipendenze
  local sys="$PREFIX/share/applications" apps="$HOME/.local/share/applications"
  mkdir -p "$sys"
  printf '[Desktop Entry]\nName=Xarchiver\nExec=xarchiver %%f\nMimeType=application/zip;\n' >"$sys/xarchiver.desktop"
  printf '[Desktop Entry]\nName=Mousepad\n' >"$sys/org.xfce.mousepad.desktop"
  desktop_hide_useless
  has "Xarchiver nascosto" "NoDisplay=true" "$(cat "$apps/xarchiver.desktop")"
  has "ma apre ancora gli archivi" "MimeType=application/zip;" "$(cat "$apps/xarchiver.desktop")"
  eq "Mousepad resta" no "$([[ -e $apps/org.xfce.mousepad.desktop ]] && echo si || echo no)"
  printf '[Desktop Entry]\nName=Mio\n' >"$apps/thunar-settings.desktop"
  printf '[Desktop Entry]\nName=Thunar\n' >"$sys/thunar-settings.desktop"
  desktop_hide_useless
  eq "una scelta dell'utente non si tocca" "[Desktop Entry]
Name=Mio" "$(cat "$apps/thunar-settings.desktop")"
  # il resto del desktop: energia, posta, terminale in italiano, barra bloccata
  mkdir -p "$PREFIX/etc/xdg/autostart" "$PREFIX/share/Thunar/sendto" "$HOME/.config/Thunar"
  : >"$PREFIX/etc/xdg/autostart/xfce4-power-manager.desktop"
  : >"$PREFIX/share/Thunar/sendto/thunar-sendto-email.desktop"
  printf '<actions>\n<action>\n\t<name>Open Terminal Here</name>\n</action>\n</actions>\n' >"$HOME/.config/Thunar/uca.xml"
  desktop_hide_useless; desktop_hide_useless
  has "gestore dell'energia spento" "Hidden=true" "$(cat "$HOME/.config/autostart/xfce4-power-manager.desktop")"
  has "niente Invia a posta" "Hidden=true" "$(cat "$HOME/.local/share/Thunar/sendto/thunar-sendto-email.desktop")"
  eq "Apri terminale qui, una volta" 1 "$(grep -c '<name xml:lang="it">Apri terminale qui</name>' "$HOME/.config/Thunar/uca.xml")"
  has "rientro conservato" $'\t<name xml:lang="it">' "$(cat "$HOME/.config/Thunar/uca.xml")"
  desktop_tune_files
  has "barra bloccata" "CustomizePanel=NONE" "$(cat "$PREFIX/etc/xdg/xfce4/kiosk/kioskrc")"
  has "spegnimento ancora tolto" "Shutdown=NONE" "$(cat "$PREFIX/etc/xdg/xfce4/kiosk/kioskrc")"
  # container: le app arrivate come dipendenze non entrano nello Start
  _fake_rootfs
  export TOD_TERMUX_HOME=$HOME
  mkdir -p "$R/var/lib/dpkg/info" "$R/usr/share/applications" "$R/var/lib/apt"
  printf '/usr/share/applications/kdesystemsettings.desktop\n' >"$R/var/lib/dpkg/info/systemsettings.list"
  printf '[Desktop Entry]\nName=KDE\nExec=systemsettings\n' >"$R/usr/share/applications/kdesystemsettings.desktop"
  printf 'Package: systemsettings\nArchitecture: arm64\nAuto-Installed: 1\n\n' >"$R/var/lib/apt/extended_states"
  desktop_refresh_caches() { :; }
  cx_export_pkgs systemsettings
  eq "dipendenza: niente voce" no "$([[ -e $apps/tod-cx-kdesystemsettings.desktop ]] && echo si || echo no)"
  printf 'Package: systemsettings\nArchitecture: arm64\nAuto-Installed: 0\n\n' >"$R/var/lib/apt/extended_states"
  cx_export_pkgs systemsettings
  eq "scelta dall'utente: c'è" si "$([[ -e $apps/tod-cx-kdesystemsettings.desktop ]] && echo si || echo no)"
}

test_dev_tools() { # modalità sviluppo: ponte e ADB all'avvio, solo se accesa
  local calls="$WORK/dev_$$"
  # tools/ (strumenti di lavoro) non è nel repository pubblico: un ponte finto
  TOD_ROOT="$WORK/devroot_$$"; mkdir -p "$TOD_ROOT/tools"; : >"$TOD_ROOT/tools/termux-bridge"
  setsid() { echo "$*" >>"$calls"; }
  have() { [[ $1 == adb ]]; }
  conf_set SVILUPPO 0
  dev_tools_start
  eq "spenta: niente" "" "$(cat "$calls" 2>/dev/null)"
  conf_set SVILUPPO 1
  dev_tools_start
  has "ponte avviato" "tools/termux-bridge" "$(cat "$calls")"
  has "con la home di Termux" "HOME=" "$(cat "$calls")"
  has "ADB in sottofondo" "tod _dev_adb" "$(cat "$calls")"
  adb() { case $1 in devices) printf 'List of devices attached\n127.0.0.1:41234\tdevice\n' ;; esac; }
  has "ADB già collegato" "ADB collegato (127.0.0.1:41234)" "$(dev_adb_reconnect)"
  unset -f setsid have adb
}

test_open_host() { # le app di Debian aprono link e file con le app del desktop, mai comandi
  mkdir -p "$TMPDIR" "$WORK/oh_$$/bin" "$WORK/oh_$$/root/home/dex"
  printf '#!/bin/sh\necho "$1" >>"%s"\n' "$WORK/oh_$$/opened" >"$WORK/oh_$$/bin/xdg-open"
  chmod +x "$WORK/oh_$$/bin/xdg-open"
  : >"$WORK/oh_$$/root/home/dex/nota.txt"
  printf '#!/bin/sh\n' >"$WORK/oh_$$/root/home/dex/script.sh"; chmod +x "$WORK/oh_$$/root/home/dex/script.sh"
  TOD_OPEN_CMD="$WORK/oh_$$/bin/xdg-open" TOD_CX_ROOTFS="$WORK/oh_$$/root" bash "$ROOT/share/tod-open-host" >"$WORK/oh_$$/log" 2>&1 &
  local svc=$! i
  for ((i = 0; i < 50; i++)); do [[ -p $TMPDIR/tod-open.fifo ]] && break; sleep 0.1; done
  printf '%s\n' "https://accounts.google.com/x" "/home/dex/nota.txt" "/home/dex/script.sh" "rm -rf /" >"$TMPDIR/tod-open.fifo"
  for ((i = 0; i < 50; i++)); do [[ $(grep -c . "$WORK/oh_$$/opened" 2>/dev/null) -ge 2 ]] && break; sleep 0.1; done
  sleep 0.3
  kill "$svc" 2>/dev/null || true
  has "link al browser del desktop" "https://accounts.google.com/x" "$(cat "$WORK/oh_$$/opened")"
  has "file del container col percorso di Termux" "$WORK/oh_$$/root/home/dex/nota.txt" "$(cat "$WORK/oh_$$/opened")"
  eq "mai eseguibili né comandi" 2 "$(grep -c . "$WORK/oh_$$/opened")"
  has "rifiuti nel registro" "rifiutato" "$(cat "$WORK/oh_$$/log")"
  # xdg-open del desktop: le app del desktop (xdg-utils), non termux-open (app di Android)
  mkdir -p "$WORK/oh_$$/pfx/bin"
  printf '#!/bin/sh
echo "desktop $1"
' >"$WORK/oh_$$/pfx/bin/xdg-utils-xdg-open"
  printf '#!/bin/sh
echo "android $1"
' >"$WORK/oh_$$/pfx/bin/termux-open"
  chmod +x "$WORK/oh_$$/pfx/bin/"*
  eq "link alle app del desktop" "desktop app://x" "$(PREFIX="$WORK/oh_$$/pfx" sh "$ROOT/share/bin/xdg-open" app://x)"
  rm -f "$WORK/oh_$$/pfx/bin/xdg-utils-xdg-open"
  eq "senza xdg-utils: Android" "android app://x" "$(PREFIX="$WORK/oh_$$/pfx" sh "$ROOT/share/bin/xdg-open" app://x)"
  # nel container: xdg-open che passa dal desktop, e browser predefinito per GIO
  _fake_rootfs
  mkdir -p "$R/home/dex/.config"
  printf '[Default Applications]\nx-scheme-handler/app=org.esempio.App.desktop\nx-scheme-handler/https=firefox.desktop\n' \
    >"$R/home/dex/.config/mimeapps.list"
  conf_set CX_PKEXEC 0
  cx_install_runner; cx_install_runner
  sh -n "$R/usr/local/bin/xdg-open"
  has "xdg-open del container" "tod-open.fifo" "$(cat "$R/usr/local/bin/xdg-open")"
  # senza proot /tmp è quella del container: la FIFO di Termux arriva da TMPDIR (26 ottobre: il login di
  # un'app non apriva più il browser). Copia con un /tmp finto: mai scrivere nella FIFO vera del desktop
  mkdir -p "$WORK/xo_$$/tmp"
  sed "s|/tmp/tod-open.fifo|$WORK/xo_$$/nessuna.fifo|" "$R/usr/local/bin/xdg-open" >"$WORK/xo_$$/xdg-open"
  mkfifo "$WORK/xo_$$/tmp/tod-open.fifo"
  (cat "$WORK/xo_$$/tmp/tod-open.fifo" >"$WORK/xo_$$/letto") &
  TMPDIR="$WORK/xo_$$/tmp" sh "$WORK/xo_$$/xdg-open" https://example.com/login >/dev/null 2>&1 || true
  # se non ha scritto nella FIFO, il lettore resterebbe appeso: lo si sblocca
  timeout 2 sh -c ': >"$1"' _ "$WORK/xo_$$/tmp/tod-open.fifo" 2>/dev/null || true
  wait
  eq "senza proot: la FIFO da TMPDIR" "https://example.com/login" "$(cat "$WORK/xo_$$/letto")"
  eq "https al desktop, una volta" 1 "$(grep -c '^x-scheme-handler/https=tod-host-open.desktop' "$R/home/dex/.config/mimeapps.list")"
  has "gli altri link restano alla loro app" "x-scheme-handler/app=org.esempio.App.desktop" "$(cat "$R/home/dex/.config/mimeapps.list")"
  eq "il vecchio browser tolto" 0 "$(grep -c firefox "$R/home/dex/.config/mimeapps.list")"
}

test_updates_progress() { # avanzamento vero da apt: MB scaricati, velocità, installazione
  has "stato di apt" "APT::Status-Fd=1" "$(cat "$ROOT/share/tod-updates.py")"
  eq "dimensioni di apt in italiano e inglese" "123000000 1234000 1234000 12300000 12300000" "$(python3 -c "
import importlib.util
sp = importlib.util.spec_from_file_location('u', '$ROOT/share/tod-updates.py'); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(' '.join(str(int(m.parse_size(*a))) for a in (('123', 'MB'), ('1.234', 'kB'), ('1,234', 'kB'), ('12,3', 'MB'), ('12.3', 'MB'))))")"
}

test_usb_lkl_servizio() { # il servizio: chi serve una partizione, dischi da non richiedere, niente macchina
  local th="$HOME/thlkl" run="$HOME/runlkl" u="$ROOT/share/usb/tod-usb" f out
  mkdir -p "$th/.config/tod" "$th/.local/share/tod-usb" "$run"
  f=$(sed -n '/^lkl_di() {/,/^}/p; /^VISTI=/p; /^usb_nuovi() {/,/^}/p' "$u")
  local base=(env TH="$th" DATA="$th/.local/share/tod-usb" LKLBIN="$th/.local/share/tod-usb/tod-lkl" RUN="$run")
  printf 'DATI\tusb1\tChiavetta USB\tX\t1\tvfat\tDATI\tA-B\nFOTO\tusb1\tChiavetta USB\tX\t1\texfat\tFOTO\tC-D\n' >"$run/lkl-usb1.volumi"
  printf 'DATI 2\tusb2\tChiavetta USB\tX\t1\tvfat\tDATI\tA-B\n' >"$run/lkl-usb2.volumi"
  eq "partizione del primo disco" "usb1" "$("${base[@]}" bash -c "$f"$'\n''lkl_di FOTO')"
  eq "stesso nome con il numero: il secondo" "usb2" "$("${base[@]}" bash -c "$f"$'\n''lkl_di "DATI 2"')"
  eq "partizione sconosciuta: nessuno" "" "$("${base[@]}" bash -c "$f"$'\n''lkl_di ALTRO')"
  # dispositivi: già visti, espulsi e già serviti non si richiedono; un espulso scollegato si dimentica
  echo file:/a >"$run/espulsi"; echo file:/b >"$run/lkl-dev-usb3"
  out=$("${base[@]}" bash -c "is_storage() { return 0; }"$'\n'"$f"$'\n''VISTI=file:/c; usb_nuovi "$(printf "file:/a\nfile:/b\nfile:/c\nfile:/d")"')
  eq "solo il disco nuovo" "file:/d" "$out"
  "${base[@]}" bash -c "is_storage() { return 0; }"$'\n'"$f"$'\n''usb_nuovi file:/d' >/dev/null
  eq "espulso e scollegato: dimenticato" "" "$(cat "$run/espulsi")"
  hasnt "niente più macchina dei dischi" "qemu" "$(tr 'A-Z' 'a-z' <"$u" | grep -v 'qemu, fino al\|tolta il')"
  # i resti della macchina: il blocco in ~/.ssh/config e i canali vanno via, il resto di config resta
  mkdir -p "$th/.ssh"; printf 'Host mio\n# tod-usb inizio\nHost tod-usb\n  Port 2222\n# tod-usb fine\n' >"$th/.ssh/config"
  : >"$run/canale-1.sock"
  "${base[@]}" TMPDIR="$HOME" bash -c "$(sed -n '/^pulisci_macchina() {/,/^}/p' "$u")"$'\n''pulisci_macchina'
  eq "config di ssh ripulito" "Host mio" "$(cat "$th/.ssh/config")"
  eq "canali via" no "$([[ -e $run/canale-1.sock ]] && echo si || echo no)"
  has "tod-lkl smonta tutto alla fine della sessione" "lkl_ferma_tutti" "$(sed -n '/^ferma() {/,/^}/p' "$u")"
}

test_tod_disco_lkl() { # comandi da terminale con LKL: lsblk/blkid dai dati di tod-lkl, pausa per chi cambia il disco
  local run="$HOME/tmpdisco/tod-usb" bin="$HOME/bindisco" so="$HOME/disco.so" w="$ROOT/share/bin/tod-disco" out
  mkdir -p "$run" "$bin" "$PREFIX/bin"
  # una libreria vera qualsiasi al posto del disco finto (un file vuoto fa protestare il linker a ogni comando)
  local l; for l in /usr/lib/aarch64-linux-gnu/libm.so.6 /lib/*/libm.so.6 /system/lib64/libm.so; do [[ -f $l ]] && { cp "$l" "$so"; break; }; done
  [[ -f $so ]] || : >"$so"
  printf '0\t0\t8000000000\tChiavetta USB\tDataTraveler\n1\t1048576\t4000000000\tvfat\tDATI\tAB12-CD34\tDATI\n2\t4001048576\t3000000000\tvfat\t\tEF56-7890\t-\n' >"$run/lkl-usb3.parti"
  printf '#!/bin/sh\necho "$@" >>%s/ncat.log; echo ok\n' "$bin" >"$bin/ncat"
  printf '#!/bin/sh\necho "fdisk $*"\n' >"$PREFIX/bin/fdisk"
  printf '#!/bin/sh\necho "mkfs.vfat $* (preload: $LD_PRELOAD)"\n' >"$PREFIX/bin/mkfs.vfat"
  chmod +x "$bin/ncat" "$PREFIX/bin/fdisk" "$PREFIX/bin/mkfs.vfat"
  local e=(env PATH="$bin:$PATH" PREFIX="$PREFIX" TMPDIR="$HOME/tmpdisco" TOD_DISCO_SO="$so")
  out=$("${e[@]}" bash "$w" lsblk)
  has "il disco" "sda         7.5G    0 disk" "$out"
  has "partizione montata" "/media/usb/DATI" "$out"
  hasnt "non montata: niente cartella" "/media/usb/-" "$out"
  out=$("${e[@]}" bash "$w" blkid)
  has "etichetta e uuid" '/dev/sda1: LABEL="DATI" UUID="AB12-CD34" TYPE="vfat"' "$out"
  has "senza etichetta: i campi non scivolano" '/dev/sda2: UUID="EF56-7890" TYPE="vfat"' "$out"
  eq "fdisk -l: i nostri dischi" "fdisk -l /dev/sda" "$("${e[@]}" bash "$w" fdisk -l)"
  out=$("${e[@]}" bash "$w" mkfs.vfat -F 32 /dev/sda2)
  has "il programma vero col disco finto" "mkfs.vfat -F 32 /dev/sda2 (preload: $so" "$out"
  eq "chi cambia il disco: pausa e ripresa sul suo disco" "$(printf -- '-U %s\n-U %s' "$run/lkl-usb3.ctl" "$run/lkl-usb3.ctl")" "$(cat "$bin/ncat.log")"
  : >"$bin/ncat.log"; "${e[@]}" bash "$w" fdisk -l /dev/sda >/dev/null
  eq "fdisk -l solo legge: niente pausa" "" "$(cat "$bin/ncat.log")"
  out=$("${e[@]}" bash "$w" mkntfs /dev/sda2 2>&1 || true)
  has "programma che Termux non ha: come installarlo" "sudo apt install ntfs-3g" "$out"
}

test_tod_dischi_dati() { # Dischi: dischi dai file di tod-lkl (stesso ordine di tod-disco), spazio libero, azioni
  python3 -c "import gi; gi.require_version('Gtk', '3.0')" 2>/dev/null || return 0
  local run="$HOME/tmpdischi/tod-usb" out
  mkdir -p "$run"
  printf '0\t0\t1000000000\tScheda SD\tLettore\tdos\n1\t1048576\t400000000\texfat\tFOTO\tAB-CD\tFOTO\n' >"$run/lkl-usb10.parti"
  printf '1\t100000000\t399000000\n' >"$run/lkl-usb10.spazio"
  printf '0\t0\t2000000000\tChiavetta USB\tKingston\t\n' >"$run/lkl-usb2.parti"
  out=$(TMPDIR="$HOME/tmpdischi" LANGUAGE=it python3 - "$ROOT/share/tod-dischi.py" <<'EOF'
import importlib.util as u, sys
s = u.spec_from_file_location("d", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
dd = m.leggi_dischi()
print([(d["id"], d["dev"]) for d in dd])
k = dd[1]
print(k["parti"][0]["dev"], k["parti"][0]["spazio"], [(i, n // 1000000) for i, n in k["liberi"]])
print(dd[0]["liberi"], m.misura(1500000000))
EOF
)
  has "ordine come tod-disco: usb2 = sda, usb10 = sdb" "[('usb2', '/dev/sda'), ('usb10', '/dev/sdb')]" "$out"
  has "partizione, spazio usato e libero dopo (allineato a 1 MiB)" "/dev/sdb1 (100000000, 399000000) [(401604608, 597)]" "$out"
  has "senza tabella: niente spazio libero da usare" "[] 1,5 GB" "$out"
  has "Dischi è il nostro" "tod-dischi.py" "$(sed -n '/^dischi() {/,/^}/p' "$ROOT/share/usb/tod-usb")"
  # 1° novembre: con il desktop in inglese la finestra mostrava "Chiavetta USB" (nome interno di tod-lkl)
  out=$(LANGUAGE=en LANG=en_US.UTF-8 python3 - "$ROOT/share/tod-dischi.py" <<'EOF'
import importlib.util as u, sys
s = u.spec_from_file_location("d", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
print(m.tipo_testo("Chiavetta USB"), "|", m.tipo_testo("Scheda SD"), "|", m.tipo_testo("altro"))
EOF
)
  eq "tipo del disco tradotto in inglese" "USB stick | SD card | altro" "$out"
}

test_usb_notifiche_lingua() { # 1° novembre: le notifiche del servizio dei dischi erano solo in italiano
  eval "$(sed -n '/^msg() {/p' "$ROOT/share/usb/tod-usb")"
  eq "notifica in inglese" "You can unplug the drive." "$(LANGUAGE=en msg "Puoi scollegare il disco." "You can unplug the drive.")"
  eq "notifica in italiano" "Puoi scollegare il disco." "$(LANGUAGE=it_IT msg "Puoi scollegare il disco." "You can unplug the drive.")"
  eq "senza lingua: inglese" "B" "$(LANGUAGE='' LANG='' msg A B)"
  hasnt "nessuna notifica con il testo scritto fisso" 'notify "$name" "P' "$(cat "$ROOT/share/usb/tod-usb")"
}

test_usb_porte_senza_java() { # termux-usb -l (Java) solo quando l'elenco di /sys cambia, o ogni 60 s
  local u="$ROOT/share/usb/tod-usb" sys="$HOME/sysusb" f out
  mkdir -p "$sys/usb1" "$sys/1-1"
  ln -s /non/leggibile "$sys/1-1.2"   # come su Android: collegamenti verso cartelle vietate
  f=$(sed -n '/^usb_firma() {/,/^}/p; /^attendi() {/,/^}/p; /^da_chiedere() {/,/^}/p' "$u")
  out=$(TOD_USB_SYS="$sys" bash -c "$f"'
SECONDS=100; usb_firma; prima=$USB_FIRMA
da_chiedere "$prima" 90 && echo uguale-10s || echo no-uguale-10s
da_chiedere "$prima" 30 && echo uguale-70s || echo no-uguale-70s
mkdir "'"$sys"'/1-1.3"; usb_firma
da_chiedere "$prima" 99 && echo cambiato || echo no-cambiato
TOD_USB_SYS=/non/esiste; usb_firma
da_chiedere "" 98 && echo vuoto-2s || echo no-vuoto-2s
da_chiedere "" 95 && echo vuoto-5s || echo no-vuoto-5s
ATTESA_FD=""; t=$SECONDS; attendi 0.1; echo attesa-ok
TOD_USB_SYS="'"$sys"'"; usb_firma; prima=$USB_FIRMA
da_chiedere "$prima" 99 105 && echo dopo-cambio || echo no-dopo-cambio
da_chiedere "$prima" 99 0 && echo finito || echo no-finito')
  eq "porte uguali: niente Java per 60 s" "no-uguale-10s" "$(echo "$out" | sed -n 1p)"
  eq "dopo 60 s si richiede comunque" "uguale-70s" "$(echo "$out" | sed -n 2p)"
  eq "chiavetta collegata: si richiede subito" "cambiato" "$(echo "$out" | sed -n 3p)"
  eq "elenco non leggibile: come prima, non prima di 4 s" "no-vuoto-2s" "$(echo "$out" | sed -n 4p)"
  eq "elenco non leggibile: ogni 4 s" "vuoto-5s" "$(echo "$out" | sed -n 5p)"
  eq "attesa senza fifo" "attesa-ok" "$(echo "$out" | sed -n 6p)"
  has "i collegamenti verso cartelle vietate contano" "1-1.2 " "$(TOD_USB_SYS="$sys" bash -c "$f"$'\n''usb_firma; echo "$USB_FIRMA"')"
  eq "dopo un cambio si richiede finché Android non ha il dispositivo" "dopo-cambio" "$(echo "$out" | sed -n 7p)"
  eq "finita la finestra, di nuovo ogni 60 s" "no-finito" "$(echo "$out" | sed -n 8p)"
  has "riavvia prende l'ambiente dalla nostra barra" "tod-barra.py" "$(grep -n 'pan=' "$u")"
  # tra un controllo delle porte e l'altro: il giro completo solo se un disco aperto è cambiato
  local run="$HOME/runporte"
  mkdir -p "$run"
  f=$(sed -n '/^lkl_vivo() {/,/^}/p; /^giro_serve() {/,/^}/p' "$u")
  sleep 30 & local vivo=$!
  echo /dev/bus/usb/001/011 >"$run/lkl-dev-usb4"; echo "$vivo" >"$run/lkl-usb4.pid"
  : >"$run/lkl-usb4.volumi"; touch -d '1 minute ago' "$run/lkl-usb4.volumi"; : >"$run/volumi"
  out=$(RUN="$run" bash -c "$f"$'\n''giro_serve && echo serve || echo niente')
  eq "disco vivo, partizioni già lette: niente giro" "niente" "$out"
  touch -d '1 minute' "$run/lkl-usb4.volumi"
  out=$(RUN="$run" bash -c "$f"$'\n''giro_serve && echo serve || echo niente')
  eq "partizioni nuove: giro" "serve" "$out"
  touch -d '1 minute ago' "$run/lkl-usb4.volumi"; kill "$vivo"; wait "$vivo" 2>/dev/null || true
  out=$(RUN="$run" bash -c "$f"$'\n''giro_serve && echo serve || echo niente')
  eq "disco finito (espulso, scollegato): giro" "serve" "$out"
  hasnt "il controllo leggero non avvia processi" '$(' "$(sed -n '/^giro_serve() {/,/^}/p; /^lkl_vivo() {/,/^}/p' "$u")"
  # dopo ogni giro si ricorda cosa ha visto (sennò un disco in errore si riapriva all'infinito)
  eq "ogni giro aggiorna VISTI" "$(grep -c 'giro "\$devs"' "$u")" "$(grep -c 'giro "\$devs"; VISTI=\$devs' "$u")"
}

test_usb_volumi() { # dischi in Esplora file: un'unità per disco, un volume per partizione, nomi e icone
  python3 -c "import gi; gi.require_version('Gio', '2.0'); from gi.repository import Gio" 2>/dev/null || return 0
  local tmp="$HOME/tmpvol" out
  mkdir -p "$tmp/tod-usb"
  printf 'EMUELEC\tsda\tScheda SD\tUSB Storage\t805306368\tvfat\tEMUELEC\t1510-0052\nScheda SD 2\tsda\tScheda SD\tUSB Storage\t1\text4\t\tc1e9\nDATI\tsdb\tChiavetta USB\tFlash\t1\texfat\tDATI\tAB-CD\n' \
    >"$tmp/tod-usb/volumi"
  out=$(TMPDIR="$tmp" python3 - "$ROOT/share/usb/tod-volumi.py" <<'PY'
import importlib.util as u, sys
s = u.spec_from_file_location("v", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
from gi.repository import GLib
d, v = m.leggi()
GLib.Variant(f"(a{m.DRIVE}a{m.VOLUME}a{m.MOUNT})", ([m.drive_struct(x) for x in d.values()], [m.volume_struct(x) for x in v], [m.mount_struct(x) for x in v]))
print(" ".join(f"{x['nome']}:{len(x['volumi'])}:{m.drive_struct(x)[2]}" for x in d.values()))
print(" ".join(x["uri"] for x in v))
PY
)
  eq "unità e volumi" "EMUELEC:1:. GThemedIcon media-flash-sd media-flash-sd-mmc media-flash drive-removable-media Scheda SD 2:1:. GThemedIcon media-flash-sd media-flash-sd-mmc media-flash drive-removable-media DATI:1:. GThemedIcon drive-removable-media-usb drive-removable-media
file:///media/usb/EMUELEC file:///media/usb/Scheda%20SD%202 file:///media/usb/DATI" "$out"
}

test_usb_non_dischi() { # un errore nel chiedere al dispositivo non deve farlo ignorare per sempre
  local bin="$HOME/binnd" run="$HOME/runnd" out
  mkdir -p "$bin" "$run"
  local f; f=$(sed -n '/^is_storage() {/,/^}/p' "$ROOT/share/usb/tod-usb")
  printf '#!/bin/sh\necho "Permission denied"\n' >"$bin/termux-usb"; chmod +x "$bin/termux-usb"
  PATH="$bin:$PATH" RUN="$run" HERE=/x bash -c "$f"$'\n''is_storage /dev/bus/usb/002/004' || true
  eq "errore: nessun segno" "" "$(cat "$run/nondischi" 2>/dev/null)"
  printf '#!/bin/sh\necho %s\n' "'{\"classes\": [3], \"storage\": false}'" >"$bin/termux-usb"
  PATH="$bin:$PATH" RUN="$run" HERE=/x bash -c "$f"$'\n''is_storage /dev/bus/usb/001/006' || true
  eq "tastiera: segnata" "/dev/bus/usb/001/006" "$(cat "$run/nondischi" 2>/dev/null)"
  printf '#!/bin/sh\necho %s\n' "'{\"classes\": [8], \"storage\": true}'" >"$bin/termux-usb"
  out=$(PATH="$bin:$PATH" RUN="$run" HERE=/x bash -c "$f"$'\n''is_storage /dev/bus/usb/002/004 && echo disco')
  eq "lettore di schede: disco" "disco" "$out"
}

test_updates_center() { # Aggiornamenti: elenco da apt, app riconosciute, mai i pacchetti protetti
  command -v python3 >/dev/null || return 0
  local info="$PREFIX/var/lib/dpkg/info" apps="$PREFIX/share/applications" out
  mkdir -p "$info" "$apps"
  printf '%s\n' "$apps/gimp.desktop" >"$info/gimp.list"
  printf '[Desktop Entry]\nName=GNU Image Manipulation Program\nName[it]=GIMP\nIcon=gimp\nExec=gimp-3.2 %%U\n' >"$apps/gimp.desktop"
  out=$(PREFIX="$PREFIX" HOME="$HOME" TOD_TERMUX_HOME="$HOME" LANGUAGE=it python3 - "$ROOT/share/tod-updates.py" <<'EOF'
import importlib.util as u, sys, json
s = u.spec_from_file_location("up", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
lst = """Listing...
gimp/x11 3.2.6-1 aarch64 [upgradable from: 3.2.6]
mesa/x11 26.1 aarch64 [upgradable from: 26.0]
termux-x11-nightly/x11 1.03 all [aggiornabile da: 1.02]
curl/stable 8.23.0 aarch64 [aggiornabile da: 8.22.0]
"""
def fake(cmd, timeout=900):
    if cmd[:2] == ["apt-mark", "showhold"]: return 0, "mesa\n"
    if cmd[:2] == ["apt", "list"]: return 0, lst
    return 0, ""
m.run = fake
m.rootfs = lambda: None
st = m.check(refresh=False)
print(" ".join(x["name"] for x in st["termux"]))
print(st["termux"][0].get("app"), st["termux"][0]["from"], st["termux"][0]["to"])
print(m.summary(st))
# aggiornare una sola app: solo quel pacchetto, nel sistema giusto
calls = []
class P:
    def __init__(self, cmd, **k): calls.append(cmd); self.stdout = iter(["Setting up gimp (3.2.6-1) ...\n"])
    def wait(self): return 0
m.subprocess.Popen = P
m.install([st["termux"][0]], lambda *a: None)
m.install([{"name": "app-electron", "where": "debian"}, {"name": "curl", "where": "termux"}], lambda *a: None)
print(" | ".join(" ".join(c[c.index("--only-upgrade") + 1:]) + (" (debian)" if "proot-distro" in c else "") for c in calls))
EOF
)
  eq "solo ciò che si può aggiornare (niente driver bloccati né Termux:X11)" "gimp curl" "$(sed -n 1p <<<"$out")"
  eq "l'app con il suo nome" "GIMP 3.2.6 3.2.6-1" "$(sed -n 2p <<<"$out")"
  eq "riassunto" "GIMP e un altro aggiornamento" "$(sed -n 3p <<<"$out")"
  eq "una alla volta, o tutte: ognuna dove sta" "gimp | curl | app-electron (debian)" "$(sed -n 4p <<<"$out")"
  has "voce in Impostazioni" "X-XFCE-SettingsDialog" "$(desktop_install_entries >/dev/null 2>&1; cat "$HOME/.local/share/applications/tod-updates.desktop")"
}

test_deb_installer() { # installer grafico dei .deb: legge nome, icona e versione; avvisa solo se serve
  command -v dpkg-deb >/dev/null && command -v python3 >/dev/null || { echo "  (dpkg-deb assente: salto)"; return 0; }
  local d="$WORK/deb_$$" out
  mkdir -p "$d/pkg/DEBIAN" "$d/pkg/usr/share/applications" "$d/pkg/usr/share/icons/hicolor/48x48/apps" \
    "$d/pkg/usr/share/icons/hicolor/256x256/apps"
  printf 'Package: provaapp\nVersion: 2.0\nArchitecture: arm64\nMaintainer: Io <io@x>\nInstalled-Size: 2048\nDescription: Una prova\n Descrizione lunga.\n' >"$d/pkg/DEBIAN/control"
  printf '[Desktop Entry]\nName=Prova App\nName[it]=App di prova\nIcon=provaapp\nExec=provaapp\n' >"$d/pkg/usr/share/applications/org.prova.App.desktop"
  printf 'piccola' >"$d/pkg/usr/share/icons/hicolor/48x48/apps/provaapp.png"
  printf 'grande' >"$d/pkg/usr/share/icons/hicolor/256x256/apps/provaapp.png"
  dpkg-deb --build --root-owner-group "$d/pkg" "$d/provaapp.deb" >/dev/null 2>&1 || dpkg-deb --build "$d/pkg" "$d/provaapp.deb" >/dev/null
  out=$(LANGUAGE=it python3 - "$ROOT/share/tod-installer.py" "$d/provaapp.deb" <<'EOF'
import sys, types, importlib.util as u, tempfile
gi = types.ModuleType("gi"); gi.require_version = lambda *a: None
repo = types.ModuleType("gi.repository")
class _W: pass
class _Gtk: Window = _W
for n in ("Gdk", "GdkPixbuf", "Gio", "GLib", "Pango"): setattr(repo, n, types.SimpleNamespace(set_prgname=lambda *a: None))
repo.Gtk = _Gtk
sys.modules["gi"] = gi; sys.modules["gi.repository"] = repo
s = u.spec_from_file_location("inst", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
deb = sys.argv[2]; tmp = tempfile.mkdtemp()
files = m.contents(deb)
a = m.app_info(deb, files, tmp)
print(a["name"], a["desktop"])
print(open(a["icon"]).read())
print(m.field(deb, "Version"), m.human(m.field(deb, "Installed-Size")))
EOF
)
  eq "nome dell'app in italiano" "App di prova org.prova.App.desktop" "$(sed -n 1p <<<"$out")"
  eq "l'icona più grande" "grande" "$(sed -n 2p <<<"$out")"
  eq "versione e spazio" "2.0 2,0 MB" "$(sed -n 3p <<<"$out")"
  # i controlli di tod: dove va, se c'è già, se è più vecchio
  pkg_installed() { return 1; }
  cx_installed() { return 0; }
  cx_pkg_installed() { [[ $1 == provaapp ]]; }
  _fake_rootfs
  printf 'Package: provaapp\nStatus: install ok installed\nVersion: 3.0\n\n' >>"$R/var/lib/dpkg/status"
  out=$(deb_check "$d/provaapp.deb")
  has "va in Debian" "target=container" "$out"
  has "installata una più nuova" "installed=3.0" "$out"
  has "questa è più vecchia" "cmp=older" "$out"
  cx_pkg_installed() { return 1; }
  app_owner() { [[ $1 == provaapp ]] && echo "provaapp-termux"; }
  has "la stessa app in un altro sistema" "owner=provaapp-termux" "$(deb_check "$d/provaapp.deb")"
}

test_theme_dark() { # Impostazioni → Aspetto: chiaro/scuro subito, anche barra e Start
  _fake_xfconf
  conf_set TEMA chiaro
  eq "chiaro" Fluent-Light "$(look_w11_gtk)"
  DISPLAY=:9 look_theme_cli scuro
  eq "scelta salvata" scuro "$(conf_get TEMA)"
  eq "tema GTK scuro" Fluent-Dark "$(xfconf-query -c xsettings -p /Net/ThemeName)"
  eq "xfce4-panel mai chiamato" 0 "$(cat "$HOME/panel_calls" 2>/dev/null | wc -l)"
  has "la barra segue il tema da sola" "notify::gtk-theme-name" "$(cat "$ROOT/share/tod-barra.py")"
  has "la barra ha la sua versione scura" "True: dict(FONDO=" "$(cat "$ROOT/share/tod-barra.py")"
  DISPLAY=:9 look_theme_cli chiaro
  eq "di nuovo chiaro" Fluent-Light "$(xfconf-query -c xsettings -p /Net/ThemeName)"
  has "lo Start ha la sua versione scura" "CSS_DARK" "$(cat "$ROOT/share/tod-start.py")"
  has "Impostazioni nello Start" "tod-settings.desktop" "$(cat "$ROOT/share/tod-start.py")"
}

test_old_settings_redirect() { # tasto destro "Impostazioni della scrivania" & co. → nuove Impostazioni
  local d="$WORK/oldset_$$"
  mkdir -p "$d"
  printf '#!/bin/sh\necho "$*"\n' >"$d/python3"
  chmod +x "$d/python3"
  eq "sfondo → Aspetto" aspetto "$(PATH="$d:$PATH" sh "$ROOT/share/bin/xfdesktop-settings" | awk '{print $NF}')"
  eq "aspetto → Aspetto" aspetto "$(PATH="$d:$PATH" sh "$ROOT/share/bin/xfce4-appearance-settings" | awk '{print $NF}')"
  eq "schermo → Schermo" schermo "$(PATH="$d:$PATH" sh "$ROOT/share/bin/xfce4-display-settings" | awk '{print $NF}')"
  eq "nuovo schermo collegato: niente finestra" "" "$(PATH="$d:$PATH" sh "$ROOT/share/bin/xfce4-display-settings" --minimal)"
  has "gestore → Impostazioni" "tod-settings.py" "$(PATH="$d:$PATH" sh "$ROOT/share/bin/xfce4-settings-manager")"
  eq "campanello → Notifiche" notifiche "$(PATH="$d:$PATH" sh "$ROOT/share/bin/xfce4-notifyd-config" | awk '{print $NF}')"
  has "il pannello vero per posizione e durata" 'bin/xfce4-notifyd-config' "$(cat "$ROOT/share/tod-settings.py")"
  has "da Avanzate si arriva ancora a quelle di XFCE (senza giro)" 'bin/xfce4-settings-manager' "$(cat "$ROOT/share/tod-settings.py")"
}

test_dexos_theme() { # tema DeX OS: il blu di Fluent diventa l'accento scelto, anche nei PNG
  command -v python3 >/dev/null || return 0
  local out
  out=$(python3 - "$ROOT/share/dexos/dexos-theme.py" "$WORK" <<'EOF'
import importlib.util as u, sys, os
s = u.spec_from_file_location("dx", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
rc = m.Recolor("#8a5cf5")
print(m.rgb_hex(*rc.rgb(0x1A, 0x73, 0xE8)))            # il blu di Fluent → viola
print(m.rgb_hex(*rc.rgb(0xF2, 0xF2, 0xF2)), m.rgb_hex(*rc.rgb(0xD9, 0x30, 0x25)))   # grigio e rosso intatti
print(rc.css("a { color: #1A73E8; background: rgba(26, 115, 232, 0.3); border: #ffffff; }"))
p = os.path.join(sys.argv[2], "t.png")
m.png_write(p, 2, 1, 4, [bytearray([0x1A, 0x73, 0xE8, 255, 10, 10, 10, 128])])
m.recolor_png(p, p + ".2", rc)
w, h, bpp, rows = m.png_read(p + ".2")
print(w, h, m.rgb_hex(*rows[0][0:3]), rows[0][3], m.rgb_hex(*rows[0][4:7]), rows[0][7])
EOF
)
  eq "accento" "#895bf5" "$(sed -n 1p <<<"$out")"
  eq "gli altri colori no" "#f2f2f2 #d93025" "$(sed -n 2p <<<"$out")"
  eq "anche rgba()" "a { color: #895bf5; background: rgba(137, 91, 245, 0.3); border: #ffffff; }" "$(sed -n 3p <<<"$out")"
  eq "PNG ricolorato, trasparenza intatta" "2 1 #895bf5 255 #0a0a0a 128" "$(sed -n 4p <<<"$out")"
  # desktop: tema DeX OS quando c'è, chiaro/scuro, accento per nome
  local th="$HOME/.local/share/themes"
  mkdir -p "$th/DeX-OS-0067c0/gtk-3.0" "$th/DeX-OS-WM-Dark-1.125/xfwm4"
  : >"$th/DeX-OS-0067c0/gtk-3.0/gtk.css"; : >"$th/DeX-OS-WM-Dark-1.125/xfwm4/themerc"
  conf_set DEXOS_NAMES "DeX-OS-0067c0 DeX-OS-Dark-0067c0 DeX-OS-WM-1.125 DeX-OS-WM-Dark-1.125"
  conf_set TEMA scuro
  eq "tema scuro DeX OS, col nome dell'accento" DeX-OS-Dark-0067c0 "$(look_w11_gtk)"
  eq "cornice DeX OS della scala" DeX-OS-WM-Dark-1.125 "$(look_w11_wm)"
  # un nome per accento e per scala: GTK ricorda i temi per nome (sennò resta il colore di prima)
  local nm
  nm=$(python3 -c "
import importlib.util as u
s = u.spec_from_file_location('dx', '$ROOT/share/dexos/dexos-theme.py'); m = u.module_from_spec(s); s.loader.exec_module(m)
print(' '.join(m.names('#8A5CF5', 1.125).values()), '|', ' '.join(m.names('#0067c0', 1.0).values()))")
  eq "nomi" "DeX-OS-8a5cf5-v11 DeX-OS-Dark-8a5cf5-v11 DeX-OS-WM-1.125-v11 DeX-OS-WM-Dark-1.125-v11 | DeX-OS-0067c0-v11 DeX-OS-Dark-0067c0-v11 DeX-OS-WM-1-v11 DeX-OS-WM-Dark-1-v11" "$nm"
  # menu, popup e suggerimenti nello stile di DeX OS: fondi pieni (niente vetro), voce attiva nell'accento
  local menu
  menu=$(python3 -c "
import importlib.util as u
s = u.spec_from_file_location('dx', '$ROOT/share/dexos/dexos-theme.py'); m = u.module_from_spec(s); s.loader.exec_module(m)
print(m.vetro_css('light', '#8a5cf5'))")
  has "voce del menu nell'accento" "background-color: #8a5cf5; color: #ffffff;" "$menu"
  eq "menu con fondo pieno" 0 "$(grep -A3 '^menu, .menu, .context-menu {' <<<"$menu" | grep -c 'rgba(2')"
  eq "niente più passaggio da Adwaita/Default (il lampo di XFCE puro)" 0 "$(declare -f look_theme_reload | grep -c 'Adwaita\|Default')"
  conf_set TEMA chiaro
  DISPLAY= look_accent_cli viola
  eq "accento per nome" "#8a5cf5" "$(conf_get ACCENTO)"
  has "lo Start usa l'accento" 'replace(b"#005fb8", a)' "$(cat "$ROOT/share/tod-start.py")"
}

test_dexos_icons() { # icone DeX OS: tutte nostre (niente Fluent), complete, simboliche solo pieni, chiare e scure
  command -v python3 >/dev/null || return 0
  local out="$WORK/icons_$$" name t d
  name=$(HOME="$WORK/icons_home_$$" python3 "$ROOT/share/dexos/dexos-icons.py" build --accent "#8a5cf5" --out "$out")
  eq "nome per accento (e versione del disegno)" DeX-OS-Icons-8a5cf5-v10 "$name"
  t="$out/$name" d="$out/DeX-OS-Icons-Dark-8a5cf5-v10"
  # GIMP (tema Legacy → hicolor) si chiudeva senza image-missing da nessuna parte (26 ottobre)
  [[ -s $out/hicolor/scalable/status/image-missing.svg && -s $t/scalable/status/image-missing.svg ]]
  has "GIMP (Legacy → Color) arriva alle icone DeX OS" "Inherits=$name,hicolor" "$(cat "$out/Color/index.theme")"
  has "niente Fluent né Adwaita sotto" "Inherits=hicolor" "$(cat "$t/index.theme")"
  has "il tema scuro eredita il chiaro" "Inherits=$name,hicolor" "$(cat "$d/index.theme")"
  local f n mancano=0
  for f in folder user-home folder-download user-trash-full start-here application-pdf \
    application-vnd.debian.binary-package image-png text-plain inode-directory; do
    [[ -n $(find "$t/scalable" -name "$f.svg" -print -quit) ]] || { echo "manca $f"; return 1; }
  done
  # ogni nome dell'elenco ha la sua icona, a colori o simbolo, e la versione simbolica
  while IFS=$'\t' read -r _ n; do
    [[ -e $(find "$t" -path "*/$n.svg" -print -quit) || -e $(find "$t" -path "*/apps/$n.svg" -print -quit) ]] || mancano=$((mancano + 1))
  done < <(grep -v '^#' "$ROOT/share/dexos/icone/nomi.txt" | sed -n '1~97p')
  eq "nessun quadratino (campione dei nomi)" 0 "$mancano"
  eq "le simboliche solo con riempimenti (GTK non ricolora i tratti)" 0 "$(grep -rl 'stroke' "$t"/symbolic | wc -l)"
  [[ -e $t/symbolic/status/battery-level-50-symbolic.svg || -e $t/symbolic/panel/battery-level-50-symbolic.svg ]] ||
    { echo "manca la batteria"; return 1; }
  has "pulsanti grigio scuro nel chiaro" "#3a4150" "$(cat "$t/scalable/actions/edit-copy.svg")"
  has "e chiari nello scuro" "#e4e7ee" "$(cat "$d/scalable/actions/edit-copy.svg")"
  eq "go-home è un pulsante, non una cartella" 1 "$(grep -c '#3a4150' "$t/scalable/actions/go-home.svg")"
  has "logo dello Start" "rect" "$(cat "$t/scalable/apps/tod-start.svg")"
  eq "rifarlo non costa nulla" "$name" "$(HOME="$WORK/icons_home_$$" python3 "$ROOT/share/dexos/dexos-icons.py" build --accent "#8a5cf5" --out "$out")"
  # le simboliche vengono dai glifi già convertiti: contorni.json allineato a glifi.py
  eq "contorni aggiornati" "" "$(cd "$ROOT/share/dexos/icone" && python3 -c "
import json, glifi
c = json.load(open('contorni.json'))
print(' '.join(sorted(set(glifi.GLIFI) ^ set(c))))")"
}

test_session_log_cap() { # session.log con un tetto, anche mentre un programma ci scrive in coda
  local f="$TOD_STATE_DIR/session.log"
  mkdir -p "$TOD_STATE_DIR"
  python3 -c 'import sys; f = open(sys.argv[1], "w"); [f.write(f"riga {i}\n") for i in range(200000)]' "$f"
  exec 9>>"$f"
  SESSION_LOG_MAX=100000 session_log_cap
  echo "dopo il taglio" >&9
  exec 9>&-
  local n
  n=$(stat -c %s "$f")
  if ((n > 100000)); then echo "  ✘ registro ancora di $n byte"; return 1; fi
  has "segno del taglio" "registro accorciato" "$(sed -n 1p "$f")"
  has "le righe più recenti restano" "riga 199999" "$(tail -n 2 "$f")"
  eq "chi scrive in coda continua dopo il taglio" "dopo il taglio" "$(tail -n 1 "$f")"
  eq "niente buchi (file sparso)" 0 "$(tr -d '\n -~àèéìòù' <"$f" | wc -c)"
  SESSION_LOG_MAX=100000000 session_log_cap
  has "sotto il tetto non si tocca" "riga 199999" "$(tail -n 2 "$f")"
  head -c 300000 /dev/zero | tr '\0' 'x' >"$TOD_STATE_DIR/start.log"
  SESSION_LOG_MAX=100000 session_log_cap
  n=$(stat -c %s "$TOD_STATE_DIR/start.log")
  if ((n > 100000)); then echo "  ✘ start.log ancora di $n byte"; return 1; fi
}

test_barra_icona_finestra() { # 1° novembre (S20+): app senza voce di menu con l'icona enorme nella barra
  has "ripiego: l'icona della finestra alla misura della barra" "get_icon(px(self.dim()[1]))" \
    "$(sed -n '/def aggiorna_pulsante/,/ev.img.set_pixel_size/p' "$ROOT/share/tod-barra.py")"
  python3 -c "import gi; gi.require_version('GdkPixbuf', '2.0')" 2>/dev/null || return 0
  local out
  out=$(python3 - "$ROOT/share/tod-barra.py" <<'PYEOF'
import re, sys
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib
src = open(sys.argv[1]).read()
exec(re.search(r"^    def get_icon\(.*?(?=^    def )", src, re.S | re.M).group(0).replace("\n    ", "\n")[4:])
class P:   # _NET_WM_ICON finto: un'icona da 48x48, come quella che PhotoCraft mette sulla finestra
    def interi(self, xid, nome): return [48, 48] + [0xff3366cc] * (48 * 48)
class F: p, xid = P(), 1
pb = get_icon(F(), 26)
print(pb.get_width(), pb.get_height())
PYEOF
)
  eq "l'icona esce alla misura chiesta" "26 26" "$out"
}

test_pannelli() { # pannelli della barra: il modulo si carica, le icone della barra aprono il pannello giusto
  command -v python3 >/dev/null || return 0
  python3 -m py_compile "$ROOT/share/tod-pannelli.py" || { echo "tod-pannelli.py non compila"; return 1; }
  local out
  # le icone a destra le calcola la barra da sé (senza avviare programmi): funzioni provate senza GTK
  out=$(python3 - "$ROOT/share/tod-barra.py" "$ROOT/share/tod-phone-status.py" <<'PYEOF2'
import os, re, sys, time
src = open(sys.argv[1]).read()
ITALIAN = True
QUI = "/q"
def T(it, en): return it
exec(re.search(r"^PANNELLO = .*?(?=^def riga_volume)", src, re.S | re.M).group(0))
for nome in ("riga_volume", "riga_notifiche", "riga_orologio", "leggi_volume"):
    exec(re.search(rf"^def {nome}\(.*?(?=^\S)", src, re.S | re.M).group(0))
print("vol", riga_volume(*leggi_volume("Volume: front-left: 30000 /  46% / -20 dB\nMute: no")))
print("muto", riga_volume(*leggi_volume("Volume: front-left: 30000 /  46% / -20 dB\nMuto: sì")))
print("senza", riga_volume(*leggi_volume("")))
print("notif", riga_notifiche(False, True), riga_notifiche(True, True))
print("ora", riga_orologio(time.strptime("2026-10-23 15:07", "%Y-%m-%d %H:%M")))
ns = {"__file__": sys.argv[2], "__name__": "tod_phone_status"}
exec(compile(open(sys.argv[2]).read(), sys.argv[2], "exec"), ns)
print("batt", ns["battery"]({"battery": {"percentage": 52, "status": "DISCHARGING", "plugged": "UNPLUGGED"}}))
print("rete", ns["network"]({"wifi": {"supplicant_state": "COMPLETED", "rssi": -50, "ssid": "casa"}}))
PYEOF2
)
  has "volume: icona del livello" "audio-volume-medium-symbolic" "$out"
  has "volume: clic → pannello" "/q/tod-pannello volume</iconclick>" "$out"
  has "volume muto (pactl in italiano)" "muto <icon>audio-volume-muted-symbolic" "$out"
  has "audio assente" "Audio non disponibile" "$out"
  has "notifiche nuove, clic → pannello" "notification-new-symbolic</icon><tool>Notifiche nuove</tool><iconclick>/q/tod-pannello notifiche" "$out"
  has "non disturbare vince" "notification-disabled-symbolic" "$out"
  has "orologio: ora e data, giorno in italiano" "<span>15:07</span>" "$out"
  has "orologio: suggerimento" "<tool>venerdì 23 ottobre 2026</tool>" "$out"
  has "il clic sull'orologio apre il calendario" "/q/tod-pannello calendario</txtclick>" "$out"
  has "batteria dalla funzione (niente Python nuovo)" "batt <icon>battery-level-50-symbolic</icon>" "$out"
  has "batteria: clic → pannello" "tod-pannello batteria</iconclick>" "$out"
  has "rete dalla funzione" "rete <icon>network-wireless-signal-excellent-symbolic</icon><tool>Wi-Fi: casa" "$out"
  eq "la barra non avvia più tod-tray né tod-phone-status.py per le icone" 0 "$(grep -c '"tod-tray"\|"tod-phone-status.py"), "' "$ROOT/share/tod-barra.py")"
  has "colori: solo l'accento di sistema, nessun blu fisso" "ACCENTO" "$(sed -n '/^CSS = /,/^"""/p' "$ROOT/share/tod-pannelli.py")"
  eq "nessun colore d'accento scritto a mano" 0 "$(sed -n '/^CSS = /,/^CSS_SCURO/p' "$ROOT/share/tod-pannelli.py" | grep -ci '#0067c0\|#005fb8\|#0a84ff')"
}

test_trust_launchers() { # collegamenti fidati: solo le copie di app installate
  local d="$WORK/trust_$$" calls="$WORK/trust_calls_$$"
  mkdir -p "$d/bin" "$HOME/Desktop" "$HOME/.local/share/applications"
  printf '#!/bin/sh\n[ "$1" = set ] && echo "$*" >>"%s"\nexit 0\n' "$calls" >"$d/bin/gio"; chmod +x "$d/bin/gio"
  printf '[Desktop Entry]\nName=Craft\n' | tee "$HOME/Desktop/tod-cx-craft.desktop" >"$HOME/.local/share/applications/tod-cx-craft.desktop"
  printf '[Desktop Entry]\nName=Sconosciuto\nExec=rm -rf ~\n' >"$HOME/Desktop/strano.desktop"
  PATH="$d/bin:$PATH" files_trust_launchers
  has "app installata: fidata" "tod-cx-craft.desktop metadata::xfce-exe-checksum" "$(cat "$calls")"
  eq "file sconosciuto: mai" 0 "$(grep -c strano "$calls")"
}

test_cestino_telefono() { # file del telefono: nel Cestino (non eliminati per sempre), spostati (non copiati)
  local src="$ROOT/share/tod-gettext.c" cc
  has "cestino: g_file_trash intercettata" "int g_file_trash(void *file" "$(cat "$src")"
  has "cartelle tra dischi: ripiego solo su WOULD_RECURSE (25)" "matches(err, quark(), 25)" "$(cat "$src")"
  has "mai sopra qualcosa che c'è già" 'lstat(a, &st) != 0' "$(cat "$src")"
  has "mv -T: mai dentro a una cartella che esiste" '"mv", "-f", "-T", "--"' "$(cat "$src")"
  has "si guarda la cartella che contiene, non il file (~/Telefono non è il telefono intero)" 'const char *barra = strrchr(path, '"'"'/'"'"');' "$(cat "$src")"
  has "stesso disco e cestinabili solo in Esplora file e scrivania" '!strcasecmp(n, "thunar") || !strcasecmp(n, "xfdesktop")' "$(cat "$src")"
  has "si può spegnere" "TOD_CESTINO_CLASSICO" "$(cat "$src")"
  has "/storage/emulated: ENOENT solo per una cartella che esiste" "e == ENOENT && (stat(name, &st) != 0" "$(cat "$src")"
  has "scrivania: niente Elimina nel tasto destro" '"<Actions>/XfdesktopFileIconManager/delete"' "$(cat "$src")"
  has "Sposta nel cestino chiede conferma" "misc-confirm-move-to-trash -n -t bool -s true" "$(cat "$ROOT/lib/files.sh")"
  has "la voce Elimina si salta quando xfdesktop la aggiunge da sé" '"tod-fuori-dal-menu")) return;' "$(cat "$src")"
  has "titolo di Thunar senza \"- Thunar\"" "FOLDER_NAME_WITHOUT_THUNAR_SUFFIX" "$(cat "$ROOT/lib/files.sh")"
  cc=$(command -v clang || command -v gcc) || { echo "  (nessun compilatore: salto la compilazione)"; return 0; }
  "$cc" -shared -fPIC -O2 -Wall -Wextra -Wno-unused-parameter -Werror -o "$WORK/tc_$$.so" "$src" -ldl
  eq "contiene g_file_trash" 1 "$(grep -ac g_file_trash "$WORK/tc_$$.so" | sed 's/^[1-9][0-9]*$/1/')"
  eq "contiene g_file_move" 1 "$(grep -ac g_file_move "$WORK/tc_$$.so" | sed 's/^[1-9][0-9]*$/1/')"
}

test_inline_rename() { # rinomina in linea: il modulo compila, intercetta gtk_dialog_run, solo in Thunar
  local cc
  cc=$(command -v clang || command -v gcc) || { echo "  (nessun compilatore: salto)"; return 0; }
  "$cc" -shared -fPIC -O2 -Wall -Werror -o "$WORK/tg_$$.so" "$ROOT/share/tod-gettext.c" -ldl
  eq "intercetta la finestra" 1 "$(grep -ac gtk_dialog_run "$WORK/tg_$$.so" | sed 's/^[1-9][0-9]*$/1/')"
  has "solo in Thunar (D-Bus lo avvia come \"Thunar\")" 'strcasecmp(prg, "thunar")' "$(cat "$ROOT/share/tod-gettext.c")"
  has "si può tornare al pannello classico" "TOD_RINOMINA_CLASSICA" "$(cat "$ROOT/share/tod-gettext.c")"
  eq "scrivania: intercetta la richiesta a Thunar" 1 "$(grep -ac g_dbus_proxy_call "$WORK/tg_$$.so" | sed 's/^[1-9][0-9]*$/1/')"
  has "scrivania: solo in xfdesktop e solo RenameFile" '!strcmp(method, "RenameFile") && !strcmp(prg, "xfdesktop")' "$(cat "$ROOT/share/tod-gettext.c")"
  has "senza genitore: si cerca la finestra di Thunar attiva" "tod_active_window(dialog)" "$(cat "$ROOT/share/tod-gettext.c")"
  has "scrivania: i lanciatori cambiano il nome mostrato e rinnovano il sigillo" "tod_desk_launcher_save" "$(cat "$ROOT/share/tod-gettext.c")"
  files_rename_css
  has "stile della casella" "window.tod-rename" "$(cat "$HOME/.config/gtk-3.0/gtk.css")"
}

test_settings_uninstall() { # Impostazioni → App: disinstallare ogni tipo di app, mai i pezzi del desktop
  local f="$ROOT/share/tod-settings.py"
  has "app del telefono: conferma di Android" "android.intent.action.DELETE" "$(cat "$f")"
  has "le altre: il disinstallatore" '"tod-disinstalla.py"), dove, nome_pkg, name' "$(cat "$f")"
  has "AppImage del container" 'dove, nome_pkg = "home"' "$(cat "$f")"
  eq "protetti Thunar, XFCE, Termux" "thunar xfce4-panel xfwm4 termux-x11-nightly" "$(python3 -c "
import re
src = open('$f').read()
rx = re.compile(re.search(r'PROTECTED = re.compile\(r\"(.*?)\"\)', src).group(1))
print(' '.join(p for p in ('thunar', 'gimp', 'xfce4-panel', 'xfwm4', 'termux-x11-nightly', 'cadcraft') if rx.match(p)))")"
}

test_disinstalla() { # disinstallazione profonda: componenti orfani solo per colpa dell'app, dati nel Cestino
  local l="$PREFIX/var/lib/dpkg/info" a="$PREFIX/share/applications" c="$HOME/.config" out
  mkdir -p "$l" "$a" "$c/GIMP/3.0" "$c/tod" "$HOME/.cache/gimp" "$HOME/.config/gtk-3.0" "$HOME/Documenti/gimp"
  printf '%s\n' "$a/gimp.desktop" "$PREFIX/bin/gimp-3.2" >"$l/gimp.list"
  printf '[Desktop Entry]\nName=GIMP\nExec=gimp-3.2 %%U\nIcon=gimp\nStartupWMClass=gimp-3.2\n' >"$a/gimp.desktop"
  printf 'Package: gimp\nStatus: install ok installed\nInstalled-Size: 1000\n\nPackage: libgimp\nInstalled-Size: 300\n\n' \
    >"$PREFIX/var/lib/dpkg/status"
  echo dati >"$c/GIMP/3.0/gimprc"
  # apt simulato: "vecchio" era orfano già prima, python-x è un pezzo del desktop
  apt-get() {
    case "$*" in
      "-s autoremove") echo "Remv vecchio [1]" ;;
      "-s purge --autoremove gimp") printf 'Purg gimp [1]\nPurg vecchio [1]\nPurg libgimp:aarch64 [1]\nPurg python-x [1]\n' ;;
      purge*) echo "apt-get $*" >>"$WORK/dis_$$" ;;
    esac
  }
  gio() { echo "cestino ${*: -1}" >>"$WORK/dis_$$"; }
  desktop_refresh_caches() { :; }
  out=$(app_piano termux gimp)
  has "il programma" $'programma\tgimp\t1000' "$out"
  has "componente orfano per colpa sua" $'componente\tlibgimp\t300' "$out"
  hasnt "già orfano prima: non si tocca" "vecchio" "$out"
  hasnt "pezzi del desktop mai" "python-x" "$out"
  has "impostazioni (nome senza maiuscole)" $'dati\t'"$c/GIMP" "$out"
  has "cache" "$HOME/.cache/gimp" "$out"
  hasnt "cartelle comuni: no" "gtk-3.0" "$out"
  hasnt "i documenti mai" "Documenti" "$out"
  has "voce del menu" $'voce\tgimp.desktop' "$out"
  eq "Thunar non si disinstalla" $'protetta\t1' "$(app_piano termux thunar)"
  printf 'thunar.desktop\ngimp.desktop\n' >"$c/tod/start-aggiunte"
  printf '[Default Applications]\nimage/png=gimp.desktop;ristretto.desktop;\nimage/x-xcf=gimp.desktop\n' >"$c/mimeapps.list"
  printf '{"fissate": ["thunar.desktop", "gimp.desktop"]}' >"$c/tod/barra.json"
  app_rimuovi termux gimp 1 >/dev/null
  out=$(cat "$WORK/dis_$$")
  has "purge del programma e dei suoi orfani, non di altro" "apt-get purge -y gimp libgimp" "$out"
  hasnt "solo quelli" "vecchio" "$out"
  has "impostazioni nel Cestino" "cestino $c/GIMP" "$out"
  has "cache nel Cestino" "cestino $HOME/.cache/gimp" "$out"
  eq "Start" "thunar.desktop" "$(cat "$c/tod/start-aggiunte")"
  eq "associazioni" $'[Default Applications]\nimage/png=ristretto.desktop;' "$(cat "$c/mimeapps.list")"
  has "barra" '"thunar.desktop"' "$(cat "$c/tod/barra.json")"
  hasnt "barra senza GIMP" "gimp" "$(cat "$c/tod/barra.json")"
  : >"$WORK/dis_$$"
  app_rimuovi termux gimp 0 >/dev/null
  hasnt "senza la spunta i dati restano" "cestino" "$(cat "$WORK/dis_$$")"
}

# --- app, desktop, UI -------------------------------------------------------------
test_apps_routing() {
  pkg_has() { [[ $1 == firefox || $1 == gimp ]]; }
  pkg_install() { echo "nativo:$*" >>"$WORK/calls_$$"; }
  cx_installed() { return 0; }
  cx_pkg_install() { echo "cx:$*" >>"$WORK/calls_$$"; }
  conf_set APPS "firefox libreoffice code-oss gimp"
  apps_install_selected 2>"$WORK/warn_$$"
  eq "chiamate" $'nativo:firefox gimp\ncx:libreoffice libreoffice-gtk3' "$(cat "$WORK/calls_$$")"
  has "code-oss senza alternativa nel container" "code-oss" "$(cat "$WORK/warn_$$")"
}

test_ini_set() {
  local f="$HOME/k.ini"
  have() { [[ $1 != kwriteconfig6 ]] && command -v "$1" >/dev/null 2>&1; }
  _ini_set "$f" Daemon Autolock false
  _ini_set "$f" Daemon LockOnResume false
  _ini_set "$f" Daemon Autolock true
  _ini_set "$f" Altro Chiave 1
  eq "ini" $'\n[Daemon]\nLockOnResume=false\nAutolock=true\n\n[Altro]\nChiave=1' "$(cat "$f")"
}

test_desktop_entries() {
  mkdir -p "$PREFIX/share/applications"
  printf '%s\n' "[Desktop Entry]" "Name=Chromium" "Exec=@@desktop_exec %U" "Icon=@@desktop_icon" >"$PREFIX/share/applications/chromium.desktop"
  desktop_install_entries
  has "Chromium riparato: si avvia" "Exec=$PREFIX/bin/chromium-browser %U" "$(cat "$HOME/.local/share/applications/chromium.desktop")"
  has "Chromium riparato: icona" "Icon=chromium" "$(cat "$HOME/.local/share/applications/chromium.desktop")"
  local c="$HOME/.local/share/applications/tod-control.desktop" h="$HOME/.config/autostart/tod-hook.desktop"
  has "centro di controllo" "Exec=$PREFIX/bin/tod menu" "$(cat "$c")"
  has "terminale" "Terminal=true" "$(cat "$c")"
  has "hook nascosto" "NoDisplay=true" "$(cat "$h")"
  has "hook" "Exec=$PREFIX/bin/tod _hook" "$(cat "$h")"
}

test_ui_noninteractive_defaults() {
  TOD_YES=1
  eq "menu → predefinito" kde "$(ui_menu T X kde xfce XFCE kde KDE)"
  eq "checklist → voci on" $'a\nc' "$(ui_checklist T X a A on b B off c C on)"
  ui_yesno T X y
  fails ui_yesno T X n
  eq "input → predefinito" 42 "$(ui_input T X 42)"
}

test_run_step_status_and_conf_reload() {
  f_ok() { echo "dentro"; conf_set DA_STEP si; }
  run_step "passo ok" f_ok >/dev/null
  eq "config ricaricata dopo la subshell" si "$(conf_get DA_STEP)"
  has "output nel log" "dentro" "$(cat "$TOD_LOG")"
  f_ko() { echo "qualcosa"; return 7; }
  local rc=0
  run_step "passo ko" f_ko >/dev/null 2>&1 || rc=$?
  eq "codice d'uscita propagato" 7 "$rc"
  # stile dei passi: errori controllati esplicitamente (set -e non è affidabile qui)
  f_explicit() { false || return 3; echo "non deve arrivare qui"; }
  rc=0
  run_step "errore esplicito" f_explicit >/dev/null 2>&1 || rc=$?
  eq "ritorno esplicito propagato" 3 "$rc"
  hasnt "si ferma al primo errore" "non deve arrivare qui" "$(cat "$TOD_LOG")"
  # die dentro un passo: il passo fallisce, lo script principale no
  f_die() { die "esco"; }
  rc=0
  run_step "die" f_die >/dev/null 2>&1 || rc=$?
  eq "die → passo fallito" 1 "$rc"
}

test_step_retry_is_bounded() {
  local rc=0
  ( TOD_YES=1; _step prova "passo che fallisce" false ) >/dev/null 2>&1 || rc=$?
  eq "con --yes si arrende" 1 "$rc"
  fails step_done prova
  ( TOD_YES=1; _step prova2 "passo ok" true ) >/dev/null 2>&1
  step_done prova2
}

test_retry_backoff() {
  N=0
  flaky() { N=$((N + 1)); ((N >= 3)); }
  retry 3 0 flaky
  eq "tentativi" 3 "$N"
  N=0
  fails retry 2 0 flaky
}

test_phantom_adb_parsing() {
  # adb finto come programma: il codice lo lancia anche tramite timeout(1)
  cat >"$PREFIX/bin/adb" <<'EOF'
#!/bin/bash
case "$*" in
  "mdns services") printf 'List of discovered mdns services\nadb-R5CX123-AbC\t_adb-tls-connect._tcp\t192.168.1.7:37123\n' ;;
  "connect 127.0.0.1:37123") echo "connected to 127.0.0.1:37123" ;;
  "devices") printf 'List of devices attached\n127.0.0.1:37123\tdevice\nemulator-5554\tdevice\n' ;;
  *"settings get global settings_enable_monitor_phantom_procs") printf 'false\r\n' ;;
  *"device_config get activity_manager max_phantom_processes") printf '2147483647\r\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$PREFIX/bin/adb"
  PATH="$PREFIX/bin:$PATH"
  eq "mDNS → porta di connessione" 127.0.0.1:37123 "$(adb_try_mdns)"
  eq "dispositivo locale" 127.0.0.1:37123 "$(adb_local_device)"
  ADB_SERIAL=127.0.0.1:37123
  phantom_verify
  eq "monitor" false "$PH_MONITOR"
}

# --- sessione con un finto Termux:X11 (socket UNIX vero) --------------------------
_fake_x11() {
  # server finto: crea il socket X0 e resta vivo; argv[0]=app_process e la classe
  # nella riga di comando lo rendono riconoscibile a x11_server_pids, come quello vero
  cat >"$PREFIX/bin/termux-x11" <<'EOF'
#!/bin/bash
echo "$@" >"$HOME/x11_args"
exec -a app_process python3 -c '
import os, socket, sys, time
d = os.environ["TMPDIR"] + "/.X11-unix"
os.makedirs(d, exist_ok=True)
s = socket.socket(socket.AF_UNIX); s.bind(d + "/X0"); s.listen(1)
time.sleep(60)
' com.termux.x11.CmdEntryPoint "$@"
EOF
  printf '#!/bin/sh\necho "$@" >>"$HOME/am_calls"\n' >"$PREFIX/bin/am"
  cat >"$PREFIX/bin/termux-x11-preference" <<'EOF'
#!/bin/sh
if [ "$1" = list ]; then
  printf '"fullscreen"="false"\n"keepScreenOn"="false"\n"displayResolutionMode"="scaled"\n"dexMetaKeyCapture"="false"\n"showAdditionalKbd"="true"\n'
else
  echo "$@" >"$HOME/prefs_set"
fi
EOF
  chmod +x "$PREFIX/bin/termux-x11" "$PREFIX/bin/am" "$PREFIX/bin/termux-x11-preference"
  PATH="$PREFIX/bin:$PATH"
}

test_x11_prefs_una_per_volta() { # tutte insieme rifiutate: una per volta, e si sa quale non va
  local b="$WORK/xp_$$"; mkdir -p "$b"
  cat >"$b/termux-x11-preference" <<'EOF'
#!/bin/sh
case "$1" in
  list) printf '"fullscreen"="false"\n"displayResolutionMode"="scaled"\n"hideCutout"="false"\n' ;;
  *) [ $# -gt 1 ] && exit 1; case "$1" in *=*) echo "termux-x11-preference [list] {key:value}"; exit 0 ;; hideCutout:*) echo "chiave non valida"; exit 1 ;; esac; echo "$1" >>"$HOME/xp_ok" ;;
esac
EOF
  chmod +x "$b/termux-x11-preference"
  PATH="$b:$PATH"
  have() { [[ $1 == termux-x11-preference ]] || command -v "$1" >/dev/null; }
  x11_apply_prefs
  # chiave:valore come vuole lo strumento vero (con chiave=valore stampava l'uso e non applicava niente)
  has "schermo intero applicato da solo" "fullscreen:true" "$(cat "$HOME/xp_ok")"
  has "risoluzione applicata da sola" "displayResolutionMode:native" "$(cat "$HOME/xp_ok")"
  has "nel registro quale non va e perché" "hideCutout:true (chiave non valida)" "$(cat "$TOD_LOG")"
}

test_session_start_stop() {
  command -v python3 >/dev/null || { echo "  (python3 assente: salto)"; return 0; }
  _fake_x11
  conf_set INSTALLED 1
  session_start >/dev/null
  [[ -S $(x11_sock) ]]
  x11_running
  has "argomenti del server" "-ac -dpi 96 -xstartup $PREFIX/bin/tod _xstartup" "$(cat "$HOME/x11_args")"
  has "activity aperta" "com.termux.x11/com.termux.x11.MainActivity" "$(cat "$HOME/am_calls")"
  eq "preferenze DeX (solo chiavi esistenti)" \
    "fullscreen:true keepScreenOn:true displayResolutionMode:native dexMetaKeyCapture:true showAdditionalKbd:false" \
    "$(cat "$HOME/prefs_set")"
  eq "preferenze applicate una volta" "$TOD_VERSION" "$(conf_get X11_PREFS_APPLIED)"
  has "seconda chiamata: già avviato" "$(t session_already)" "$(session_start)"
  session_stop >/dev/null
  fails x11_running
  eq "socket rimosso" no "$([[ -e $(x11_sock) ]] && echo si || echo no)"
  has "stop chiesto all'app" "com.termux.x11.ACTION_STOP" "$(cat "$HOME/am_calls")"
}

test_x11_with_server_temporary() {
  command -v python3 >/dev/null || { echo "  (python3 assente: salto)"; return 0; }
  _fake_x11
  _show() { echo "DISPLAY=$DISPLAY"; [[ -S $(x11_sock) ]] && echo socket; }
  eq "server temporaneo per il comando" $'DISPLAY=:0\nsocket' "$(x11_with_server _show)"
  fails x11_running
  # codice d'uscita del comando propagato
  local rc=0
  x11_with_server sh -c 'exit 4' || rc=$?
  eq "rc" 4 "$rc"
}

test_display_tune_xfce() {
  cat >"$PREFIX/bin/xrandr" <<'EOF'
#!/bin/sh
echo "Screen 0: minimum 320 x 200, current $(cat "$HOME/res") x $(cat "$HOME/res_h"), maximum 8192 x 8192"
EOF
  cat >"$PREFIX/bin/xfconf-query" <<'EOF'
#!/bin/sh
case "$*" in
  *"-p /general/theme"*"-s"*) echo "$@" >>"$HOME/xfconf"; echo "${@: -1}" ;;
esac
case "$*" in
  *"-s "*) echo "$@" >>"$HOME/xfconf" ;;
  *"-p /general/theme") cat "$HOME/theme" 2>/dev/null ;;
esac
EOF
  chmod +x "$PREFIX/bin/xrandr" "$PREFIX/bin/xfconf-query"
  PATH="$PREFIX/bin:$PATH"
  echo 3840 >"$HOME/res"; echo 2160 >"$HOME/res_h"
  display_tune
  has "4K: DPI" "-c xsettings -p /Xft/DPI -n -t int -s 96" "$(cat "$HOME/xfconf")"
  has "4K: scala 2" "-p /Gdk/WindowScalingFactor -n -t int -s 2" "$(cat "$HOME/xfconf")"
  has "4K: tema xhdpi" "-s Default-xhdpi" "$(cat "$HOME/xfconf")"
  : >"$HOME/xfconf"; echo Default-xhdpi >"$HOME/theme"
  echo 3120 >"$HOME/res"; echo 1440 >"$HOME/res_h"
  display_tune
  has "telefono: DPI 200" "-p /Xft/DPI -n -t int -s 200" "$(cat "$HOME/xfconf")"
  has "torna al tema normale" "-p /general/theme -s Default" "$(cat "$HOME/xfconf")"
  : >"$HOME/xfconf"
  conf_set DPI 132
  display_tune
  has "DPI manuale" "-s 132" "$(cat "$HOME/xfconf")"
}

_fake_proot() { # finto proot-distro sopra il finto rootfs
  _fake_rootfs
  cat >"$PREFIX/bin/proot-distro" <<'EOF'
#!/bin/bash
# finto proot-distro: esegue il comando dopo "--" sull'host, mappando /tmp e /usr/local/bin
echo "$*" >>"$HOME/pd_calls"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
args=()
for a in "$@"; do
  case $a in
    /tmp/*) a="$TMPDIR/${a#/tmp/}" ;;
    /usr/local/bin/*) a="$ROOTFS$a" ;;
  esac
  args+=("$a")
done
exec "${args[@]}"
EOF
  chmod +x "$PREFIX/bin/proot-distro"
  PATH="$PREFIX/bin:$PATH"
  export ROOTFS="$R"
}

test_cx_plumbing_with_fake_proot() {
  _fake_proot
  local out
  out=$(cx_root uno "due tre" <<'EOF'
echo "argomenti: [$1] [$2]"
echo 'apici singoli: ok dentro lo script'
EOF
)
  has "argomenti al root script" "argomenti: [uno] [due tre]" "$out"
  has "apici negli script" "apici singoli: ok" "$out"
  eq "file temporaneo rimosso" "" "$(find "$TMPDIR" -name 'tod-cx-*' | tr -d '\n')"
  has "login come root con /tmp condiviso" "login --shared-tmp debian --" "$(cat "$HOME/pd_calls")"
  cx_install_runner
  eq "cx_run → tod-run" "ciao" "$(cx_run --raw echo ciao)"
  has "login come utente" "login --user dex --shared-tmp --bind $HOME:$HOME debian -- /usr/local/bin/tod-run --raw echo ciao" "$(cat "$HOME/pd_calls")"
  # GPU del container: scritta nel rootfs (dentro proot diventa /etc/tod/gpu.env)
  printf 'TOD_TEST_GPU=kgsl\n' | cx_write /etc/tod/gpu.env 644
  eq "gpu.env nel rootfs" "TOD_TEST_GPU=kgsl" "$(cat "$R/etc/tod/gpu.env")"
  eq "permessi" 644 "$(stat -c %a "$R/etc/tod/gpu.env")"
}

# --- Termux:X11 sharedUid e ponte GameNative ----------------------------------------
_fake_pm() { # pm finto: $1 = uid di Termux:X11 (vuoto = non installata), $2 = GameNative installato (1/0)
  cat >"$PREFIX/bin/pm" <<EOF
#!/bin/sh
case "\$*" in
  "list packages -U com.termux.x11") [ -n "$1" ] && echo "package:com.termux.x11 uid:$1" ;;
  "path com.termux.x11") [ -n "$1" ] && echo "package:/data/app/~~x/com.termux.x11/base.apk" ;;
  "path app.gamenative") [ "$2" = 1 ] && echo "package:/data/app/~~y/app.gamenative/base.apk" ;;
esac
exit 0
EOF
  chmod +x "$PREFIX/bin/pm"
  export TOD_PM="$PREFIX/bin/pm"
}

test_x11_variant_and_uid() {
  TERMUX_APP__APK_RELEASE=GITHUB
  eq "Termux da GitHub" shareduid "$(x11_variant)"
  TERMUX_APP__APK_RELEASE=F_DROID
  eq "Termux da F-Droid" regular "$(x11_variant)"
  unset TERMUX_APP__APK_RELEASE
  TERMUX_APK_RELEASE=GITHUB
  eq "Termux 0.118 (vecchio nome)" shareduid "$(x11_variant)"
  _fake_pm "$(id -u)" 0
  eq "stesso UID" shared "$(x11_uid_status)"
  _fake_pm 10999 0
  eq "UID diverso" separate "$(x11_uid_status)"
  _fake_pm "" 0
  eq "non installata" unknown "$(x11_uid_status)"
  fails x11_app_installed
}

test_x11_asset_selection() {
  if ! command -v jq >/dev/null; then echo "  (jq assente: salto)"; return 0; fi
  local rel='{"assets":[
    {"name":"termux-x11-nightly-1.03.01-0-all.deb","browser_download_url":"u/deb"},
    {"name":"termux-x11-universal-sharedUid-debug.apk","browser_download_url":"u/shared"},
    {"name":"termux-x11-universal-debug.apk","browser_download_url":"u/universal"},
    {"name":"termux-x11-arm64-v8a-debug.apk","browser_download_url":"u/arm64"}]}'
  eq "sharedUid" u/shared "$(jq -r "$(x11_asset_query shareduid)" <<<"$rel")"
  eq "normale: universal, mai sharedUid" u/universal "$(jq -r "$(x11_asset_query regular)" <<<"$rel")"
  rel='{"assets":[{"name":"termux-x11-universal-sharedUid-debug.apk","browser_download_url":"u/shared"},
                  {"name":"app-arm64-v8a-debug.apk","browser_download_url":"u/arm64"}]}'
  eq "normale: ripiego arm64" u/arm64 "$(jq -r "$(x11_asset_query regular)" <<<"$rel")"
}

test_x11_glamor_apk() { # 30 ottobre: la Termux:X11 di Termux On DeX (glamor) al posto della nightly, con ripiego
  if ! command -v jq >/dev/null; then echo "  (jq assente: salto)"; return 0; fi
  TOD_X11_APK="$WORK/x11g_$$.apk"; TOD_X11_DEB="$WORK/x11g_$$.deb"
  local TOD_ROOT="$WORK/x11g_radice_$$"   # mai la dist/ vera del repository
  mkdir -p "$TOD_ROOT"
  # la release finta in un file: x11_app_download ha una sua variabile locale "rel"
  echo '{"assets":[{"name":"termux-x11-nightly-1.03.01-0-all.deb","browser_download_url":"u/deb"},
    {"name":"termux-x11-universal-sharedUid-debug.apk","browser_download_url":"u/shared"},
    {"name":"termux-x11-universal-debug.apk","browser_download_url":"u/universal"}]}' >"$WORK/x11g_rel_$$"
  net_get() { cat "$WORK/x11g_rel_$$"; }
  net_download() { # url dest [sha]: "rotto" = la release con glamor non risponde
    echo "$1" >>"$WORK/x11g_dl_$$"
    if [[ $1 == *x11-glamor-* && -f $WORK/x11g_rotto_$$ ]]; then return 1; fi
    echo "da $1" >"$2"
  }
  x11_app_download shareduid
  eq "sharedUid: la nostra dalla release" 1 "$(conf_get X11_GLAMOR)"
  eq "si ricorda quale versione" "$X11_GLAMOR_VERSIONE" "$(conf_get X11_GLAMOR_INSTALLATA)"
  has "scaricata dalla release" "releases/download/x11-glamor-$X11_GLAMOR_VERSIONE/termux-x11-glamor-shareduid.apk" "$(cat "$TOD_X11_APK")"
  eq "niente pacchetto della nightly" no "$([[ -e $TOD_X11_DEB ]] && echo si || echo no)"
  touch "$WORK/x11g_rotto_$$"
  x11_app_download shareduid
  eq "release irraggiungibile: nightly ufficiale" "da u/shared" "$(cat "$TOD_X11_APK")"
  eq "release irraggiungibile: glamor spento" 0 "$(conf_get X11_GLAMOR)"
  rm -f "$WORK/x11g_rotto_$$"
  x11_app_download regular
  eq "variante normale: sempre l'ufficiale" "da u/universal" "$(cat "$TOD_X11_APK")"
  eq "variante normale: glamor spento" 0 "$(conf_get X11_GLAMOR)"
  conf_set X11_GLAMOR_APK 0
  x11_app_download shareduid
  eq "X11_GLAMOR_APK=0: l'ufficiale" "da u/shared" "$(cat "$TOD_X11_APK")"
  conf_set X11_GLAMOR_APK 1
  mkdir -p "$TOD_ROOT/dist"
  echo locale >"$TOD_ROOT/dist/termux-x11-glamor-shareduid.apk"
  X11_GLAMOR_SHA256=$(sha256sum "$TOD_ROOT/dist/termux-x11-glamor-shareduid.apk" | cut -d' ' -f1)
  : >"$WORK/x11g_dl_$$"
  x11_app_download shareduid
  eq "copia in dist/ con l'impronta giusta: niente rete" locale "$(cat "$TOD_X11_APK")"
  eq "copia in dist/: nessuno scaricamento" "" "$(cat "$WORK/x11g_dl_$$")"
}

test_self_update_da_github() { # 1° novembre: Termux On DeX si aggiorna anche dalla finestra Aggiornamenti
  have git || { echo "  (git assente: salto)"; return 0; }
  local o="$WORK/self_$$/origine" out
  local HOME="$WORK/self_$$/casa"
  local c="$HOME/.local/share/tod"
  g() { git -c user.name=prova -c user.email=prova@example.com "$@"; }
  mkdir -p "$o" "$HOME/.local/share"
  g -C "$o" init -q && g -C "$o" checkout -q -b v2
  echo uno >"$o/tod" && chmod 644 "$o/tod"   # anche senza permesso di esecuzione nel repository
  g -C "$o" add tod && g -C "$o" commit -q -m "primo"
  git clone -q --depth 1 -b v2 "file://$o" "$c"   # come install.sh
  local TOD_ROOT=$c
  eq "appena installato: niente di nuovo" "stato=aggiornato" "$(self_check)"
  echo due >"$o/tod" && g -C "$o" commit -qam "Barra: icona giusta"
  echo tre >>"$o/tod" && g -C "$o" commit -qam "Dischi in inglese"
  out=$(self_check)
  has "novità su GitHub" "stato=nuovo" "$out"
  has "contate" "novita=2" "$out"
  eq "con i titoli, la più nuova prima" "titolo=Dischi in inglese" "$(sed -n '/^titolo=/{p;q}' <<<"$out")"
  self_update
  eq "codice nuovo" "$(git -C "$o" rev-parse HEAD)" "$(git -C "$c" rev-parse HEAD)"
  eq "poi niente di nuovo" "stato=aggiornato" "$(self_check)"
  # la storia riscritta su GitHub (commit unico + push --force): git pull --ff-only falliva. Qui la copia
  # non è più "leggera" (il controllo ha scaricato tutti i commit): si riconosce dal posto
  g -C "$o" checkout -q --orphan nuovo && g -C "$o" commit -q -m "Termux On DeX v2" && g -C "$o" branch -q -M nuovo v2
  out=$(self_check)
  has "storia riscritta: c'è la novità" "stato=nuovo" "$out"
  hasnt "storia riscritta: novità non contate" "novita=" "$out"
  self_update
  eq "storia riscritta: aggiornato lo stesso" "$(git -C "$o" rev-parse HEAD)" "$(git -C "$c" rev-parse HEAD)"
  # mai sopra modifiche fatte a mano
  echo mio >>"$c/tod"
  g -C "$o" commit -q --allow-empty -m "altro"
  fails self_update
  eq "modifiche fatte a mano: restano" 1 "$(grep -c mio "$c/tod")"
  # una copia di sviluppo (clone completo altrove): solo avanti, mai allineata a forza
  local d="$WORK/self_$$/sviluppo"
  git clone -q -b v2 "file://$o" "$d"
  local TOD_ROOT=$d
  echo quattro >"$o/tod" && g -C "$o" commit -qam "avanti"
  self_update
  eq "sviluppo: avanti" "$(git -C "$o" rev-parse HEAD)" "$(git -C "$d" rev-parse HEAD)"
  g -C "$o" checkout -q --orphan nuovo2 && g -C "$o" commit -q -m "riscritta" && g -C "$o" branch -q -M nuovo2 v2
  fails self_update
  eq "sviluppo, storia riscritta: niente reset" "avanti" "$(git -C "$d" log -1 --format=%s)"
  # copia senza ramo su GitHub (quella di Pietro) o senza git: nessuna voce
  local TOD_ROOT="$WORK/self_$$/locale"
  mkdir -p "$TOD_ROOT" && git -C "$TOD_ROOT" init -q
  eq "copia senza ramo remoto: nessuna voce" "stato=nessuno" "$(self_check)"
  local TOD_ROOT="$WORK/self_$$/senza-git"
  mkdir -p "$TOD_ROOT"
  eq "senza git: nessuna voce" "stato=nessuno" "$(self_check)"
}

test_aggiornamenti_voce_tod() { # la voce "Termux On DeX" nella finestra Aggiornamenti e la sua installazione
  local f="$WORK/upd_$$" out
  mkdir -p "$f"
  printf '#!/bin/sh\necho "uscita di prova"\necho x11=nuova\n' >"$f/tod-ok"
  # gli errori di tod vanno su stderr, seguiti dal rimando al registro
  printf '#!/bin/sh\necho "✘ errore finto" >&2\necho "  Dettagli nel registro: /x/tod.log" >&2\nexit 1\n' >"$f/tod-ko"
  out=$(LANGUAGE=it HOME="$f" python3 - "$ROOT/share/tod-updates.py" "$f" <<'EOF'
import importlib.util as u, sys
s = u.spec_from_file_location("up", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
print(m.tod_item("stato=aggiornato"), m.tod_item("stato=nessuno"), m.tod_item("stato=errore"))
it = m.tod_item("stato=nuovo\nda=aaaaaaa\na=bbbbbbb\nnovita=2\ntitolo=Barra: icona giusta\ntitolo=Dischi in inglese\n")
print(it["app"], "|", it["desc"], "|", it["where"], it["from"], it["to"])
print(m.tod_item("stato=nuovo\nda=a\na=b\ntitolo=Termux On DeX v2")["desc"])
print(m.summary({"tod": [it], "termux": [{"name": "curl", "to": "1"}], "debian": []}))
m.TOD = sys.argv[2] + "/tod-ok"
ok, nota = m.install([it], lambda *a: None)
print(ok, nota)
m.TOD = sys.argv[2] + "/tod-ko"
print(m.install([it], lambda *a: None))
EOF
)
  eq "niente di nuovo: nessuna voce" "None None None" "$(sed -n 1p <<<"$out")"
  eq "la voce: nome, novità e la modifica più nuova" "Termux On DeX | 2 novità · Barra: icona giusta | tod aaaaaaa bbbbbbb" "$(sed -n 2p <<<"$out")"
  eq "storia riscritta: nuova versione" "Nuova versione · Termux On DeX v2" "$(sed -n 3p <<<"$out")"
  eq "nel riassunto per prima" "Termux On DeX e un altro aggiornamento" "$(sed -n 4p <<<"$out")"
  has "installata dalla finestra: cosa cambia e quando" "True Termux On DeX è aggiornato: barra, Start e finestre cambiano al prossimo avvio" "$(sed -n 5p <<<"$out")"
  has "Termux:X11 nuova: da Termux, non da qui" "installala da Termux con tod update" "$(sed -n 5p <<<"$out")"
  eq "errore: l'ultima riga di tod" "(False, 'errore finto')" "$(sed -n 6p <<<"$out")"
  has "la finestra chiama tod" '"_self_update"' "$(cat "$ROOT/share/tod-updates.py")"
}

test_x11_glamor_nuova_versione() { # la Termux:X11 nuova si propone solo da tod update (installarla chiude Termux)
  conf_set X11_GLAMOR 1
  if x11_glamor_da_aggiornare; then echo "  ✘ installazione di prima del 1° novembre (versione 1): niente da fare"; return 1; fi
  local X11_GLAMOR_VERSIONE=2
  x11_glamor_da_aggiornare || { echo "  ✘ versione 2 uscita: da aggiornare"; return 1; }
  usb_on() { return 1; }
  desktop_install_entries() { :; }
  eq "dopo il codice nuovo: avviso per la finestra" "x11=nuova" "$(self_after)"
  conf_set X11_GLAMOR_INSTALLATA 2
  eq "già la nuova: niente" "" "$(self_after)"
  conf_set X11_GLAMOR 0
  conf_set X11_GLAMOR_INSTALLATA 1
  eq "con la Termux:X11 ufficiale: mai" "" "$(self_after)"
}

test_install_sh_full_upgrade_first() { # 31 ottobre: "CANNOT LINK EXECUTABLE" su un Termux appena installato
  local d="$WORK/inst_$$" b="$WORK/inst_$$/bin"
  mkdir -p "$d/com.termux/files/usr/bin" "$b" "$d/script"
  cp "$ROOT/install.sh" "$d/script/"   # lontano dal repository: niente "copia locale"
  printf '#!/bin/sh\necho "apt-get $*" >>%s/log\n' "$d" >"$b/apt-get"
  printf '#!/bin/sh\nexit 0\n' >"$b/dpkg"
  printf '#!/bin/sh\necho "tod $*" >>%s/log\n' "$d" >"$d/tod-finto"
  printf '#!/bin/sh\nfor a; do dest=$a; done\nmkdir -p "$dest" && cp %s/tod-finto "$dest/tod"\n' "$d" >"$b/git"
  printf '#!/bin/sh\necho "pkg $*" >>%s/log\n' "$d" >"$b/pkg"
  printf '#!/bin/sh\nexit 0\n' >"$b/apt-cache"   # gli elenchi dei pacchetti ci sono
  chmod +x "$b"/* "$d/tod-finto"
  PATH="$b:$PATH" PREFIX="$d/com.termux/files/usr" TOD_HOME="$d/tod" bash "$d/script/install.sh" --yes </dev/null >/dev/null 2>&1
  eq "elenchi da pkg (sceglie il mirror), aggiornamento completo, poi i pacchetti e tod" \
    "$(printf '%s\n' 'pkg update' full-upgrade 'install git dialog jq curl ca-certificates' 'tod install --yes')" \
    "$(sed -e 's/^apt-get -y -q -o [^ ]* -o [^ ]* //' "$d/log")"
  # 1° novembre (S20+): nessun server raggiungibile, il DNS del telefono li manda a 127.0.0.1
  : >"$d/log"
  printf '#!/bin/sh\nexit 100\n' >"$b/apt-cache"
  printf '#!/bin/sh\nprintf 127.0.0.1\n' >"$b/curl"
  chmod +x "$b"/*
  local out rc=0
  out=$(PATH="$b:$PATH" PREFIX="$d/com.termux/files/usr" TOD_HOME="$d/tod" bash "$d/script/install.sh" --yes </dev/null 2>&1) || rc=$?
  eq "senza elenchi si ferma" 1 "$rc"
  hasnt "senza elenchi: niente install alla cieca" "install git" "$(cat "$d/log")"
  has "il perché: il DNS del telefono" "DNS privato" "$out"
  printf '#!/bin/sh\nprintf 104.16.1.1\n' >"$b/curl"
  out=$(PATH="$b:$PATH" PREFIX="$d/com.termux/files/usr" TOD_HOME="$d/tod" bash "$d/script/install.sh" --yes </dev/null 2>&1) || true
  has "rete giù: controllare la connessione" "Controlla la connessione" "$out"
}

test_pkg_refresh_altro_mirror() { # un server dei pacchetti irraggiungibile: pkg di Termux sceglie un altro mirror
  apt_run() { echo "apt $*" >>"$HOME/apt"; [[ $* != *--error-on=any* ]]; }
  printf '#!/bin/sh\necho "pkg $*" >>"$HOME/pkg"\n' >"$PREFIX/bin/pkg"
  chmod +x "$PREFIX/bin/pkg"
  PATH="$PREFIX/bin:$PATH"
  pkg_refresh
  eq "server giù: pkg update" "pkg update" "$(cat "$HOME/pkg")"
  eq "poi gli elenchi dal mirror nuovo" 2 "$(grep -c update "$HOME/apt")"
  rm -f "$HOME/pkg" "$HOME/apt"
  apt_run() { echo "apt $*" >>"$HOME/apt"; }
  pkg_refresh
  eq "tutto a posto: niente pkg" "" "$(cat "$HOME/pkg" 2>/dev/null)"
  eq "una volta sola" 1 "$(grep -c update "$HOME/apt")"
}

test_games_bridge() {
  _fake_pm "" 1
  printf '#!/bin/sh\necho "$@" >>"$HOME/am_calls"\n' >"$PREFIX/bin/am"
  chmod +x "$PREFIX/bin/am"
  PATH="$PREFIX/bin:$PATH"
  game_add 1091500 "Cyberpunk 2077" >/dev/null
  local f="$HOME/.local/share/applications/tod-game-1091500.desktop"
  has "voce nel menu" "Exec=$PREFIX/bin/tod game run 1091500" "$(cat "$f")"
  has "categoria" "Categories=Game;" "$(cat "$f")"
  has "elenco" "Cyberpunk 2077" "$(game_list)"
  game_run 1091500
  eq "intent di GameNative" "start -n app.gamenative/app.gamenative.MainActivity -a app.gamenative.LAUNCH_GAME --ei app_id 1091500" \
    "$(cat "$HOME/am_calls")"
  fails game_add "cyberpunk"
  fails game_run 12ab
  games_entries
  has "voce GameNative" "Exec=$PREFIX/bin/tod game open" "$(cat "$HOME/.local/share/applications/tod-gamenative.desktop")"
  game_remove 1091500 >/dev/null
  eq "rimosso" no "$([[ -e $f ]] && echo si || echo no)"
  _fake_pm "" 0
  fails game_run 1091500
  games_entries
  eq "senza GameNative niente voce" no "$([[ -e $HOME/.local/share/applications/tod-gamenative.desktop ]] && echo si || echo no)"
}

# --- signal 9: associazione ADB (il caso reale del Galaxy S26) -----------------------
test_phantom_input_parsing() {
  eq "porta semplice" 41235 "$(ph_port_from 41235)"
  eq "indirizzo completo" 41235 "$(ph_port_from "192.168.1.5:41235")"
  eq "con spazi" 41235 "$(ph_port_from " 41235 ")"
  fails ph_port_from "abc"
  fails ph_port_from ""
  eq "codice" 123456 "$(ph_code_from 123456)"
  eq "codice con spazio" 123456 "$(ph_code_from "123 456")"
  fails ph_code_from 12345
}

_fake_adb() { # adb finto: l'associazione riesce solo se $HOME/pair_ok esiste
  cat >"$PREFIX/bin/adb" <<'EOF'
#!/bin/bash
echo "adb $*" >>"$HOME/adb_calls"
case "$1" in
  start-server) exit 0 ;;
  devices) echo "List of devices attached" ;;
  mdns) echo "List of discovered mdns services" ;;
  pair)
    if [ -f "$HOME/pair_ok" ]; then touch "$HOME/paired"; echo "Successfully paired to $2 [guid=adb-R5CX-abc]"
    else echo "Failed: Wrong password or connection was dropped."; fi
    exit 0 ;;   # come il vero adb: esce con 0 anche quando fallisce
  connect)
    if [ -f "$HOME/paired" ] && [ "$2" = "127.0.0.1:37999" ]; then echo "connected to $2"
    else echo "failed to authenticate to $2"; fi ;;
esac
EOF
  cat >"$PREFIX/bin/nmap" <<'EOF'
#!/bin/sh
printf 'Host: 127.0.0.1 ()\tPorts: 37999/open/tcp//unknown///, 41235/open/tcp//unknown///\n'
EOF
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/am"
  chmod +x "$PREFIX/bin/adb" "$PREFIX/bin/nmap" "$PREFIX/bin/am"
  PATH="$PREFIX/bin:$PATH"
  # risposte dell'utente, una per chiamata (le chiamate avvengono in subshell: contatore su file)
  ui_input() {
    local n
    n=$(cat "$HOME/ui_n" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" >"$HOME/ui_n"
    sed -n "${n}p" "$HOME/ui_answers"
  }
}

test_phantom_pair_failure_is_not_success() {
  _fake_adb
  printf '%s\n' "192.168.1.5:41235" "123456" 41235 123456 41235 123456 >"$HOME/ui_answers"
  local rc=0
  adb_connect_local >"$HOME/out" 2>&1 || rc=$?
  eq "si arrende dopo 3 tentativi" 1 "$rc"
  hasnt "nessun tentativo di connessione dopo un'associazione fallita" "connect 127.0.0.1:41235" \
    "$(grep -v '^adb connect 127.0.0.1:37999' "$HOME/adb_calls" || true)"
  has "spiega perché" "popup" "$(cat "$HOME/out")"
  eq "3 associazioni tentate" 3 "$(grep -c '^adb pair' "$HOME/adb_calls")"
}

test_phantom_pair_success_finds_connect_port() {
  _fake_adb
  touch "$HOME/pair_ok"
  printf '%s\n' "192.168.1.5:41235" "123 456" >"$HOME/ui_answers"
  adb_connect_local >"$HOME/out" 2>&1
  eq "porta di connessione trovata da sola" 127.0.0.1:37999 "$ADB_SERIAL"
  eq "all'utente chiesti solo porta e codice del popup" 2 "$(cat "$HOME/ui_n")"
  has "associazione con l'indirizzo ripulito" "adb pair 127.0.0.1:41235 123456" "$(cat "$HOME/adb_calls")"
}

# --- interfaccia grafica dell'installazione -------------------------------------------
_fake_dialog() { # dialog finto: registra quello che riceve la barra, risponde ai popup da file
  cat >"$PREFIX/bin/dialog" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case $a in
    --gauge) cat >>"$HOME/gauge_feed"; exit 0 ;;
    --yesno)
      n=$(cat "$HOME/yesno_n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$HOME/yesno_n"
      echo yesno >>"$HOME/dialog_calls"
      rc=$(sed -n "${n}p" "$HOME/yesno_rcs" 2>/dev/null); exit "${rc:-0}" ;;
    --textbox | --infobox | --msgbox) echo "$a" >>"$HOME/dialog_calls"; exit 0 ;;
  esac
done
exit 0
EOF
  chmod +x "$PREFIX/bin/dialog"
  PATH="$PREFIX/bin:$PATH"
  TUI_TTY=/dev/null TUI_ON=1 TUI_BACKTITLE=test
  export TOD_PROGRESS_FILE="$TMPDIR/tod-progress"
  : >"$TOD_PROGRESS_FILE"
}

test_tui_parse_status() {
  export TOD_PROGRESS_FILE="$TMPDIR/p"
  : >"$TOD_PROGRESS_FILE"
  eq "vuoto" "|" "$(tui_parse_status)"
  echo "dlstatus:3:12.5:Retrieving file 3 of 25" >>"$TOD_PROGRESS_FILE"
  eq "download (0-30%)" "3|Download dei pacchetti: 3 di 25" "$(tui_parse_status)"
  echo "pmstatus:xfce4-panel:50.0:Installing xfce4-panel" >>"$TOD_PROGRESS_FILE"
  eq "installazione (30-100%)" "65|Installazione: xfce4-panel" "$(tui_parse_status)"
  echo "tod:40:Test del profilo GPU kgsl" >>"$TOD_PROGRESS_FILE"
  eq "nota con percentuale" "40|Test del profilo GPU kgsl" "$(tui_parse_status)"
  echo "tod:-:Download: mesa.deb" >>"$TOD_PROGRESS_FILE"
  eq "nota senza percentuale" "|Download: mesa.deb" "$(tui_parse_status)"
  echo "pmerror:libfoo:10:dpkg error" >>"$TOD_PROGRESS_FILE"
  has "errore di dpkg" "Errore nel pacchetto libfoo" "$(tui_parse_status)"
}

test_tui_overall_and_render() {
  tui_register a "Alfa" 10
  tui_register b "Beta" 30
  tui_register c "Gamma" 60
  TUI_STATE[a]=done
  TUI_STATE[b]=run
  eq "avanzamento totale pesato" 25 "$(tui_overall b 50)"
  local r
  r=$(tui_render "dettaglio")
  has "intestazione" "Passo 2 di 3" "$r"
  has "passo fatto" '\Z2✔\Zn Alfa' "$r"
  has "passo in corso" '\Z4▶\Zn \ZbBeta\ZB' "$r"
  has "passo in attesa" '· Gamma' "$r"
  has "dettaglio" "dettaglio" "$r"
}

test_tui_run_progress() {
  _fake_dialog
  tui_register a "Primo" 50
  tui_register b "Secondo" 50
  TUI_STATE[a]=done
  step_b() { for i in 20 60 90; do printf 'pmstatus:pkg%s:%s.0:Installing\n' "$i" "$i" >>"$TOD_PROGRESS_FILE"; sleep 0.4; done; }
  tui_run b step_b
  tui_gauge_close
  eq "passo completato" done "${TUI_STATE[b]}"
  step_done b
  local feed pcts
  feed=$(cat "$HOME/gauge_feed")
  has "pacchetto mostrato" "Installazione: pkg60" "$feed"
  pcts=$(awk 'prev == "XXX" && /^[0-9]+$/ {print} {prev = $0}' "$HOME/gauge_feed")
  eq "arriva al 100%" 100 "$(tail -n 1 <<<"$pcts")"
  eq "la barra non torna mai indietro" "$(sort -n <<<"$pcts")" "$pcts"
}

test_tui_close_with_surviving_process() {
  _fake_dialog
  tui_register d "Passo con un demone" 100
  # come il server X dei test GPU: un processo che sopravvive al passo
  with_daemon() { sleep 47 & echo $! >"$HOME/daemon_pid"; }
  tui_run d with_daemon
  local t0=$SECONDS
  tui_gauge_close
  eq "la barra si chiude subito (il passo non ha ereditato la FIFO)" yes "$( (( SECONDS - t0 <= 2 )) && echo yes || echo no)"
  kill "$(cat "$HOME/daemon_pid")" 2>/dev/null || true
  # e anche se un processo la tiene davvero aperta, l'attesa è limitata
  tui_gauge_open
  sleep 43 &
  local holder=$!
  t0=$SECONDS
  tui_gauge_close
  eq "attesa limitata" yes "$( (( SECONDS - t0 <= 4 )) && echo yes || echo no)"
  kill "$holder" 2>/dev/null || true
  eq "intestazione finale" "Completato" "$(tui_render "" | sed -n 1p | cut -d' ' -f1)"
}

test_tui_run_retry_and_log() {
  _fake_dialog
  printf '%s\n' 3 0 >"$HOME/yesno_rcs"   # prima "Mostra log", poi "Riprova"
  tui_register x "Passo instabile" 100
  flaky() { if [[ -f $HOME/second ]]; then return 0; fi; touch "$HOME/second"; echo "errore finto"; return 5; }
  tui_run x flaky
  tui_gauge_close
  eq "riuscito al secondo tentativo" done "${TUI_STATE[x]}"
  eq "popup: log mostrato e poi riprova" $'yesno\n--textbox\nyesno' "$(cat "$HOME/dialog_calls")"
}

test_tui_run_quit() {
  _fake_dialog
  printf '%s\n' 1 >"$HOME/yesno_rcs"   # "Esci"
  tui_register y "Passo rotto" 100
  broken() { return 2; }
  local rc=0
  ( tui_run y broken ) >/dev/null 2>&1 || rc=$?
  eq "uscita con errore" 1 "$rc"
  fails step_done y
}

test_apt_run_status_fd() {
  cat >"$PREFIX/bin/apt-get" <<'EOF'
#!/bin/bash
for a; do if [ "$a" = "APT::Status-Fd=3" ]; then echo "pmstatus:foo:42.0:Installing foo" >&3; fi; done
echo "apt-get $*" >>"$HOME/apt_args"
EOF
  chmod +x "$PREFIX/bin/apt-get"
  PATH="$PREFIX/bin:$PATH"
  export TOD_PROGRESS_FILE="$TMPDIR/p"
  : >"$TOD_PROGRESS_FILE"
  apt_run -y install foo
  has "Status-Fd attivo" "-o APT::Status-Fd=3" "$(cat "$HOME/apt_args")"
  eq "riga di stato scritta" "pmstatus:foo:42.0:Installing foo" "$(cat "$TOD_PROGRESS_FILE")"
  unset TOD_PROGRESS_FILE
  : >"$HOME/apt_args"
  apt_run -y install foo
  hasnt "senza interfaccia niente Status-Fd" "Status-Fd" "$(cat "$HOME/apt_args")"
}

# --- casi reali dal log del Galaxy S26 Ultra ---------------------------------------
test_audio_restarts_broken_daemon() {
  _fake_pulse
  local st="$HOME/pulse_state"
  touch "$st/running" "$st/broken"
  printf '0\tmodule-null-sink\t\n' >"$st/modules"
  audio_start
  has "demone riavviato" "pulseaudio --kill" "$(cat "$st/calls")"
  eq "uscita vera dopo il riavvio" AAudio_sink "$(cat "$st/default")"
  has "motivo nel log" "nessuna uscita vera, riavvio PulseAudio" "$(cat "$TOD_LOG")"
}

test_audio_status_unreachable() {
  _fake_pulse
  touch "$HOME/pulse_state/running"
  audio_pactl() { return 1; }   # PulseAudio vivo ma non risponde (es. da dentro il proot)
  local out
  out=$(audio_status 2>&1)
  hasnt "niente Errore inatteso" "Errore inatteso" "$out"
  has "flussi a zero" "0" "$out"
}

test_audio_test_reaches_container() {
  _fake_proot
  # pacat finto: conta i byte ricevuti (da file o da stdin)
  cat >"$PREFIX/bin/pacat" <<'EOF'
#!/bin/bash
f=/dev/stdin
for a in "$@"; do case $a in -*) ;; *) f=$a ;; esac; done
if [[ $f == /dev/stdin ]]; then wc -c <"$f" >"$HOME/pacat_native"; else wc -c <"$f" >"$HOME/pacat_cx"; fi
EOF
  chmod +x "$PREFIX/bin/pacat"
  audio_start() { :; }
  audio_test >/dev/null 2>&1
  eq "nota nativa" 16000 "$(cat "$HOME/pacat_native" 2>/dev/null)"
  eq "nota arrivata nel container" 16000 "$(cat "$HOME/pacat_cx" 2>/dev/null)"
  has "esito nel log" "nativo=ok container=ok" "$(cat "$TOD_LOG")"
}

test_cx_rootfs_proot_distro_5() {
  local base="$PREFIX/var/lib/proot-distro"
  fails cx_rootfs
  mkdir -p "$base/installed-rootfs/debian/etc"
  eq "proot-distro 4" "$base/installed-rootfs/debian" "$(cx_rootfs)"
  mkdir -p "$base/containers/debian/rootfs/etc"
  eq "proot-distro 5 ha la precedenza" "$base/containers/debian/rootfs" "$(cx_rootfs)"
  rm -rf "$base/installed-rootfs"
  eq "solo proot-distro 5" "$base/containers/debian/rootfs" "$(cx_rootfs)"
  # con la 5 niente --bind della home (è già montata): niente avvisi a ogni avvio di un'app
  printf '#!/bin/sh\necho "$@" >>"$HOME/pd_calls"\n' >"$PREFIX/bin/proot-distro"
  chmod +x "$PREFIX/bin/proot-distro"
  PATH="$PREFIX/bin:$PATH"
  cx_run --raw true
  hasnt "nessun bind doppio con la 5" "--bind" "$(cat "$HOME/pd_calls")"
}

test_x11_server_restart_retry() {
  command -v python3 >/dev/null || { echo "  (python3 assente: salto)"; return 0; }
  # il primo avvio non crea il socket (come il 2° avvio ravvicinato sul telefono), il secondo sì
  cat >"$PREFIX/bin/termux-x11" <<'EOF'
#!/bin/bash
n=$(cat "$HOME/x11_n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$HOME/x11_n"
if [ "$n" -eq 1 ]; then echo "errore finto del server"; exit 1; fi
exec -a app_process python3 -c '
import os, socket, time
d = os.environ["TMPDIR"] + "/.X11-unix"; os.makedirs(d, exist_ok=True)
s = socket.socket(socket.AF_UNIX); s.bind(d + "/X0"); s.listen(1); time.sleep(30)' com.termux.x11.CmdEntryPoint "$@"
EOF
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/am"
  chmod +x "$PREFIX/bin/termux-x11" "$PREFIX/bin/am"
  PATH="$PREFIX/bin:$PATH"
  TOD_X11_WAIT=2 TOD_X11_RETRY_PAUSE=0 TOD_X11_SETTLE=0
  eq "riesce al secondo tentativo" ok "$(x11_with_server sh -c 'echo ok')"
  eq "due avvii" 2 "$(cat "$HOME/x11_n")"
  has "il motivo finisce nel log" "errore finto del server" "$(cat "$TOD_LOG")"
  fails x11_running
}

test_gpu_setup_lfdevs_x11_failure() {
  _gpu_mocks 'zink-turnip|ok|zink Vulkan 1.4(Adreno (TM) 840 (MESA_TURNIP))|' 'kgsl|ok|FD840|'
  # come sul telefono: il primo server X parte, il secondo (dopo i driver sperimentali) no
  x11_with_server() {
    local n
    n=$(cat "$HOME/xws_n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$HOME/xws_n"
    if (( n >= 2 )); then return 1; fi
    "$@"
  }
  gpu_setup >/dev/null 2>&1
  eq "resta sui driver ufficiali" official "$(gpu_stack)"
  eq "profilo dal test vero" zink-turnip "$(conf_get GPU_PROFILE)"
  has "risultati ufficiali ripristinati" "MESA_TURNIP" "$(cat "$TOD_GPU_PROBE")"
  has "spiegato nel log" "server X non si avvia" "$(cat "$TOD_LOG")"
}

test_x11_server_senza_lock() { # server della sessione vivo ma senza file di lock (dopo un arresto con l'app aperta)
  local d="$WORK/srv_$$"
  mkdir -p "$TMPDIR/.X11-unix" "$d"
  rm -f "$TMPDIR/.X0-lock"
  : >"$d/com.termux.x11"
  : >"$d/:0"
  # un processo con la stessa riga di comando del server vero ("termux-x11 com.termux.x11 :0 ...")
  (cd "$d" && exec -a termux-x11 tail com.termux.x11 :0 -f -s 1 >/dev/null 2>&1) &
  local srv=$!
  sleep 0.3
  rm -f "$(x11_sock)"
  python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$(x11_sock)"
  has "riconosciuto dalla riga di comando" "$srv" "$(x11_server_pids)"
  eq "server acceso" si "$(x11_running && echo si || echo no)"
  kill "$srv" 2>/dev/null || true
}

test_x11_lock_file_detection() {
  TOD_X11_SETTLE=0
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/am"
  chmod +x "$PREFIX/bin/am"
  PATH="$PREFIX/bin:$PATH"
  mkdir -p "$TMPDIR/.X11-unix"
  # server rimasto vivo, con un nome che i vecchi controlli non riconoscevano
  bash -c 'exec -a termux-x11 sleep 41' &
  local srv=$!
  sleep 0.2
  printf '%10d\n' "$srv" >"$TMPDIR/.X0-lock"
  touch "$(x11_sock)"
  has "riconosciuto dal file di lock" "$srv" "$(x11_server_pids)"
  x11_cleanup_stale
  eq "socket di un server vivo non cancellato" si "$([[ -e $(x11_sock) ]] && echo si || echo no)"
  x11_kill
  eq "server chiuso" no "$(kill -0 "$srv" 2>/dev/null && echo si || echo no)"
  eq "lock rimosso dopo la chiusura" no "$([[ -e $TMPDIR/.X0-lock ]] && echo si || echo no)"
  # PID riciclato da un processo qualunque: non è un server X, non va toccato
  sleep 42 &
  local other=$!
  printf '%10d\n' "$other" >"$TMPDIR/.X0-lock"
  fails x11_lock_pid
  kill "$other" 2>/dev/null || true
}

test_session_start_retry_logs_server_error() {
  command -v python3 >/dev/null || { echo "  (python3 assente: salto)"; return 0; }
  cat >"$PREFIX/bin/termux-x11" <<'EOF'
#!/bin/bash
n=$(cat "$HOME/x11_n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$HOME/x11_n"
if [ "$n" -eq 1 ]; then echo "Fatal server error: Server is already active for display 0"; exit 1; fi
exec -a app_process python3 -c '
import os, socket, time
d = os.environ["TMPDIR"] + "/.X11-unix"; os.makedirs(d, exist_ok=True)
s = socket.socket(socket.AF_UNIX); s.bind(d + "/X0"); s.listen(1); time.sleep(30)' com.termux.x11.CmdEntryPoint "$@"
EOF
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/am"
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/termux-x11-preference"
  chmod +x "$PREFIX/bin/termux-x11" "$PREFIX/bin/am" "$PREFIX/bin/termux-x11-preference"
  PATH="$PREFIX/bin:$PATH"
  TOD_X11_WAIT=2 TOD_X11_SETTLE=0
  conf_set INSTALLED 1
  session_start >/dev/null 2>&1
  x11_running
  has "errore del server nel log" "Server is already active for display 0" "$(cat "$TOD_LOG")"
  session_stop >/dev/null 2>&1
  fails x11_running
}

# --- lingua, uscita dal menu, disinstallazione ----------------------------------

_fake_xfconf() { # xfconf-query finto che conserva le proprietà (anche gli array) su file
  cat >"$PREFIX/bin/xfconf-query" <<'EOF'
#!/bin/bash
c="" p="" list=0 arr=0 reset=0; vals=()
while (($#)); do
  case $1 in
    -c) c=$2; shift ;; -p) p=$2; shift ;; -l) list=1 ;; -a) arr=1 ;; -r) reset=1 ;; -t) shift ;; -s) vals+=("$2"); shift ;;
  esac
  shift
done
d="$HOME/xfconf/$c"; mkdir -p "$d"
f="$d/$(printf '%s' "$p" | base64 -w0 | tr '/+' '_-')"
if ((list)); then for x in "$d"/*.p; do [[ -f $x ]] && cat "$x"; done | sort; exit 0; fi
if ((reset)); then
  for x in "$d"/*.p; do
    [[ -f $x ]] || continue
    case $(cat "$x") in "$p" | "$p"/*) rm -f "${x%.p}".* ;; esac
  done
  exit 0
fi
if ((${#vals[@]})); then
  printf '%s\n' "$p" >"$f.p"; printf '%s\n' "${vals[@]}" >"$f.v"
  if ((arr || ${#vals[@]} > 1)); then touch "$f.a"; else rm -f "$f.a"; fi
  exit 0
fi
[[ -f $f.v ]] || exit 1
if [[ -f $f.a ]]; then printf 'Value is an array with %s items:\n\n' "$(wc -l <"$f.v")"; fi
cat "$f.v"
EOF
  printf '#!/bin/sh\necho "$*" >>"$HOME/panel_calls"\n' >"$PREFIX/bin/xfce4-panel"
  chmod +x "$PREFIX/bin/xfconf-query" "$PREFIX/bin/xfce4-panel"
  PATH="$PREFIX/bin:$PATH"
}

test_pannelli_avvisano_la_barra() { # volume/notifiche cambiati: SIGUSR2 alla nostra barra, mai xfce4-panel (errore D-Bus)
  command -v python3 >/dev/null || return 0
  local d="$WORK/pav_$$"
  mkdir -p "$d/bin" "$d/finta"
  printf '#!/bin/sh\necho "$*" >>"%s/chiamate"\n' "$d" >"$d/bin/xfce4-panel"
  chmod +x "$d/bin/xfce4-panel"
  # una "barra" finta: si chiama tod-barra.py e scrive quando riceve SIGUSR2
  printf '%s\n' 'import signal, sys, time' \
    'signal.signal(signal.SIGUSR2, lambda *a: open(sys.argv[1] + "/segnale", "w").write("ok"))' \
    'open(sys.argv[1] + "/pronta", "w").write("ok")' 'time.sleep(20)' >"$d/finta/tod-barra.py"
  python3 "$d/finta/tod-barra.py" "$d" &
  local pid=$! i
  for i in $(seq 50); do if [[ -f $d/pronta ]]; then break; fi; sleep 0.1; done
  echo "$pid" >"$d/tod-barra.pid"
  # solo la funzione, senza caricare GTK: il file si legge e si esegue aggiorna_barra
  TMPDIR="$d" PATH="$d/bin:$PATH" python3 -c '
import os, re, signal, subprocess, sys
src = open(sys.argv[1]).read()
f = re.search(r"^def aggiorna_barra\(\):.*?(?=^\S)", src, re.S | re.M).group(0)
exec(f)
aggiorna_barra()' "$ROOT/share/tod-pannelli.py"
  for i in $(seq 30); do if [[ -f $d/segnale ]]; then break; fi; sleep 0.1; done
  kill "$pid" 2>/dev/null || true
  eq "la barra riceve il segnale" ok "$(cat "$d/segnale" 2>/dev/null)"
  eq "xfce4-panel mai chiamato" 0 "$(cat "$d/chiamate" 2>/dev/null | wc -l)"
}

test_pannelli_batteria_memoria() { # durata della batteria e memoria raggruppata per app (senza GTK)
  command -v python3 >/dev/null || return 0
  local out
  out=$(python3 - "$ROOT/share/tod-pannelli.py" <<'PYEOF'
import os, re, sys, tempfile
src = open(sys.argv[1]).read()
ITALIAN = True
def TT(it, en): return it
for nome in ("in_carica", "corrente_ua", "stima_ore", "durata", "in_proot", "raggruppa", "banda", "qualita"):
    exec(re.search(rf"^def {nome}\(.*?(?=^\S)", src, re.S | re.M).group(0))
# scarica: 2 645 000 µAh a -738 281 µA medi → 3,58 h
b = {"percentage": 52, "status": "DISCHARGING", "plugged": "UNPLUGGED", "current_average": -738281, "charge_counter": 2645000}
print("scarica", durata(stima_ore(b)))
# in carica, in mA e mAh: piena (100%) da 50% con 2000 mAh a 1000 mA → 2 h
print("carica", durata(stima_ore({"percentage": 50, "status": "CHARGING", "current_average": 1000, "charge_counter": 2000})))
print("senza corrente", stima_ore({"percentage": 50, "status": "DISCHARGING", "current_average": 0, "charge_counter": 1}))
class Info:
    def __init__(s, i, n): s.i, s.n = i, n
    def get_id(s): return s.i
    def get_display_name(s): return s.n
class Cat:
    def cerca(s, ist, cl): return Info("editor.desktop", "Editor") if cl == "Editor" else None
# 10 = finestra dell'editor (Electron); 11 e 12 suoi figli (renderer, terminale); 20 = X; 30 = finestra di Mousepad
procs = {10: (1, 300), 11: (10, 500), 12: (11, 200), 20: (1, 60), 30: (1, 25)}
app, sistema = raggruppa(procs, [(0x1, 10, "editor", "Editor"), (0x2, 10, "editor", "Editor"), (0x3, 30, "mousepad", "Mousepad")], Cat())
print("app", [(a["nome"], a["kb"], len(a["finestre"])) for a in app], "sistema", sistema)
# Mousepad aperto con proot, l'editor senza
app, _ = raggruppa(procs, [(0x1, 10, "editor", "Editor"), (0x3, 30, "mousepad", "Mousepad")], Cat(), lambda pid: pid == 30)
print("proot", sorted((a["nome"], a["proot"]) for a in app))
# /proc finto: 30 seguito da proot (40), 10 senza tracciatore, 50 seguito da un debugger
d = tempfile.mkdtemp()
for pid, tracer, argv0 in ((30, 40, None), (40, 0, b"/data/data/com.termux/files/usr/bin/proot"), (10, 0, None),
                           (50, 60, None), (60, 0, b"/usr/bin/gdb")):
    os.makedirs(f"{d}/{pid}")
    open(f"{d}/{pid}/status", "w").write(f"Name:\tx\nTracerPid:\t{tracer}\n")
    if argv0:
        open(f"{d}/{pid}/cmdline", "wb").write(argv0 + b"\0-r\0/rootfs\0")
print("in_proot", in_proot(30, d), in_proot(10, d), in_proot(50, d), in_proot(99, d))
print("banda", banda(2412), banda(5200), banda(6115))
print("qualita", qualita(-50)[1], qualita(-80)[1])
PYEOF
)
  has "durata in scarica" "scarica 3 h 35 min" "$out"
  has "durata in carica (mA e mAh)" "carica 2 h 0 min" "$out"
  has "senza corrente: nessuna stima" "senza corrente None" "$out"
  has "l'editor con i suoi processi, due finestre" "('Editor', 1000, 2)" "$out"
  has "Mousepad a parte" "('Mousepad', 25, 1)" "$out"
  has "il resto è il sistema" "sistema 60" "$out"
  has "segno proot solo per l'app in proot" "proot [('Editor', False), ('Mousepad', True)]" "$out"
  has "proot riconosciuto dal tracciatore" "in_proot True False False False" "$out"
  has "bande" "banda 2,4 GHz 5 GHz 6 GHz" "$out"
  has "segnale" "qualita excellent weak" "$out"
  local ps
  ps=$(cat "$ROOT/share/tod-phone-status.py")
  has "il clic apre i nostri pannelli" '"tod-pannello")' "$ps"
  has "clic sull'icona della batteria" '{PANNELLO} batteria' "$ps"
  has "clic sull'icona della rete" '{PANNELLO} rete' "$ps"
}

test_app_cambiate_una_volta() { # 230 app del telefono tolte insieme (S20+): Start e barra rifanno l'elenco una volta
  has "Start: attesa prima di ricostruire" "_ricarica_dopo())" "$(cat "$ROOT/share/tod-start.py")"
  hasnt "Start: mai a ogni cambio" 'connect("changed", lambda *a: self.reload())' "$(cat "$ROOT/share/tod-start.py")"
  has "barra: attesa anche lei" "_ricarica_dopo())" "$(cat "$ROOT/share/tod-barra.py")"
  # sessione: barra, Start e pannelli prima di aspetto e cartelle
  local h
  h=$(sed -n '/^session_hook() {/,/^}/p' "$ROOT/lib/session.sh")
  eq "barra prima dell'aspetto" 1 "$(( $(grep -n look_barra_avvia <<<"$h" | cut -d: -f1) < $(grep -n look_session_apply <<<"$h" | cut -d: -f1) ))"
}

test_barra_nostra() { # la barra di DeX OS al posto di xfce4-panel: la sessione parte senza (niente attesa di 16 s)
  _fake_xfconf
  command -v python3 >/dev/null && python3 -m py_compile "$ROOT/share/tod-barra.py" || { echo "tod-barra.py non compila"; return 1; }
  look_barra_sessione
  eq "sessione: 4 programmi" 4 "$(xfconf-query -c xfce4-session -p /sessions/Failsafe/Count)"
  local tutti="" i
  for i in 0 1 2 3; do tutti+="$(xfconf-query -c xfce4-session -p /sessions/Failsafe/Client${i}_Command | tail -n +1 | tr '\n' ' ')"; done
  eq "niente xfce4-panel nella sessione" 0 "$(grep -c xfce4-panel <<<"$tutti")"
  has "la scrivania c'è" xfdesktop "$tutti"
  has "Thunar in sottofondo" "--daemon" "$tutti"
  # la prima volta la barra fissa le app installate, non legge più la barra di XFCE
  hasnt "niente docklike" "docklike" "$(cat "$ROOT/share/tod-barra.py")"
  has "app fissate predefinite" "PRIME = [" "$(cat "$ROOT/share/tod-barra.py")"
}

test_xfce_single_power_button() { # un solo Spegni: Start, Ctrl+Alt+Canc e il tasto di accensione
  _fake_xfconf
  local q=xfconf-query
  desktop_install_entries
  xfce_power_button
  has "nome italiano" "Name[it]=Spegni" "$(cat "$HOME/.local/share/applications/tod-stop.desktop")"
  eq "Ctrl+Alt+Canc" "$PREFIX/bin/tod spegni" "$($q -c xfce4-keyboard-shortcuts -p "/commands/custom/<Primary><Alt>Delete")"
  eq "tasto di accensione" "$PREFIX/bin/tod spegni" "$($q -c xfce4-keyboard-shortcuts -p /commands/custom/XF86PowerOff)"
  eq "xfce4-panel mai chiamato" 0 "$(cat "$HOME/panel_calls" 2>/dev/null | wc -l)"
  # la voce "Esci" di XFCE nascosta dal menu
  mkdir -p "$PREFIX/share/applications" && echo x >"$PREFIX/share/applications/xfce4-session-logout.desktop"
  desktop_tune_files
  has "Esci nascosto" "NoDisplay=true" "$(cat "$HOME/.local/share/applications/xfce4-session-logout.desktop")"
}

test_tod_help_question_mark() {
  local out
  out=$(bash "$ROOT/tod" "?" 2>&1) || true
  has "tod ? mostra l'aiuto" "tod" "$out"
  hasnt "niente errore" "$(t unknown_cmd "?")" "$out"
}

_fake_deb() { # _fake_deb file nome architettura [percorso dei file]
  local d="$WORK/deb_$$_$2_$3"
  mkdir -p "$d/DEBIAN" "$d${4:-/usr/share/doc/$2}"
  printf 'Package: %s\nVersion: 1.0\nArchitecture: %s\nMaintainer: test <t@t>\nDescription: App di prova %s\n' "$2" "$3" "$2" >"$d/DEBIAN/control"
  echo x >"$d${4:-/usr/share/doc/$2}/file"
  dpkg-deb --root-owner-group -b "$d" "$1" >/dev/null 2>&1 || dpkg-deb -b "$d" "$1" >/dev/null
}

test_deb_install_routing() {
  command -v dpkg-deb >/dev/null || { echo "  (dpkg-deb assente: salto)"; return 0; }
  mkdir -p "$HOME/Downloads" "$HOME/lavoro"
  _fake_deb "$HOME/Downloads/photocraft-0.7.0-linux-aarch64.deb" photocraft arm64
  _fake_deb "$HOME/lavoro/strumento_aarch64.deb" strumento aarch64
  _fake_deb "$HOME/lavoro/giocopc_amd64.deb" giocopc amd64
  _fake_deb "$HOME/lavoro/temi_all.deb" temi all /data/data/com.termux/files/usr/share/temi
  # i tentativi di Pietro dell'11 ottobre: nome nudo, ./nome, percorso completo
  eq "nome nudo: cercato nei Download" "$HOME/Downloads/photocraft-0.7.0-linux-aarch64.deb" "$(cd "$HOME" && deb_resolve photocraft-0.7.0-linux-aarch64.deb)"
  eq "percorso relativo" "$HOME/lavoro/strumento_aarch64.deb" "$(cd "$HOME/lavoro" && deb_resolve ./strumento_aarch64.deb)"
  fails deb_resolve inesistente.deb
  mkdir -p "$HOME/Downloads/App ArtCraft" && cp "$HOME/lavoro/temi_all.deb" "$HOME/Downloads/App ArtCraft/spostato.deb"
  eq "nome nudo: anche nelle sottocartelle dei Download" "$HOME/Downloads/App ArtCraft/spostato.deb" "$(cd / && deb_resolve spostato.deb)"
  eq "Debian → container" container "$(deb_target "$HOME/Downloads/photocraft-0.7.0-linux-aarch64.deb")"
  eq "Termux → termux" termux "$(deb_target "$HOME/lavoro/strumento_aarch64.deb")"
  eq "all con percorsi di Termux" termux "$(deb_target "$HOME/lavoro/temi_all.deb")"
  eq "per PC" non-arm:amd64 "$(deb_target "$HOME/lavoro/giocopc_amd64.deb")"
  pkg_install() { echo "pkg $*" >>"$HOME/inst_calls"; }
  cx_installed() { return 0; }
  cx_pkg_install() { echo "cx $* export=${CX_EXPORT_NAMES:-} file=$([[ -f $TMPDIR/${1#/tmp/} ]] && echo si)" >>"$HOME/inst_calls"; }
  (cd "$HOME/lavoro" && apps_add ./strumento_aarch64.deb) >/dev/null 2>&1
  (cd "$HOME" && apps_add photocraft-0.7.0-linux-aarch64.deb) >/dev/null 2>&1
  local c
  c=$(cat "$HOME/inst_calls")
  has "Termux: apt con il percorso assoluto" "pkg $HOME/lavoro/strumento_aarch64.deb" "$c"
  has "Debian: nel container dalla /tmp condivisa" "cx /tmp/tod-deb-" "$c"
  has "Debian: voci di menu del pacchetto giusto" "export=photocraft file=si" "$c"
  eq "file temporaneo rimosso" "" "$(find "$TMPDIR" -name 'tod-deb-*' | tr -d '\n')"
  fails apps_add "$HOME/lavoro/giocopc_amd64.deb"
  has "spiegazione per i pacchetti da PC" "amd64" "$( (apps_add "$HOME/lavoro/giocopc_amd64.deb") 2>&1)"
  # doppio clic: finestre zenity
  cat >"$PREFIX/bin/zenity" <<'EOF'
#!/bin/bash
echo "zenity $*" >>"$HOME/zenity_calls"
if [[ $* == *--progress* ]]; then cat >/dev/null; fi
EOF
  chmod +x "$PREFIX/bin/zenity"
  PATH="$PREFIX/bin:$PATH"
  # senza PyGObject: dove c'è (il CI su Ubuntu) deb_gui farebbe exec dell'installer grafico al posto del test
  python3() { if [[ $* == "-c import gi" ]]; then return 1; fi; command python3 "$@"; }
  : >"$HOME/inst_calls"
  DISPLAY=:0 deb_gui "$HOME/Downloads/photocraft-0.7.0-linux-aarch64.deb" >/dev/null 2>&1
  c=$(cat "$HOME/zenity_calls")
  has "conferma con nome e versione" "Installare <b>photocraft</b> 1.0?" "$c"
  has "dice dove va" "installato in <b>Debian</b>" "$c"
  has "barra d'attesa" "--progress --pulsate" "$c"
  has "esito" "photocraft è installato" "$c"
  has "installato davvero" "cx /tmp/tod-deb-" "$(cat "$HOME/inst_calls")"
  : >"$HOME/zenity_calls"
  DISPLAY=:0 deb_gui "$HOME/lavoro/giocopc_amd64.deb" >/dev/null 2>&1 || true
  has "pacchetto da PC: errore chiaro" "--error" "$(cat "$HOME/zenity_calls")"
  # associazione del doppio clic
  desktop_install_entries
  has "aperto con tod installa" "Exec=$PREFIX/bin/tod installa %f" "$(cat "$HOME/.local/share/applications/tod-deb.desktop")"
  has ".deb predefinito" "application/vnd.debian.binary-package=tod-deb.desktop" "$(cat "$HOME/.config/mimeapps.list")"
}

test_files_user_home() {
  _fake_rootfs
  mkdir -p "$R/home/dex"
  export TOD_TERMUX_HOME=$HOME
  FILES_PHONE="$WORK/phone_$$"
  mkdir -p "$FILES_PHONE"/{Documents,Download,Pictures,Music,Movies,DCIM/Camera} "$HOME/Progetti" "$HOME/Desktop" \
    "$HOME/.config/gtk-3.0" "$HOME/.local/share" "$HOME/storage"
  echo cfg >"$HOME/.config/prova"
  # com'era sul telefono di Pietro: collegamenti Telefono/Downloads e segnalibri vecchi
  ln -s "$FILES_PHONE" "$HOME/Telefono"
  ln -s "$FILES_PHONE/Download" "$HOME/Downloads"
  printf '%s\n' "file://$HOME/Telefono Telefono" "file://$HOME/Telefono/DCIM/Camera Fotocamera" "file://$R/home/dex Debian" \
    "file://$HOME/Downloads" "file://$HOME/Progetti Progetti" >"$HOME/.config/gtk-3.0/bookmarks"
  conf_set USER_NAME pietro
  files_setup
  local uh b="$HOME/.config/gtk-3.0/bookmarks"
  uh="$(dirname "$HOME")/pietro"
  eq "home dell'utente" "$uh" "$(files_user_home)"
  eq "Documenti = quelli del telefono" "$(readlink -f "$FILES_PHONE/Documents")" "$(readlink -f "$uh/Documenti")"
  eq "Video = Movies del telefono" "$(readlink -f "$FILES_PHONE/Movies")" "$(readlink -f "$uh/Video")"
  eq "Desktop = quello di Termux (lanciatori)" "$(readlink -f "$HOME/Desktop")" "$(readlink -f "$uh/Desktop")"
  eq "impostazioni condivise" cfg "$(cat "$uh/.config/prova")"
  eq "nella home solo le cartelle dell'utente" "Desktop Documenti Download Immagini Musica Video" "$(ls "$uh" | sort | tr '\n' ' ' | sed 's/ $//')"
  eq "collegamento Telefono tolto" no "$([[ -e $HOME/Telefono || -L $HOME/Telefono ]] && echo si || echo no)"
  has "cartelle XDG nella home dell'utente" "XDG_DOWNLOAD_DIR=\"$uh/Download\"" "$(cat "$HOME/.config/user-dirs.dirs")"
  eq "barra laterale: prima le cartelle dell'utente" "file://$uh/Documenti" "$(sed -n 1p "$b")"
  hasnt "niente Telefono" "Telefono" "$(cat "$b")"
  hasnt "niente Debian" "Debian" "$(cat "$b")"
  hasnt "niente Fotocamera" "Fotocamera" "$(cat "$b")"
  hasnt "niente doppione di Download" "file://$HOME/Downloads" "$(cat "$b")"
  has "segnalibro dell'utente conservato" "file://$HOME/Progetti Progetti" "$(cat "$b")"
  has "niente frecce sui collegamenti" "<svg" "$(cat "$HOME/.local/share/icons/hicolor/22x22/emblems/emblem-symbolic-link.svg")"
  has "niente X rosse" "<svg" "$(cat "$HOME/.local/share/icons/hicolor/22x22/emblems/emblem-unreadable.svg")"
  eq "niente più tema Fluent-tod (le icone DeX OS hanno gli emblemi vuoti)" no "$([[ -e $HOME/.local/share/icons/Fluent-tod ]] && echo si || echo no)"
  eq "Android/data nascosto nel telefono" Android "$(cat "$FILES_PHONE/.hidden")"
  local app
  app=$(dirname "$(dirname "$HOME")")
  eq "/data/data → solo la cartella di Termux" "${app##*/}" "$(ls "$PREFIX/share/tod-fs$(dirname "$app")")"
  has "nella cartella di Termux solo files" code_cache "$(cat "$app/.hidden")"
  has "sopra la home: la home tecnica di Termux nascosta" "${HOME##*/}" "$(cat "$(dirname "$HOME")/.hidden" 2>/dev/null)"
  local n
  n=$(wc -l <"$b")
  files_setup
  eq "seconda volta: niente doppioni" "$n" "$(wc -l <"$b")"
  # container: stesse cartelle
  mkdir -p "$R/home/dex/Documenti" "$R/home/dex/Musica"
  touch "$R/home/dex/Musica/mio.mp3"
  ln -s "$FILES_PHONE/Download" "$R/home/dex/Downloads"
  ln -s "$WORK" "$R/home/dex/storage"
  files_cx_user_dirs
  eq "doppione Downloads tolto" no "$([[ -L $R/home/dex/Downloads ]] && echo si || echo no)"
  eq "storage nascosto" storage "$(cat "$R/home/dex/.hidden")"
  eq "Documenti nel container: collegamento, non un disco montato" "$(readlink -f "$FILES_PHONE/Documents")" "$(readlink "$R/home/dex/Documenti")"
  eq "Desktop nel container" "$(readlink -f "$HOME/Desktop")" "$(readlink "$R/home/dex/Desktop")"
  eq "una cartella vera con file non si tocca" mio.mp3 "$(ls "$R/home/dex/Musica")"
  has "Salva con nome nel container" 'XDG_DOCUMENTS_DIR="$HOME/Documenti"' "$(cat "$R/home/dex/.config/user-dirs.dirs")"
  # la sessione gira come pietro
  (
    session_user_env
    eq "HOME della sessione" "$uh" "$HOME"
    eq "utente" pietro "$TOD_USER"
    eq "mappa delle cartelle di sistema" "$PREFIX/share/tod-fs" "$TOD_FS_MAP"
    eq "nome completo" Pietro "$TOD_USER_FULLNAME"
    eq "tod trova ancora i suoi file" "$(readlink -f "$TOD_TERMUX_HOME/.config/tod/tod.conf")" "$(readlink -f "$HOME/.config/tod/tod.conf")"
  )
  # Thunar come Esplora file
  _fake_xfconf
  files_session
  eq "niente barra dei menu" false "$(xfconf-query -c thunar -p /last-menubar-visible)"
  eq "barra del titolo uguale alle altre finestre" false "$(xfconf-query -c thunar -p /misc-use-csd)"
  eq "niente emblemi nella barra laterale" false "$(xfconf-query -c thunar -p /shortcuts-icon-emblems)"
  has "stile Esplora file" ".thunar .path-bar" "$(cat "$HOME/.config/gtk-3.0/gtk.css")"
  printf 'mio { color: red; }\n' >>"$HOME/.config/gtk-3.0/gtk.css"
  files_gtk_css
  eq "stile scritto una volta sola" 1 "$(grep -cF "Termux On DeX: Esplora file" "$HOME/.config/gtk-3.0/gtk.css")"
  has "le regole dell'utente restano" "mio { color: red; }" "$(cat "$HOME/.config/gtk-3.0/gtk.css")"
  eq "niente barra di stato" false "$(xfconf-query -c thunar -p /last-statusbar-visible)"
  eq "i dischi USB collegati sulla scrivania, come macOS" true "$(xfconf-query -c xfce4-desktop -p /desktop-icons/file-icons/show-removable)"
  eq "anche i volumi di tipo device (tod-volumi)" true "$(xfconf-query -c xfce4-desktop -p /desktop-icons/file-icons/show-device-removable)"
  eq "niente file system sulla scrivania" false "$(xfconf-query -c xfce4-desktop -p /desktop-icons/file-icons/show-filesystem)"
  eq "niente Computer, File System, Rete" "computer:/// file:/// network:///" "$(xfconf_values thunar /hidden-bookmarks | tr '\n' ' ' | sed 's/ $//')"
  # nome non valido: niente home
  conf_set USER_NAME "Pietro Cav"
  fails files_user_home
  fails files_user_valid usr
}

test_i18n_follows_desktop_language() {
  getprop() { echo ""; }
  conf_set LINGUA it
  LANG=en_US.UTF-8 i18n_init
  eq "senza getprop: la lingua del desktop" it "$TOD_LANG"
  conf_set UI_LANG en
  i18n_init
  eq "UI_LANG vince" en "$TOD_LANG"
}

test_gettext_shim_program_domain() {
  local cc
  cc=$(command -v cc || command -v clang || true)
  if [[ -z $cc ]] || ! command -v python3 >/dev/null; then echo "  (compilatore o python3 assente: salto)"; return 0; fi
  local d="$WORK/shim_$$"
  # su Android il linker carica librerie solo sotto /data: lì, se c'è
  # (non usr/tmp: sotto proot diventa /tmp, che il linker rifiuta)
  if [[ -d /data/data/com.termux/cache && -w /data/data/com.termux/cache ]]; then d=$(mktemp -d /data/data/com.termux/cache/tod-shimtest-XXXXXX); fi
  mkdir -p "$d/loc/it/LC_MESSAGES"
  "$cc" -shared -fPIC -O2 -o "$d/shim.so" "$ROOT/share/tod-gettext.c" -ldl
  # catalogo .mo minimo per il dominio "provaprog" (formato GNU)
  python3 - "$d/loc/it/LC_MESSAGES/provaprog.mo" <<'EOF'
import struct, sys
msgs = {b"": b"Content-Type: text/plain; charset=UTF-8\nPlural-Forms: nplurals=2; plural=(n != 1);\n", b"_Edit": b"_Modifica"}
keys = sorted(msgs); ids = b""; strs = b""; o = []; t = []
for k in keys:
    o.append((len(k), len(ids))); ids += k + b"\0"
    t.append((len(msgs[k]), len(strs))); strs += msgs[k] + b"\0"
n = len(keys); start = 7 * 4 + 16 * n
out = struct.pack("Iiiiiii", 0x950412de, 0, n, 7 * 4, 7 * 4 + 8 * n, 0, 0)
out += b"".join(struct.pack("ii", l, start + p) for l, p in o)
out += b"".join(struct.pack("ii", l, start + len(ids) + p) for l, p in t)
open(sys.argv[1], "wb").write(out + ids + strs)
EOF
  cat >"$d/provaprog.c" <<'EOF'
#include <stdio.h>
char *dgettext(const char *, const char *);
char *textdomain(const char *);
int main(int argc, char **argv) {
  if (argc > 1) textdomain(argv[1]);
  printf("%s\n", dgettext(NULL, "_Edit"));
  return 0;
}
EOF
  # su Android dgettext non è in libc: si collega alla libreria stessa
  "$cc" -o "$d/provaprog" "$d/provaprog.c" 2>/dev/null ||
    "$cc" -o "$d/provaprog" "$d/provaprog.c" "$d/shim.so" -Wl,-rpath,"$d"
  local run=(env TOD_GETTEXT_LANG=it TOD_GETTEXT_DIR="$d/loc" LD_PRELOAD="$d/shim.so" "$d/provaprog")
  eq "senza textdomain: il dominio è il nome del programma (Thunar su Termux)" _Modifica "$("${run[@]}")"
  eq "textdomain esplicito vince" _Edit "$("${run[@]}" altrodominio)"
  eq "senza lingua: niente traduzione" _Edit "$(env TOD_GETTEXT_DIR="$d/loc" LD_PRELOAD="$d/shim.so" "$d/provaprog")"
  # GObject caricata dopo l'avvio (Python con gi): RTLD_NEXT dava NULL e g_object_add_weak_pointer non
  # registrava niente → puntatori appesi a widget liberati, barra e Start in crash (22 ottobre)
  cat >"$d/debole.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
  void *h = dlopen("libgobject-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!h) h = dlopen("libgobject-2.0.so", RTLD_NOW | RTLD_LOCAL);
  if (!h) { puts("salta"); return 0; }
  void *(*nuovo)(unsigned long, const char *, ...) = (void *(*)(unsigned long, const char *, ...))dlsym(h, "g_object_new");
  void (*unref)(void *) = (void (*)(void *))dlsym(h, "g_object_unref");
  /* GTK la chiama per nome: arriva a quella intercettata */
  void (*debole)(void *, void **) = (void (*)(void *, void **))dlsym(RTLD_DEFAULT, "g_object_add_weak_pointer");
  if (!debole) debole = (void (*)(void *, void **))dlsym(h, "g_object_add_weak_pointer");
  void *o = nuovo(80, NULL), *p = o;   /* 80 = G_TYPE_OBJECT */
  debole(o, &p);
  unref(o);
  puts(p ? "appeso" : "azzerato");
  return 0;
}
EOF
  if "$cc" -o "$d/debole" "$d/debole.c" -ldl 2>/dev/null; then
    local esito
    esito=$(LD_PRELOAD="$d/shim.so" "$d/debole")
    if [[ $esito != salta ]]; then eq "GObject caricata dopo: il puntatore debole si azzera" azzerato "$esito"; fi
  fi
  # nome utente (getpwuid/getpwnam): "pietro" invece di u0_a715
  cat >"$d/chi.c" <<'EOF'
#include <stdio.h>
#include <pwd.h>
#include <unistd.h>
int main(void) {
  struct passwd *p = getpwuid(getuid());
  struct passwd *q = getpwnam("pietro");
  printf("%s|%s\n", p ? p->pw_name : "?", q ? q->pw_name : "-");
  return 0;
}
EOF
  "$cc" -o "$d/chi" "$d/chi.c"
  eq "utente della sessione" "pietro|pietro" "$(env TOD_USER=pietro LD_PRELOAD="$d/shim.so" "$d/chi")"
  hasnt "fuori dalla sessione niente cambia" "pietro" "$(env LD_PRELOAD="$d/shim.so" "$d/chi")"
  # cartelle di sistema che Android non lascia leggere (/data/data): elencate dalla mappa
  cat >"$d/elenca.c" <<'EOF'
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  DIR *d = opendir(argv[1]);
  if (!d) { printf("errore\n"); return 0; }
  struct dirent *e;
  while ((e = readdir(d))) if (e->d_name[0] != '.') printf("%s ", e->d_name);
  printf("| %s\n", access(argv[1], R_OK) == 0 ? "leggibile" : "no");
  closedir(d);
  return 0;
}
EOF
  "$cc" -o "$d/elenca" "$d/elenca.c"
  mkdir -p "$d/chiusa/com.termux" "$d/chiusa/altra_app" "$d/mappa$d/chiusa/com.termux"
  chmod 000 "$d/chiusa"
  if ! ls "$d/chiusa" >/dev/null 2>&1; then
    eq "senza mappa: errore come prima" errore "$(env LD_PRELOAD="$d/shim.so" "$d/elenca" "$d/chiusa")"
    eq "con la mappa: solo la strada verso Termux" "com.termux | leggibile" \
      "$(env TOD_FS_MAP="$d/mappa" LD_PRELOAD="$d/shim.so" "$d/elenca" "$d/chiusa/")"
  fi
  chmod 755 "$d/chiusa"
  has "cartelle leggibili: quelle vere" altra_app "$(env TOD_FS_MAP="$d/mappa" LD_PRELOAD="$d/shim.so" "$d/elenca" "$d/chiusa")"
  rm -rf "$d"
}

test_look_windows11() { # DeX OS: tema, tasto Windows, registro delle notifiche, proporzioni; niente xfce4-panel
  pkg_install_avail() { echo "$*" >>"$HOME/pkg_calls"; }
  cx_installed() { return 1; }
  mkdir -p "$PREFIX/share/applications"
  desktop_install_entries
  look_apply_windows11 >/dev/null 2>&1
  has "Fluent GTK (la base di DeX OS)" "fluent-gtk-theme" "$(cat "$HOME/pkg_calls")"
  hasnt "niente icone Fluent né plugin della barra" "fluent-icon-theme" "$(cat "$HOME/pkg_calls")"
  hasnt "niente docklike" "docklike" "$(cat "$HOME/pkg_calls")"
  eq "nessuna configurazione della barra di XFCE" no "$([[ -e $HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml || -e $HOME/.config/xfce4/panel ]] && echo si || echo no)"
  eq "comando tod-start" "$TOD_ROOT/share/tod-start" "$(readlink "$PREFIX/bin/tod-start")"
  eq "aspetto" windows11 "$(conf_get ASPETTO)"
  # nella sessione
  _fake_xfconf
  look_session_apply
  local q=xfconf-query
  eq "tema" Fluent-Light "$($q -c xsettings -p /Net/ThemeName)"
  eq "finestre" Fluent-Light "$($q -c xfwm4 -p /general/theme)"
  eq "pulsanti a destra" "O|HMC" "$($q -c xfwm4 -p /general/button_layout)"
  eq "tasto Windows" "$PREFIX/bin/tod-start" "$($q -c xfce4-keyboard-shortcuts -p /commands/custom/Super_L)"
  eq "registro delle notifiche acceso (per il pannello)" true "$($q -c xfce4-notifyd -p /notification-log)"
  eq "notifiche in basso a destra" bottom-right "$($q -c xfce4-notifyd -p /notify-location)"
  eq "xfce4-panel mai chiamato" 0 "$(cat "$HOME/panel_calls" 2>/dev/null | wc -l)"
  # proporzioni: tutto dallo stesso DPI
  look_scale_apply 108
  eq "icone del desktop in proporzione" 54 "$($q -c xfce4-desktop -p /desktop-icons/icon-size)"
  eq "puntatore in proporzione" 27 "$($q -c xsettings -p /Gtk/CursorThemeSize)"
  eq "senza Inter niente font Inter" 1 "$($q -c xsettings -p /Gtk/FontName >/dev/null 2>&1 && echo 0 || echo 1)"
  $q -c xsettings -p /Net/ThemeName -n -t string -s Altro
  look_session_apply
  eq "una volta sola" Altro "$($q -c xsettings -p /Net/ThemeName)"
  # XFCE di base non c'è più: solo DeX OS
  fails look_cli xfce
  fails look_cli v1
}

test_look_via_barra_xfce() { # aggiornando: via plugin della barra di XFCE, icone Fluent, copie vecchie
  local h=$HOME
  export TOD_TERMUX_HOME=$h
  mkdir -p "$h/.local/share/icons/Fluent-tod" "$h/.config/xfce4/panel" "$h/.config/xfce4.prima-di-windows11" \
    "$h/.local/share/icons/hicolor/scalable/apps" "$h/.config/xfce4/xfconf/xfce-perchannel-xml"
  echo x >"$h/.local/share/icons/hicolor/scalable/apps/tod-start.svg"
  echo x >"$h/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
  pkg_installed() { [[ $1 == xfce4-docklike-plugin || $1 == fluent-icon-theme ]]; }
  apt_run() { echo "$*" >>"$h/apt_calls"; }
  look_via_barra_xfce
  has "apt toglie solo quelli installati" "remove fluent-icon-theme xfce4-docklike-plugin" "$(cat "$h/apt_calls")"
  hasnt "e non gli altri" "whiskermenu" "$(cat "$h/apt_calls")"
  local f
  for f in .local/share/icons/Fluent-tod .config/xfce4/panel .config/xfce4.prima-di-windows11 \
    .local/share/icons/hicolor/scalable/apps/tod-start.svg .config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml; do
    eq "via $f" no "$([[ -e $h/$f ]] && echo si || echo no)"
  done
  # DeX OS: le versioni superate del disegno via, gli altri colori restano
  local t="$h/.local/share/themes" i="$h/.local/share/icons"
  mkdir -p "$t/DeX-OS-0067c0-v10" "$t/DeX-OS-0067c0-v11" "$t/DeX-OS-WM-1.333-v10" "$t/DeX-OS-WM-1.333-v11" "$t/DeX-OS-8a5cf5-v11" \
    "$i/DeX-OS-Icons-0067c0-v8" "$i/DeX-OS-Icons-0067c0-v9" "$i/DeX-OS-Icons-Dark-0067c0-v8" "$i/DeX-OS-Cursors-0067c0-v2"
  conf_set DEXOS_NAMES "DeX-OS-0067c0-v11 DeX-OS-Dark-0067c0-v11 DeX-OS-WM-1.333-v11 DeX-OS-WM-Dark-1.333-v11 DeX-OS-Icons-0067c0-v9 DeX-OS-Cursors-0067c0-v2"
  look_dexos_vecchi
  eq "temi e icone superati via, attuali e altri colori restano" \
    "DeX-OS-0067c0-v11 DeX-OS-8a5cf5-v11 DeX-OS-WM-1.333-v11 | DeX-OS-Cursors-0067c0-v2 DeX-OS-Icons-0067c0-v9" \
    "$(ls "$t" | tr '\n' ' ')| $(ls "$i" | grep DeX | tr '\n' ' ' | sed 's/ $//')"
}

test_cx_sync_look() {
  _fake_rootfs
  export TOD_TERMUX_HOME=$HOME
  mkdir -p "$PREFIX/share/themes/Fluent-Light/gtk-3.0" "$PREFIX/share/icons/Fluent" "$PREFIX/share/fonts/tod-inter" \
    "$HOME/.local/share/icons/Fluent-tod" "$HOME/.local/share/icons/hicolor" "$HOME/.local/share/icons/DeX-OS-Cursors-x-v2" "$R/usr/share/icons/Adwaita"
  cx_sync_look
  eq "tema Fluent nel container" "$PREFIX/share/themes/Fluent-Light" "$(readlink "$R/usr/share/themes/Fluent-Light")"
  eq "icone senza emblemi nel container" "$HOME/.local/share/icons/Fluent-tod" "$(readlink "$R/usr/share/icons/Fluent-tod")"
  eq "puntatore DeX OS" "$HOME/.local/share/icons/DeX-OS-Cursors-x-v2" "$(readlink "$R/usr/share/icons/DeX-OS-Cursors-x-v2")"
  eq "font Inter" "$PREFIX/share/fonts/tod-inter" "$(readlink "$R/usr/local/share/fonts/tod-inter")"
  eq "hicolor del container intatto" no "$([[ -L $R/usr/share/icons/hicolor ]] && echo si || echo no)"
}

test_shizuku() {
  command -v zip >/dev/null || { echo "  (zip assente: salto)"; return 0; }
  local d="$WORK/sz_$$"
  mkdir -p "$d/assets"
  printf '#!/system/bin/sh\n[ -z "$RISH_APPLICATION_ID" ] && export RISH_APPLICATION_ID="PKG"\n' >"$d/assets/rish"
  echo dex >"$d/assets/rish_shizuku.dex"
  (cd "$d" && zip -q -r base.apk assets)
  printf '#!/bin/sh\n[ "$1" = path ] && echo "package:%s/base.apk"\n' "$d" >"$PREFIX/bin/pm"
  chmod +x "$PREFIX/bin/pm"
  PATH="$PREFIX/bin:$PATH"
  shizuku_rish_install
  has "rish per Termux" 'RISH_APPLICATION_ID="com.termux"' "$(cat "$PREFIX/bin/rish")"
  eq "dex di sola lettura (Android 14+)" 400 "$(stat -c %a "$(shizuku_dir)/rish_shizuku.dex")"
  # Shizuku attivo: i comandi "da ADB" passano da rish
  printf '#!/bin/sh\n[ "$1" = -c ] && shift; case "$1" in "echo tod-ok") echo tod-ok ;; *) echo "rish:$1" ;; esac\n' >"$(shizuku_dir)/rish"
  SHIZUKU_OK=""
  shizuku_ready
  eq "comando via Shizuku" "rish:settings get global x " "$(priv_sh settings get global x)"
  eq "stato" "$(t sz_ok)" "$(shizuku_status)"
  # Shizuku spento: si torna ad ADB
  printf '#!/bin/sh\nexit 1\n' >"$(shizuku_dir)/rish"
  printf '#!/bin/sh\necho "adb:$*"\n' >"$PREFIX/bin/adb"
  chmod +x "$PREFIX/bin/adb"
  SHIZUKU_OK="" ADB_SERIAL=127.0.0.1:5555
  eq "senza Shizuku: ADB" "adb:-s 127.0.0.1:5555 shell settings get global x" "$(priv_sh settings get global x)"
}

test_start_unblocks_usr1() { # Android blocca SIGUSR1 e i figli lo ereditano: il menu deve sbloccarlo
  has "sblocco di SIGUSR1" "pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGUSR1})" "$(cat "$ROOT/share/tod-start.py")"
  command -v python3 >/dev/null || return 0
  eq "con il segnale bloccato dal padre, arriva lo stesso" ricevuto "$(timeout 10 python3 -c '
import signal, subprocess, sys, time
signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})   # come fa Android: il figlio lo eredita
child = "import signal,sys\nsignal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGUSR1})\n" \
        "signal.signal(signal.SIGUSR1, lambda *a: (print(\"ricevuto\"), sys.exit(0)))\nsignal.pause()"
p = subprocess.Popen([sys.executable, "-c", child])
time.sleep(0.5); p.send_signal(signal.SIGUSR1); p.wait(5)
')"
}

test_start_wrapper() {
  local w="$ROOT/share/tod-start" log="$WORK/start_$$"
  mkdir -p "$TMPDIR" "$WORK/fakepy_$$"
  printf '#!/bin/sh\necho "python3 $*" >>"%s"\n' "$log" >"$WORK/fakepy_$$/python3"
  chmod +x "$WORK/fakepy_$$/python3"
  # nessun menu in memoria: si avvia e si mostra
  PATH="$WORK/fakepy_$$:$PATH" sh "$w"
  has "senza menu: avvio con --show" "tod-start.py --show" "$(cat "$log")"
  # menu vivo ma bloccato (non risponde a SIGUSR1): ucciso e riavviato
  bash -c 'trap "" USR1; sleep 20; :' tod-start.py &   # nel cmdline come il menu vero
  local hung=$!
  echo "$hung" >"$TMPDIR/tod-start.pid"
  : >"$log"
  PATH="$WORK/fakepy_$$:$PATH" sh "$w" 2>/dev/null
  sleep 0.2
  eq "menu bloccato: ucciso" no "$(kill -0 "$hung" 2>/dev/null && echo si || echo no)"
  has "e riavviato" "tod-start.py --show" "$(cat "$log")"
  # dopo un riavvio il vecchio pid può essere di un altro processo: non è il menu, non si tocca
  sleep 20 &
  local other=$!
  echo "$other" >"$TMPDIR/tod-start.pid"
  : >"$log"
  PATH="$WORK/fakepy_$$:$PATH" sh "$w" --preload 2>/dev/null
  has "pid di un altro processo: menu precaricato lo stesso" "tod-start.py" "$(cat "$log")"
  eq "e l'altro processo resta vivo" si "$(kill -0 "$other" 2>/dev/null && echo si || echo no)"
  kill "$other" 2>/dev/null || true
}

test_android_apps() {
  command -v python3 >/dev/null || { echo "  (python3 assente: salto)"; return 0; }
  local out
  out=$(python3 - "$ROOT/share/tod-android-apps.py" <<'EOF'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("a", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(round(m.inset_fraction("(type 0x6)0x147ae30"), 3))
tree = """N: android=http://schemas.android.com/apk/res/android
  E: vector (line=1)
    A: http://schemas.android.com/apk/res/android:viewportWidth(0x01010402)=(type 0x4)0x42d80000
    A: http://schemas.android.com/apk/res/android:viewportHeight(0x01010403)=108.0
    E: path (line=2)
      A: http://schemas.android.com/apk/res/android:fillColor(0x010101a5)=#ff25d366
      A: http://schemas.android.com/apk/res/android:pathData(0x01010405)="M0,0h108v108h-108z" (Raw: "M0,0h108v108h-108z")
"""
class F:   # APK finto: nessuna risorsa
    def resolve(self, r): return None
w, h, body = m.vector_svg(F(), m.xml_nodes(tree))
print(h, body)
print(m.FRAMEWORK_COLORS["0x0106000b"][0])
EOF
)
  has "frazione di inset di Android" "0.01" "$out"
  has "vettore → SVG con il colore" '<path d="M0,0h108v108h-108z" fill="#25d366"' "$out"
  has "colore di Android (bianco)" "#ffffff" "$out"
  # sincronizzazione: mai senza gli strumenti, mai se spenta
  android_apps_ready() { return 1; }
  android_apps_sync
  conf_set ANDROID_APPS 0
  android_apps_ready() { return 0; }
  android_apps_sync
  eq "spenta: niente scansione" no "$([[ -e $TOD_STATE_DIR/android-apps.log ]] && echo si || echo no)"
}

test_phone_status() {
  command -v python3 >/dev/null || { echo "  (python3 assente: salto)"; return 0; }
  mkdir -p "$TMPDIR"
  local ps="$ROOT/share/tod-phone-status.py"
  printf '%s' '{"battery":{"percentage":51,"status":"DISCHARGING","plugged":"UNPLUGGED","temperature":35.0},"wifi":{"supplicant_state":"COMPLETED","rssi":-60,"ssid":"\"Casa\"","ip":"192.168.1.17"}}' >"$TMPDIR/tod-phone.json"
  has "batteria al 50%" "<icon>battery-level-50-symbolic</icon>" "$(LANGUAGE=it python3 "$ps" batteria)"
  has "percentuale nel suggerimento" "51%" "$(LANGUAGE=it python3 "$ps" batteria)"
  has "Wi-Fi con il nome della rete" "Wi-Fi: Casa" "$(LANGUAGE=it python3 "$ps" rete)"
  has "segnale buono" "network-wireless-signal-good-symbolic" "$(LANGUAGE=it python3 "$ps" rete)"
  printf '%s' '{"battery":{"percentage":100,"status":"CHARGING","plugged":"AC"},"wifi":{"error":"Please grant the following permission to use this command: android.permission.ACCESS_FINE_LOCATION"}}' >"$TMPDIR/tod-phone.json"
  has "in carica" "battery-level-100-charged-symbolic" "$(LANGUAGE=it python3 "$ps" batteria)"
  has "manca il permesso Posizione" "permesso Posizione" "$(LANGUAGE=it python3 "$ps" rete)"
  # nella nostra barra: rete, volume, batteria, notifiche, orologio, in quest'ordine
  has "ordine delle icone di stato" '"rete"' "$(grep -A2 'VOCI = \[' "$ROOT/share/tod-barra.py")"
  # notifiche: solo le nuove, niente Termux/sistema, niente doppioni; cambia il testo = nuova
  local py
  py=$(
    cd "$ROOT/share" && python3 -c '
import importlib.util as u
s = u.spec_from_file_location("ps", "tod-phone-status.py"); m = u.module_from_spec(s); s.loader.exec_module(m)
seen = {}
a = [{"key": "k1", "packageName": "com.whatsapp", "title": "Anna", "content": "ciao"},
     {"key": "k2", "packageName": "com.termux", "title": "Termux", "content": "1 session"}]
m.fresh(a, seen)
b = a + [{"key": "k3", "packageName": "com.google.android.gm", "title": "Posta", "content": "x"},
         {"key": "k4", "packageName": "com.google.android.gm", "title": "Posta", "content": "x"}]
b[0] = dict(b[0], content="ciao, ci sei?")
print(",".join(n["key"] for n in m.fresh(b, seen)))
print(",".join(n["key"] for n in m.fresh(b[1:], seen)), len(seen))
'
  )
  eq "solo le notifiche nuove" "k1,k3
 3" "$py"
}

test_lingua_code_and_env() {
  eq "dalla lingua di Android" it "$(lingua_code)"
  conf_set LINGUA en
  eq "scelta dell'utente" en "$(lingua_code)"
  conf_set LINGUA it
  fails lingua_active
  # 1° novembre (S20+): passo di traduzione fallito → anche Start, barra e Impostazioni in inglese
  eq "senza traduzione di XFCE: la lingua per le nostre finestre, niente modulo" "it||" \
    "$(unset LANGUAGE TOD_GETTEXT_LANG LD_PRELOAD; lingua_env; echo "${LANGUAGE:-}|${TOD_GETTEXT_LANG:-}|${LD_PRELOAD:-}")"
  eq "in inglese: niente" "|" "$(unset LANGUAGE TOD_GETTEXT_LANG; LINGUA=x; conf_set LINGUA en; lingua_env; echo "${LANGUAGE:-}|${TOD_GETTEXT_LANG:-}"; conf_set LINGUA it)"
  conf_set LINGUA it
  touch "$LINGUA_SO"
  mkdir -p "$LINGUA_DIR/it/LC_MESSAGES"
  fails lingua_active
  touch "$LINGUA_DIR/it/LC_MESSAGES/xfce4-panel.mo"
  lingua_active
  LD_PRELOAD=/termux-exec.so lingua_env
  eq "libreria davanti a termux-exec" "$LINGUA_SO:/termux-exec.so" "$LD_PRELOAD"
  eq "lingua" it "$TOD_GETTEXT_LANG"
  eq "LANGUAGE per i menu di glib" it "$LANGUAGE"
  lingua_env
  eq "non aggiunta due volte" "$LINGUA_SO:/termux-exec.so" "$LD_PRELOAD"
  mkdir -p "$WORK/mo_$$" && touch "$WORK/mo_$$/a.mo" "$WORK/mo_$$/gimp30.mo"
  eq "cataloghi installati" 2 "$(lingua_install_mo it "$WORK/mo_$$" | tail -n 1)"
  # i plug-in di GIMP vogliono la cartella compilata $PREFIX/share/locale (26 ottobre)
  eq "share/locale porta alle nostre traduzioni" tod-locale "$(readlink "$PREFIX/share/locale")"
  # cataloghi delle app solo se l'app c'è
  have() { [[ $1 == gimp ]]; }
  eq "solo GIMP installato" "gimp-data libgimp-3.0-0" "$(lingua_app_pkgs | tr '\n' ' ' | sed 's/ $//')"
  have() { command -v "$1" >/dev/null 2>&1; }
}

test_lingua_ripara() { # la traduzione mancante si installa da sola all'avvio del desktop, una volta al giorno
  conf_set LINGUA it
  lingua_setup() { echo chiamata >>"$HOME/ripara"; touch "$LINGUA_SO"; mkdir -p "$LINGUA_DIR/it/LC_MESSAGES"
    touch "$LINGUA_DIR/it/LC_MESSAGES/thunar.mo"; }
  printf '#!/bin/sh\necho "$@" >>"$HOME/notifiche"\n' >"$PREFIX/bin/notify-send"
  chmod +x "$PREFIX/bin/notify-send"
  PATH="$PREFIX/bin:$PATH"
  has "tod doctor: mancante, e cosa succederà" "traduzione di XFCE mancante" "$(lingua_doctor)"
  lingua_ripara
  wait
  eq "installata in sottofondo" chiamata "$(cat "$HOME/ripara")"
  has "avviso quando è pronta" "Traduzione pronta" "$(cat "$HOME/notifiche")"
  eq "tod doctor: pronta" "it, desktop tradotto" "$(lingua_doctor)"
  rm -f "$LINGUA_SO" "$HOME/ripara"
  lingua_ripara
  wait
  eq "fallita oggi: si riprova domani, non a ogni avvio" "" "$(cat "$HOME/ripara" 2>/dev/null)"
  echo 2000-01-01 >"$TOD_STATE_DIR/lingua-tentativo"
  lingua_ripara
  wait
  eq "un altro giorno: si riprova" chiamata "$(cat "$HOME/ripara")"
  conf_set LINGUA en
  rm -f "$HOME/ripara" "$TOD_STATE_DIR/lingua-tentativo"
  lingua_ripara
  wait
  eq "in inglese: niente da installare" "" "$(cat "$HOME/ripara" 2>/dev/null)"
  has "chiamata dall'hook della sessione" "lingua_ripara" "$(sed -n '/^session_hook() {/,/^}/p' "$ROOT/lib/session.sh")"
}

test_x11_glamor_solo_adreno() { # 1° novembre: sul S20+ (Mali) la Termux:X11 con glamor si chiudeva appena aperta
  conf_set X11_GLAMOR 1
  local GPU_FAMILY=adreno
  x11_glamor_ok || { echo "  ✘ Adreno: glamor acceso"; return 1; }
  GPU_FAMILY=mali
  fails x11_glamor_ok
  GPU_FAMILY=xclipse
  fails x11_glamor_ok
  GPU_FAMILY=adreno
  conf_set X11_GLAMOR_NO 1
  fails x11_glamor_ok
  conf_set X11_GLAMOR_NO 0
  conf_set X11_GLAMOR 0
  fails x11_glamor_ok
}

test_session_start_glamor_ripiego() { # Termux:X11 con glamor che si chiude subito: si riparte senza, per sempre
  command -v python3 >/dev/null || { echo "  (python3 assente: salto)"; return 0; }
  cat >"$PREFIX/bin/termux-x11" <<'EOF'
#!/bin/bash
echo "${TERMUX_X11_GLAMOR:-?}" >>"$HOME/x11_glamor"
exec -a app_process python3 -c '
import os, socket, time
d = os.environ["TMPDIR"] + "/.X11-unix"; os.makedirs(d, exist_ok=True)
p = d + "/X0"
if os.path.exists(p): os.unlink(p)
s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(1)
time.sleep(1 if os.environ.get("TERMUX_X11_GLAMOR") == "1" else 30)' com.termux.x11.CmdEntryPoint "$@"
EOF
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/am"
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/termux-x11-preference"
  chmod +x "$PREFIX/bin/termux-x11" "$PREFIX/bin/am" "$PREFIX/bin/termux-x11-preference"
  PATH="$PREFIX/bin:$PATH"
  TOD_X11_WAIT=3 TOD_X11_SETTLE=0 TOD_X11_VIVO=2
  local GPU_FAMILY=adreno
  conf_set INSTALLED 1
  conf_set X11_GLAMOR 1
  session_start >/dev/null 2>&1
  x11_running || { echo "  ✘ il desktop deve partire senza glamor"; return 1; }
  eq "prima con glamor, poi senza" "1 0" "$(tr '\n' ' ' <"$HOME/x11_glamor" | sed 's/ $//')"
  eq "ricordato per questo telefono" 1 "$(conf_get X11_GLAMOR_NO)"
  has "nel registro il perché" "si è chiusa appena aperta" "$(cat "$TOD_LOG")"
  session_stop >/dev/null 2>&1
  fails x11_running
  : >"$HOME/x11_glamor"
  session_start >/dev/null 2>&1
  eq "la volta dopo: subito senza glamor" "0" "$(cat "$HOME/x11_glamor")"
  session_stop >/dev/null 2>&1
}

test_xstartup_server_nuovo_niente_arresto() { # la sessione del server morto non spegne quello ripartito
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/dbus-launch"
  printf '#!/bin/sh\necho "$@" >"$HOME/tod_called"\n' >"$PREFIX/bin/tod"
  chmod +x "$PREFIX/bin/dbus-launch" "$PREFIX/bin/tod"
  PATH="$PREFIX/bin:$PATH"
  x11_server_pids() { if [[ -f $HOME/srv_n ]]; then echo 222; else touch "$HOME/srv_n"; echo 111; fi; }
  session_xstartup >/dev/null 2>&1
  sleep 1
  eq "server nuovo: niente arresto" "" "$(cat "$HOME/tod_called" 2>/dev/null)"
  has "nel registro" "il server X è un altro" "$(cat "$TOD_LOG")"
}

test_logout_stops_everything() {
  # "Esci" dal menu: quando la sessione XFCE finisce, parte "tod stop" staccato
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/dbus-launch"
  printf '#!/bin/sh\necho "$@" >"$HOME/tod_called"\n' >"$PREFIX/bin/tod"
  chmod +x "$PREFIX/bin/dbus-launch" "$PREFIX/bin/tod"
  PATH="$PREFIX/bin:$PATH"
  session_xstartup >/dev/null 2>&1
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [[ -f $HOME/tod_called ]] && break; sleep 0.2; done
  eq "arresto completo dopo l'uscita" stop "$(cat "$HOME/tod_called" 2>/dev/null)"
}

test_phantom_restore_defaults() {
  cat >"$PREFIX/bin/adb" <<'EOF'
#!/bin/bash
echo "$*" >>"$HOME/adb_calls"
case "$*" in
  *"settings get global settings_enable_monitor_phantom_procs") printf 'null\r\n' ;;
  *"device_config get activity_manager max_phantom_processes") printf 'null\r\n' ;;
esac
exit 0
EOF
  chmod +x "$PREFIX/bin/adb"
  PATH="$PREFIX/bin:$PATH"
  ADB_SERIAL=127.0.0.1:37999
  phantom_unapply
  phantom_verify_default
  has "monitor rimesso come di fabbrica" "settings delete global settings_enable_monitor_phantom_procs" "$(cat "$HOME/adb_calls")"
  has "limite dei processi rimesso" "device_config delete activity_manager max_phantom_processes" "$(cat "$HOME/adb_calls")"
  has "ottimizzazione batteria rimessa" "deviceidle whitelist -com.termux" "$(cat "$HOME/adb_calls")"
}

test_uninstall_package_list_and_safety() {
  mkdir -p "$PREFIX/var/log"
  cat >"$PREFIX/var/log/dpkg.log" <<'EOF'
2026-10-11 18:20:00 install unzip:aarch64 <none> 6.0-9
2026-10-11 18:34:47 install x11-repo:all <none> 8.4-1
2026-10-11 18:35:00 upgrade bash:aarch64 5.2-1 5.3-1
2026-10-11 18:39:00 install xfce4:all <none> 4.20
2026-10-11 18:40:00 install rimosso:aarch64 <none> 1.0
EOF
  pkg_installed() { [[ $1 != rimosso ]]; }
  eq "da Termux On DeX in poi" $'x11-repo\nxfce4' "$(tod_installed_packages '2026-10-11 18:34:33')"
  eq "tutti (Termux come nuovo)" $'unzip\nx11-repo\nxfce4' "$(tod_installed_packages '')"
  # prova generale che toccherebbe un pacchetto vitale: la rimozione si blocca
  apt-mark() { :; }
  apt-get() { if [[ $1 == -s ]]; then printf 'Purg xfce4 [4.20]\nPurg bash [5.3-1]\n'; fi; }
  apt_run() { echo "NON DOVEVA ARRIVARE QUI" >"$HOME/removed"; }
  conf_set UNINSTALL_SINCE '2026-10-11 18:34:33'
  fails uninstall_packages
  eq "niente rimosso" no "$([[ -e $HOME/removed ]] && echo si || echo no)"
}

test_uninstall_packages_success() {
  mkdir -p "$PREFIX/var/log"
  printf '%s\n' "2026-10-11 18:34:47 install x11-repo:all <none> 8.4-1" \
    "2026-10-11 18:39:00 install xfce4:all <none> 4.20" >"$PREFIX/var/log/dpkg.log"
  pkg_installed() { return 0; }
  apt-mark() { echo "apt-mark $*" >>"$HOME/calls"; }
  apt-get() { if [[ $1 == -s ]]; then printf 'Purg xfce4 [4.20]\nPurg x11-repo [8.4-1]\n'; fi; }
  apt_run() { echo "apt $*" >>"$HOME/calls"; }
  conf_set UNINSTALL_SINCE '2026-10-11 18:34:33'
  uninstall_packages
  has "segnati come automatici" "apt-mark auto x11-repo xfce4" "$(cat "$HOME/calls")"
  has "tolti solo quelli che non servono ad altro" "autoremove --purge" "$(cat "$HOME/calls")"
}

_fake_pulse() { # PulseAudio finto con moduli veri (stato su file)
  local st="$HOME/pulse_state"
  mkdir -p "$st"
  printf '0\tmodule-aaudio-sink\t\n1\tmodule-suspend-on-idle\t\n' >"$st/modules"
  cat >"$PREFIX/bin/pulseaudio" <<'EOF'
#!/bin/bash
st="$HOME/pulse_state"
echo "pulseaudio $* XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}" >>"$st/calls"
case $1 in
  --check) [[ -f $st/running && ${XDG_RUNTIME_DIR:-} == "$TMPDIR" ]] ;;
  --start) touch "$st/running"; rm -f "$st/broken"; printf '0\tmodule-native-protocol-unix\t\n' >"$st/modules" ;;
  --kill) rm -f "$st/running" ;;
esac
EOF
  cat >"$PREFIX/bin/pactl" <<'EOF'
#!/bin/bash
st="$HOME/pulse_state"
echo "pactl $* PULSE_SERVER=${PULSE_SERVER:-}" >>"$st/calls"
what="$1"; [[ $1 == list && ${2:-} == short ]] && what="list ${3:-}"
case $what in
  info) [[ -f $st/running ]] ;;
  "list modules") cat "$st/modules" ;;
  "list sinks")
    if grep -q module-aaudio-sink "$st/modules"; then printf '0\tAAudio_sink\tmodule-aaudio-sink.c\n'; fi
    if grep -q module-sles-sink "$st/modules"; then printf '1\tOpenSL_ES_sink\tmodule-sles-sink.c\n'; fi ;;
  "list sink-inputs") : ;;
  load-module)
    # demone "rotto" (visto su Android 17): le uscite verso Android vengono rifiutate
    if [[ -f $st/broken && $2 =~ ^module-(aaudio|sles)-sink$ ]]; then echo "Failure: Module initialization failed" >&2; exit 1; fi
    n=$(( $(wc -l <"$st/modules") + 5 )); printf '%s\t%s\t\n' "$n" "$2" >>"$st/modules"; echo "$n" ;;
  unload-module) awk -v id="$2" '$1 != id' "$st/modules" >"$st/m2" && mv "$st/m2" "$st/modules" ;;
  set-default-sink) echo "$2" >"$st/default" ;;
esac
EOF
  chmod +x "$PREFIX/bin/pulseaudio" "$PREFIX/bin/pactl"
  PATH="$PREFIX/bin:$PATH"
}

test_audio_start_and_ensure() {
  _fake_pulse
  local st="$HOME/pulse_state"
  audio_start
  has "demone nella cartella della sessione" "pulseaudio --start --exit-idle-time=-1 XDG_RUNTIME_DIR=$TMPDIR" "$(cat "$st/calls")"
  has "modulo TCP per il container" "module-native-protocol-tcp" "$(cat "$st/modules")"
  hasnt "niente sospensione dell'uscita" "module-suspend-on-idle" "$(cat "$st/modules")"
  eq "uscita predefinita" AAudio_sink "$(cat "$st/default")"
  has "pactl parla al socket del desktop" "PULSE_SERVER=unix:$TMPDIR/pulse/native" "$(cat "$st/calls")"
  # scelta di OpenSL ES
  conf_set AUDIO_SINK sles
  audio_ensure
  hasnt "AAudio tolto" "module-aaudio-sink" "$(cat "$st/modules")"
  has "OpenSL ES caricato" "module-sles-sink" "$(cat "$st/modules")"
  eq "uscita OpenSL ES" OpenSL_ES_sink "$(cat "$st/default")"
  # nessuna uscita: si prova prima AAudio
  conf_set AUDIO_SINK auto
  printf '0\tmodule-native-protocol-tcp\t\n' >"$st/modules"
  audio_ensure
  has "uscita creata" "module-aaudio-sink" "$(cat "$st/modules")"
  # il TCP non viene caricato due volte
  eq "un solo modulo TCP" 1 "$(grep -c module-native-protocol-tcp "$st/modules")"
}

test_session_uses_audio_socket() {
  _fake_pulse
  printf '#!/bin/sh\necho "$PULSE_SERVER" >"$HOME/pulse_env"\n' >"$PREFIX/bin/dbus-launch"
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/bin/tod"
  chmod +x "$PREFIX/bin/dbus-launch" "$PREFIX/bin/tod"
  session_xstartup >/dev/null 2>&1
  eq "le app del desktop usano il socket giusto" "unix:$TMPDIR/pulse/native" "$(cat "$HOME/pulse_env")"
}

# --- CLI end-to-end (processo separato, come sul telefono) ----------------------
test_cli_smoke() {
  local out rc=0
  out=$(bash "$ROOT/tod" version)
  has "version" "Termux On DeX" "$out"
  has "help" "install" "$(bash "$ROOT/tod" help)"
  bash "$ROOT/tod" comando-inesistente >/dev/null 2>&1 || rc=$?
  eq "comando ignoto → 2" 2 "$rc"
  has "status" "Desktop" "$(bash "$ROOT/tod" status)"
  has "install --help" "--no-container" "$(bash "$ROOT/tod" install --help)"
  bash "$ROOT/tod" tweak vsync off >/dev/null
  has "tweak scrive il profilo" "vblank_mode=0" "$(cat "$HOME/.config/tod/gpu.env")"
  has "doctor" "GPU" "$(bash "$ROOT/tod" doctor 2>&1)"
  has "gpu status" "stack=official" "$(bash "$ROOT/tod" gpu status)"
  has "x11 status" "Termux:X11" "$(bash "$ROOT/tod" x11 status)"
  hasnt "niente giochi nella guida" "game add" "$(bash "$ROOT/tod" help)"
  has "guida: aspetto e lingua" "aspetto [tema|accento|puntatore]" "$(bash "$ROOT/tod" help)"
  rc=0
  bash "$ROOT/tod" gpu use profilo-finto >/dev/null 2>&1 || rc=$?
  eq "profilo inesistente rifiutato" 1 "$rc"
  rc=0
  bash "$ROOT/tod" start >/dev/null 2>&1 || rc=$?
  eq "start senza installazione" 1 "$rc"
}

test_xsync_wait() { # xfwm4: conferma del ridisegno data da tod, al massimo ~25 cambi di misura al secondo
  local cc
  cc=$(command -v clang || command -v gcc) || { echo "  (nessun compilatore: salto)"; return 0; }
  "$cc" -shared -fPIC -O2 -Wall -Werror -o "$WORK/tx_$$.so" "$ROOT/share/tod-gettext.c" -ldl
  eq "intercetta la richiesta di ridisegno" 1 "$(grep -ac "XSendEvent" "$WORK/tx_$$.so" | sed 's/^[1-9][0-9]*$/1/')"
  has "solo dentro xfwm4" 'strcmp(n, "xfwm4")' "$(cat "$ROOT/share/tod-gettext.c")"
  has "conferma con il contatore della finestra" "XSyncSetCounter" "$(cat "$ROOT/share/tod-gettext.c")"
  has "conferma quando l'app ha disegnato davvero (DAMAGE)" "XDamageCreate" "$(cat "$ROOT/share/tod-gettext.c")"
  has "mai sopra una conferma vera dell'app" "if (cur < a->value)" "$(cat "$ROOT/share/tod-gettext.c")"
  has "si può spegnere" "TOD_XSYNC_CLASSICO" "$(cat "$ROOT/share/tod-gettext.c")"
}

test_resize_edges() { # cornice da 1 px elegante, ma si ridimensiona senza mirare (bordi invisibili)
  python3 -c "import ast; ast.parse(open('$ROOT/share/tod-edges.py').read())"
  has "avviato dalla sessione" "share/tod-edges.py" "$(cat "$ROOT/lib/session.sh")"
  has "zone che non disegnano" "InputOnly" "$(cat "$ROOT/share/tod-edges.py")"
  has "il ridimensionamento lo fa xfwm4" "_NET_WM_MOVERESIZE" "$(cat "$ROOT/share/tod-edges.py")"
  has "mai sopra la barra delle app" "_NET_WORKAREA" "$(cat "$ROOT/share/tod-edges.py")"
  has "xfwm4 accetta la presa del mouse (ora aggiornata)" "_TOD_EDGES_TIME" "$(cat "$ROOT/share/tod-edges.py")"
  has "bordo da una riga" 'save(f"left-{sfx}", B, S(8)' "$(cat "$ROOT/share/dexos/dexos-theme.py")"
  has "angoli in basso larghi (sennò l'arrotondamento in alto sparisce)" "cw = R + S(10)" "$(cat "$ROOT/share/dexos/dexos-theme.py")"
  has "niente striscia in alto" "frame_border_top -n -t int -s 0" "$(cat "$ROOT/lib/look.sh")"
}

# =============================================================================
pass=0 fail=0 failed=()
for fn in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${FILTER}" || true); do
  out=$( ( set -Eeuo pipefail; fresh_env "$fn"; "$fn" ) 2>&1 )
  rc=$?
  if [[ $rc == 0 ]]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$fn"
    if [[ -n $out ]]; then printf '%s\n' "$out"; fi
  else
    fail=$((fail + 1))
    failed+=("$fn")
    printf 'FAIL %s (rc=%s)\n%s\n' "$fn" "$rc" "$out"
  fi
done
printf '\n%d superati, %d falliti\n' "$pass" "$fail"
if ((fail)); then printf '  - %s\n' "${failed[@]}"; exit 1; fi
