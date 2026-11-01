# shellcheck shell=bash
# =============================================================================
#  Accelerazione grafica
#
#  Due "stack" di driver lato Termux:
#    official → mesa + Turnip (mesa-vulkan-icd-freedreno) dei repository Termux
#    lfdevs   → mesa con backend Freedreno-KGSL (OpenGL nativo su Adreno, senza
#               Zink) dai pacchetti di lfdevs/termux-packages, bloccati con apt-mark
#  Profili (variabili d'ambiente) provati in ordine, il primo che funziona vince:
#    kgsl > zink-turnip > zink-turnip-sw > zink-wrapper > virgl > llvmpipe
#  Il test è reale (glxinfo su un server X vero), quindi gestisce da solo casi
#  come le Adreno 840 "v2" che Turnip non riconosce (VK_ERROR_INCOMPATIBLE_DRIVER).
# =============================================================================

declare -gA GPU_RANK=([kgsl]=1 [zink-turnip]=2 [zink-turnip-sw]=3 [zink-wrapper]=4 [virgl]=5 [llvmpipe]=9)

LFDEVS_TERMUX_REPO=lfdevs/termux-packages
LFDEVS_CX_REPO=lfdevs/mesa-for-android-container
# Release di riserva se l'API GitHub non risponde (checksum dalle note di rilascio)
LFDEVS_TERMUX_FALLBACK_TAG=freedreno-26.2.0-devel-20260709
declare -gA LFDEVS_TERMUX_FALLBACK=(
  [mesa_26.2.0-1_aarch64.deb]=5adfa7b3000bdce3ff660afb40e069e95508b0ab5c54c29dd9732111a548cfeb
  [mesa-vulkan-icd-freedreno_26.2.0-1_aarch64.deb]=f22d1258f28d71f38ce4e39e67f251565f1f1df57ccb4c046698e6e853aa5aca
)
LFDEVS_CX_FALLBACK_TAG=mesa-26.2.0-devel-20260709
declare -gA LFDEVS_CX_FALLBACK=(
  [debian_trixie_arm64]=4ee525b4844fb189f3762ff75ef77f5b80eee8f6cdab2e5588731b5c9f8168bb
  [ubuntu_noble_arm64]=89adc0d7b7eaa26e619cd6c41114894c152fa1680d0ff1969947e94e151f660f
  [ubuntu_questing_arm64]=344dffe6f06ccf8cf67f7f679a697eb55be47a79a09e369a42f36cbac24e39a0
  [ubuntu_resolute_arm64]=ed98eaeb85c1f84288759ddcc6936730a2ecd6c76d6a870b3a474797b2c68fad
)

TOD_GPU_PROBE="$TOD_STATE_DIR/gpu-probe.txt"

# variabili che un profilo può impostare: vanno tolte prima di provarne un altro,
# altrimenti (es. lanciando "tod gpu probe" dal terminale del desktop) si mescolano
GPU_VARS=(MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER VK_ICD_FILENAMES VK_DRIVER_FILES TU_DEBUG
  MESA_VK_WSI_DEBUG MESA_GL_VERSION_OVERRIDE MESA_GLSL_VERSION_OVERRIDE LIBGL_ALWAYS_SOFTWARE
  TOD_NEEDS_VIRGL TOD_GPU_PROFILE vblank_mode MESA_VK_WSI_PRESENT_MODE)

gpu_env_reset() { unset "${GPU_VARS[@]}"; }

gpu_unset_args() { # → argomenti "-u VAR" per env(1)
  local v
  for v in "${GPU_VARS[@]}"; do printf -- '-u\n%s\n' "$v"; done
}

gpu_stack() { cat "$TOD_STATE_DIR/gpu-stack" 2>/dev/null || echo official; }
gpu_set_stack() { echo "$1" >"$TOD_STATE_DIR/gpu-stack"; }

