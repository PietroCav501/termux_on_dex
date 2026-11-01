# shellcheck shell=bash
# =============================================================================
#  Centro di controllo (tod menu): le operazioni di tutti i giorni senza comandi
# =============================================================================

menu_gpu_pick() {
  local -a items=()
  local p st r s cur choice
  cur=$(conf_get GPU_PROFILE llvmpipe)
  if [[ -f $TOD_GPU_PROBE ]]; then
    while IFS='|' read -r p st r s; do
      [[ -n $p ]] || continue
      if [[ $st == ok ]]; then items+=("$p" "✔ ${r:0:48}${s:+ · $s}"); else items+=("$p" "✘ $(t gpu_failed)"); fi
    done <"$TOD_GPU_PROBE"
  fi
  if ((${#items[@]} == 0)); then items=(llvmpipe "software"); fi
  choice=$(ui_menu "GPU" "$(t m_gpu_text "$cur")" "$cur" "${items[@]}") || return 0
  if gpu_write_env "$choice"; then ok "$(t gpu_profile_set "$choice")"; else err "$(t gpu_profile_unavailable "$choice")"; fi
}

menu_main() {
  local c v
  # senza un terminale (es. aperto da un menu che non ne dà uno) il menu a testo si ripeteva da
  # solo all'infinito (14 ottobre: "Avvia il desktop" due volte al secondo): si apre in una finestra
  if [[ ! -t 0 ]]; then
    if [[ -n ${DISPLAY:-} ]] && have xfce4-terminal; then
      exec xfce4-terminal --title "$(t m_title)" -x "$PREFIX/bin/tod" menu
    fi
    return 0
  fi
  detect_device
  while true; do
    c=$(ui_menu "Termux On DeX $TOD_VERSION" "$(t m_text "$(conf_get GPU_PROFILE '?')" "$(conf_get DPI auto)")" start \
      start "$(t m_start)" stop "$(t m_stop)" gpu "$(t m_gpu)" probe "$(t m_probe)" bench "$(t m_bench)" \
      dpi "$(t m_dpi)" vsync "$(t m_vsync)" phantom "$(t m_phantom)" add "$(t m_add)" \
      cx "$(t m_cx)" update "$(t m_update)" doctor "$(t m_doctor)" quit "$(t m_quit)") || return 0
    case $c in
      start) session_start || true ;;
      stop) session_stop || true ;;
      gpu) menu_gpu_pick ;;
      probe) run_step "$(t s_gpu_probe)" gpu_reprobe || true ;;
      bench) run_step "$(t s_gpu_bench)" gpu_reprobe --bench || true; menu_gpu_pick ;;
      dpi)
        v=$(ui_input "DPI" "$(t m_dpi_prompt)" "$(conf_get DPI auto)") || continue
        (display_cli "$v") || true
        ;;
      vsync)
        v=$(ui_menu "VSync" "$(t m_vsync_text)" "$(conf_get VSYNC on)" \
          on "$(t vs_on)" off "$(t vs_off)" tearfree "$(t vs_tearfree)") || continue
        conf_set VSYNC "$v"
        gpu_write_env "$(conf_get GPU_PROFILE llvmpipe)" || true
        ok "$(t m_restart_needed)"
        ;;
      phantom) phantom_fix ;;
      add)
        v=$(ui_input "$(t m_add)" "$(t m_add_prompt)") || continue
        if [[ -n ${v// /} ]]; then
          local -a pk=()
          read -ra pk <<<"$v"
          apps_add "${pk[@]}" || true
        fi
        ;;
      cx) if cx_installed; then cx_run || true; else warn "$(t cx_missing)"; fi ;;
      update) tod_update || true ;;
      doctor) tod_doctor | less -R || true ;;
      quit | *) return 0 ;;
    esac
    if [[ $c != quit && $c != doctor ]]; then read -rp "$(t press_enter) " || return 0; fi
  done
}