gpu_icd() { # gpu_icd schema → percorso del JSON ICD Vulkan (es. freedreno, wrapper)
  local f
  for f in "$PREFIX"/share/vulkan/icd.d/*"$1"*.json; do
    if [[ -f $f ]]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# gpu_profile_env profilo → righe VAR=valore (l'ICD è fissato: con più driver
# installati Zink potrebbe altrimenti scegliere lavapipe o il driver sbagliato)
gpu_profile_env() {
  local icd
  case $1 in
    kgsl)
      echo MESA_LOADER_DRIVER_OVERRIDE=kgsl
      ;;
    zink-turnip | zink-turnip-sw)
      icd=$(gpu_icd freedreno) || return 1
      printf '%s\n' MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink \
        "VK_ICD_FILENAMES=$icd" "VK_DRIVER_FILES=$icd" TU_DEBUG=noconform
      if [[ $1 == zink-turnip-sw ]]; then echo MESA_VK_WSI_DEBUG=sw; fi
      ;;
    zink-wrapper) # Zink sopra il driver Vulkan proprietario di Android
      icd=$(gpu_icd wrapper) || return 1
      printf '%s\n' MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink "VK_ICD_FILENAMES=$icd" "VK_DRIVER_FILES=$icd"
      ;;
    virgl) # OpenGL tramite virgl_test_server_android (GLES di sistema): va su qualsiasi GPU
      printf '%s\n' GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.0 MESA_GLSL_VERSION_OVERRIDE=400 TOD_NEEDS_VIRGL=1
      ;;
    llvmpipe)
      printf '%s\n' GALLIUM_DRIVER=llvmpipe LIBGL_ALWAYS_SOFTWARE=1
      ;;
    *) return 1 ;;
  esac
}

gpu_env_export() { # carica il profilo attivo nell'ambiente corrente
  gpu_env_reset
  [[ -f $TOD_GPU_ENV ]] || return 0
  set -a
  # shellcheck source=/dev/null
  . "$TOD_GPU_ENV"
  set +a
}

gpu_write_env() { # gpu_write_env profilo
  local p=$1 spec
  spec=$(gpu_profile_env "$p") || return 1
  {
    echo "# Generato da Termux On DeX $TOD_VERSION - profilo GPU: $p ($(date '+%F %T'))"
    echo "# Cambia con: tod gpu use <profilo>  |  nuovo test: tod gpu probe"
    echo "TOD_GPU_PROFILE=$p"
    printf '%s\n' "$spec"
    case $(conf_get VSYNC on) in
      off) echo "vblank_mode=0" ;;
      tearfree) printf '%s\n' "vblank_mode=3" "MESA_VK_WSI_PRESENT_MODE=mailbox" ;;
    esac
  } >"$TOD_GPU_ENV"
  conf_set GPU_PROFILE "$p"
}

# ----------------------------------------------------------------------------
#  virgl (server lato Termux, usato anche dal container come ripiego)
# ----------------------------------------------------------------------------
virgl_running() { pgrep -f virgl_test_server >/dev/null 2>&1; }

virgl_start() {
  have virgl_test_server_android || return 1
  if virgl_running; then return 0; fi
  nohup virgl_test_server_android >"$TOD_STATE_DIR/virgl.log" 2>&1 </dev/null &
  sleep 1
  virgl_running
}

virgl_stop() { pkill -f virgl_test_server 2>/dev/null || true; }

# ----------------------------------------------------------------------------
#  Installazione degli stack
# ----------------------------------------------------------------------------
gpu_install_base() {
  pkg_install mesa mesa-demos || return 1
  pkg_install_avail vulkan-tools vulkan-loader-generic virglrenderer-android glmark2 || true
  if [[ $GPU_FAMILY == adreno ]]; then pkg_install_avail mesa-vulkan-icd-freedreno || true; fi
}

gpu_install_lfdevs() { # Freedreno-KGSL per Termux nativo
  have jq || pkg_install jq || return 1
  local dir="$TOD_CACHE_DIR/lfdevs-termux" rel tag rx line url sha name
  local -a debs=()
  mkdir -p "$dir"
  if rel=$(gh_release "$LFDEVS_TERMUX_REPO" freedreno-); then
    tag=$(jq -r .tag_name <<<"$rel")
    for rx in '^mesa_.*_aarch64\.deb$' '^mesa-vulkan-icd-freedreno_.*_aarch64\.deb$'; do
      line=$(gh_asset "$rel" "$rx")
      if [[ -z $line ]]; then err "$(t gpu_asset_missing "$rx" "$tag")"; return 1; fi
      IFS='|' read -r url sha name <<<"$line"
      if [[ -z $sha ]]; then sha=$(gh_body_sha "$rel" "$name"); fi
      net_download "$url" "$dir/$name" "$sha" || return 1
      debs+=("$dir/$name")
    done
  else
    tag=$LFDEVS_TERMUX_FALLBACK_TAG
    warn "$(t gh_fallback "$tag")"
    for name in "${!LFDEVS_TERMUX_FALLBACK[@]}"; do
      net_download "https://github.com/$LFDEVS_TERMUX_REPO/releases/download/$tag/$name" \
        "$dir/$name" "${LFDEVS_TERMUX_FALLBACK[$name]}" || return 1
      debs+=("$dir/$name")
    done
  fi
  pkg_unhold mesa mesa-vulkan-icd-freedreno
  if ! apt_run "${APT_FLAGS[@]}" install --allow-downgrades --allow-change-held-packages "${debs[@]}"; then
    pkg_fix
    gpu_set_stack lfdevs        # forza il ripristino anche se dpkg si è fermato a metà
    gpu_restore_official || true
    return 1
  fi
  pkg_hold mesa mesa-vulkan-icd-freedreno   # `pkg upgrade` non deve sovrascriverli
  gpu_set_stack lfdevs
  conf_set GPU_LFDEVS_TAG "$tag"
  log "stack lfdevs installato: $tag"
}

gpu_restore_official() { # torna ai driver dei repository Termux
  [[ $(gpu_stack) == lfdevs ]] || return 0
  local v vi
  local -a want=()
  pkg_unhold mesa mesa-vulkan-icd-freedreno
  pkg_refresh || true
  v=$(pkg_repo_version mesa)
  if [[ -n $v ]]; then want+=("mesa=$v"); fi
  if pkg_installed mesa-vulkan-icd-freedreno; then
    vi=$(pkg_repo_version mesa-vulkan-icd-freedreno)
    if [[ -n $vi ]]; then want+=("mesa-vulkan-icd-freedreno=$vi"); fi
  fi
  if ((${#want[@]})); then
    apt_run "${APT_FLAGS[@]}" install --reinstall --allow-downgrades "${want[@]}" || return 1
  fi
  gpu_set_stack official
  log "stack official ripristinato"
}

# ----------------------------------------------------------------------------
#  Test dei profili (richiedono DISPLAY con un server X attivo)
# ----------------------------------------------------------------------------
gpu_vk_ok() { # gpu_vk_ok icd.json → 0 se vulkaninfo trova un dispositivo
  have vulkaninfo || return 0
  local out
  if ! out=$(VK_ICD_FILENAMES=$1 VK_DRIVER_FILES=$1 timeout 20 vulkaninfo --summary 2>&1 </dev/null); then
    log "vulkaninfo KO ($1): $(grep -m1 -Ei 'unsupported|incompatible|error' <<<"$out" || true)"
    return 1
  fi
  grep -q 'deviceName' <<<"$out"
}

gpu_probe_one() { # gpu_probe_one profilo → stampa il renderer OpenGL; 0 = funziona
  local p=$1 spec out renderer icd rc=0
  local -a envs=() clean=()
  spec=$(gpu_profile_env "$p") || return 2
  mapfile -t envs <<<"$spec"
  mapfile -t clean < <(gpu_unset_args)
  case $p in
    zink-*)
      icd=$(sed -n 's/^VK_ICD_FILENAMES=//p' <<<"$spec")
      gpu_vk_ok "$icd" || return 1
      ;;
  esac
  if [[ $p == virgl ]]; then virgl_start || return 1; fi
  if out=$(env "${clean[@]}" "${envs[@]}" timeout 25 glxinfo -B 2>&1 </dev/null); then rc=0; else rc=$?; fi
  if [[ $p == virgl ]]; then virgl_stop; fi
  renderer=$(sed -n 's/^[[:space:]]*OpenGL renderer string:[[:space:]]*//p' <<<"$out" | sed -n 1p)
  log "probe $p: rc=$rc renderer=${renderer:-nessuno}"
  if [[ $rc != 0 || -z $renderer ]]; then
    log "probe $p output: $(tail -n 3 <<<"$out" | tr '\n' ' ')"
    return 1
  fi
  if [[ $p != llvmpipe && ${renderer,,} =~ llvmpipe|softpipe|swrast ]]; then return 1; fi
  if [[ $p == zink-* && ${renderer,,} != *zink* ]]; then return 1; fi
  printf '%s' "$renderer"
}

gpu_bench_one() { # gpu_bench_one profilo → punteggio glmark2 (0 se fallisce)
  local spec out s=""
  local -a envs=() clean=()
  if ! have glmark2 || ! spec=$(gpu_profile_env "$1"); then echo 0; return 0; fi
  mapfile -t envs <<<"$spec"
  mapfile -t clean < <(gpu_unset_args)
  if [[ $1 == virgl ]]; then virgl_start || true; fi
  if out=$(env "${clean[@]}" "${envs[@]}" vblank_mode=0 timeout 150 glmark2 -s 800x600 \
    -b build:use-vbo=true:duration=4 -b texture:texture-filter=mipmap:duration=4 \
    -b shading:shading=phong:duration=4 -b bump:bump-render=high-poly:duration=4 2>&1 </dev/null); then :; fi
  if [[ $1 == virgl ]]; then virgl_stop; fi
  s=$(sed -n 's/.*glmark2 Score:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$out" | sed -n 1p)
  printf '%s' "${s:-0}"
}

# Adreno 8xx (verificato su 840, Galaxy S26 Ultra, Mesa 26.3): con kgsl e con zink-turnip
# Chromium ed Electron lasciano blocchi neri e superfici incomplete (menu, popup,
# ridisegni parziali), anche senza DRI3 e senza UBWC. glmark2 invece è pulito: il
# problema è nelle app con tante superfici. zink con WSI software è pulito.
# Questi profili restano usabili a mano (tod gpu run kgsl -- gioco), non per il desktop.
gpu_glitchy() { # gpu_glitchy profilo → vero se sporca il desktop su questa GPU
  [[ ${GPU_ADRENO:-} =~ ^8[0-9][0-9]$ ]] || return 1
  [[ $1 == kgsl ]] && return 0
  [[ $1 == zink-turnip ]] && ! gpu_glamor
}

# Server X con glamor (X11_GLAMOR=1, Termux:X11 con la composizione sulla GPU): la presentazione Vulkan
# diretta (DRI3) di zink-turnip è pulita anche con Chromium ed Electron (30 ottobre, Adreno 840: nessun
# blocco nero né fotogramma rovinato con menu e popup) ed è molto più fluida della copia software
# (mirino di CADCraft: 42 → 92 aggiornamenti al secondo, ritardo 33 → 17 ms). kgsl non è stato riprovato.
gpu_glamor() { [[ $(conf_get X11_GLAMOR 0) == 1 ]]; }

gpu_rank() { # posizione nella preferenza per il desktop (più basso = meglio)
  if gpu_glitchy "$1"; then
    echo $((${GPU_RANK[$1]:-50} + 20))
  elif [[ ${GPU_ADRENO:-} =~ ^8[0-9][0-9]$ ]] && { { gpu_glamor && [[ $1 == zink-turnip ]]; } ||
    { ! gpu_glamor && [[ $1 == zink-turnip-sw ]]; }; }; then
    echo 0
  else
    echo "${GPU_RANK[$1]:-50}"
  fi
}

gpu_candidates() {
  local -a c=()
  if [[ $GPU_FAMILY == adreno ]]; then
    if [[ $(gpu_stack) == lfdevs ]]; then c+=(kgsl); fi
    if gpu_icd freedreno >/dev/null; then c+=(zink-turnip zink-turnip-sw); fi
  fi
  if gpu_icd wrapper >/dev/null; then c+=(zink-wrapper); fi
  if have virgl_test_server_android; then c+=(virgl); fi
  c+=(llvmpipe)
  printf '%s\n' "${c[@]}"
}

gpu_probe_all() { # [--bench]  → risultati in $TOD_GPU_PROBE (profilo|ok/ko|renderer|punteggio)
  local bench=${1:-} p r s
  local -a cands=()
  mapfile -t cands < <(gpu_candidates)
  if [[ $bench != --bench ]]; then
    # senza benchmark vince il primo che funziona: si provano in ordine di preferenza (gpu_rank), sennò su
    # Adreno 8xx con lo stack lfdevs vinceva sempre kgsl, che sporca il desktop (30 ottobre)
    mapfile -t cands < <(for p in "${cands[@]}"; do printf '%s %s\n' "$(gpu_rank "$p")" "$p"; done |
      sort -s -n -k1,1 | cut -d' ' -f2)
  fi
  : >"$TOD_GPU_PROBE"
  local k=0
  for p in "${cands[@]}"; do
    k=$((k + 1))
    progress_note "$((k * 90 / ${#cands[@]}))" "$(t tui_gpu_test "$p")"
    if r=$(gpu_probe_one "$p"); then
      s=""
      if [[ $bench == --bench && $p != llvmpipe ]]; then s=$(gpu_bench_one "$p"); fi
      printf '%s|ok|%s|%s\n' "$p" "$r" "$s" >>"$TOD_GPU_PROBE"
      # senza benchmark basta il primo che funziona (l'ordine è già per qualità)
      if [[ $bench != --bench ]]; then break; fi
    else
      printf '%s|ko||\n' "$p" >>"$TOD_GPU_PROBE"
    fi
  done
}

gpu_pick_best() { # dal file dei risultati → profilo migliore
  local file=${1:-$TOD_GPU_PROBE} best="" bestrank=99 bestscore=0 p st r s rank
  [[ -f $file ]] || { echo llvmpipe; return 0; }
  while IFS='|' read -r p st r s; do
    [[ -n $p && $st == ok ]] || continue
    rank=$(gpu_rank "$p")
    # col benchmark vince il punteggio; un profilo che sporca il desktop vale il minimo
    if [[ $s =~ ^[0-9]+$ ]] && (( s > 0 )) && gpu_glitchy "$p"; then s=1; fi
    if [[ $s =~ ^[0-9]+$ ]] && (( s > 0 )); then
      if (( s > bestscore )); then best=$p bestscore=$s bestrank=0; fi
    elif (( bestscore == 0 && rank < bestrank )); then
      best=$p bestrank=$rank
    fi
  done <"$file"
  printf '%s' "${best:-llvmpipe}"
}

gpu_score_of() { # gpu_score_of profilo [file] → punteggio registrato (0 se assente)
  local s
  s=$(awk -F'|' -v p="$1" '$1 == p && $2 == "ok" {print $4}' "${2:-$TOD_GPU_PROBE}" 2>/dev/null | sed -n 1p) || s=""
  num "$s"
}

# gpu_setup [--bench] — installa, prova, sceglie. Pensato per run_step (non interattivo).
gpu_setup() {
  local bench=${1:-} best_off best off_file="$TOD_STATE_DIR/gpu-probe.official.txt"
  gpu_install_base || return 1
  if [[ $(gpu_stack) == lfdevs ]]; then gpu_restore_official || true; fi
  x11_with_server gpu_probe_all "$bench" || return 1
  cp -f "$TOD_GPU_PROBE" "$off_file"
  best_off=$(gpu_pick_best "$off_file")
  best=$best_off
  log "gpu: migliore con stack official = $best_off"

  if [[ $GPU_FAMILY == adreno && $(conf_get GPU_EXPERIMENTAL yes) == yes ]]; then
    if gpu_install_lfdevs; then
      : >"$TOD_GPU_PROBE"   # niente decisioni su risultati del test precedente
      if x11_with_server gpu_probe_all "$bench"; then
        best=$(gpu_pick_best)
      else
        warn "$(t gpu_lfdevs_x11)"
        best=llvmpipe        # equivale a "peggiore": si torna ai driver ufficiali
      fi
      log "gpu: migliore con stack lfdevs = $best"
      # resta solo se è strettamente migliore: a parità i driver ufficiali sono più curati
      local worse=0
      if [[ $bench == --bench ]]; then
        if (( $(gpu_score_of "$best") <= $(gpu_score_of "$best_off" "$off_file") )); then worse=1; fi
      elif (( $(gpu_rank "$best") >= $(gpu_rank "$best_off") )); then
        worse=1
      fi
      if (( worse )); then
        log "gpu: lo stack sperimentale non migliora, torno a quello ufficiale"
        gpu_restore_official || return 1
        cp -f "$off_file" "$TOD_GPU_PROBE"
        best=$best_off
      fi
    else
      warn "$(t gpu_lfdevs_fail)"
    fi
  fi

  # Ultima spiaggia prima del software: Zink sul driver Vulkan di Android
  if [[ $best == llvmpipe || $best == virgl ]] && pkg_has vulkan-wrapper-android && ! pkg_installed vulkan-wrapper-android; then
    if apt_run "${APT_FLAGS[@]}" install --no-remove vulkan-wrapper-android; then
      : >"$TOD_GPU_PROBE"
      x11_with_server gpu_probe_all "$bench" || true
      local w; w=$(gpu_pick_best)
      if (( $(gpu_rank "$w") < $(gpu_rank "$best") )); then best=$w; fi
    fi
  fi
  gpu_write_env "$best"
  log "gpu: profilo scelto = $best"
}

gpu_reprobe() { # nuovo test senza reinstallare nulla
  x11_with_server gpu_probe_all "${1:-}" || return 1
  gpu_write_env "$(gpu_pick_best)"
}

gpu_show() {
  local p st r s cur
  cur=$(conf_get GPU_PROFILE "?")
  printf '%s%s%s  stack=%s  %s=%s\n' "$C_BOLD" "$(t gpu_title)" "$C_0" "$(gpu_stack)" "$(t gpu_active)" "$cur"
  if [[ -f $TOD_GPU_PROBE ]]; then
    while IFS='|' read -r p st r s; do
      if [[ $st == ok ]]; then
        printf '  %s✔%s %-15s %s%s\n' "$C_G" "$C_0" "$p" "$r" "${s:+  (glmark2: $s)}"
      else
        printf '  %s✘%s %-15s\n' "$C_R" "$C_0" "$p"
      fi
    done <"$TOD_GPU_PROBE"
  fi
}

gpu_cli() { # tod gpu [status|probe [--bench]|bench|use <profilo>|stack official|lfdevs|run <profilo> -- cmd]
  local sub=${1:-status}
  if (($#)); then shift; fi
  detect_device
  case $sub in
    status | "") gpu_show ;;
    probe) run_step "$(t s_gpu_probe)" gpu_reprobe "${1:-}" && gpu_show ;;
    bench) run_step "$(t s_gpu_bench)" gpu_reprobe --bench && gpu_show ;;
    use)
      local p=${1:-}
      [[ -n $p && -n ${GPU_RANK[$p]:-} ]] || die "$(t gpu_unknown_profile "$p" "${!GPU_RANK[*]}")"
      gpu_write_env "$p" || die "$(t gpu_profile_unavailable "$p")"
      ok "$(t gpu_profile_set "$p")"
      ;;
    stack)
      case ${1:-} in
        official) run_step "$(t s_gpu_official)" gpu_restore_official && run_step "$(t s_gpu_probe)" gpu_reprobe ;;
        lfdevs) run_step "$(t s_gpu_lfdevs)" gpu_install_lfdevs && run_step "$(t s_gpu_probe)" gpu_reprobe ;;
        *) die "tod gpu stack official|lfdevs" ;;
      esac
      gpu_show
      ;;
    run) # tod gpu run <profilo> -- comando...   (un'app con un profilo diverso dal desktop)
      local p=${1:-} spec
      shift || true
      if [[ ${1:-} == -- ]]; then shift; fi
      spec=$(gpu_profile_env "$p") || die "$(t gpu_profile_unavailable "$p")"
      local -a envs=() clean=()
      mapfile -t envs <<<"$spec"
      mapfile -t clean < <(gpu_unset_args)
      if [[ $p == virgl ]]; then virgl_start || true; fi
      exec env "${clean[@]}" "${envs[@]}" "$@"
      ;;
    *) die "tod gpu [status|probe|bench|use <profilo>|stack official|lfdevs|run <profilo> -- cmd]" ;;
  esac
}
