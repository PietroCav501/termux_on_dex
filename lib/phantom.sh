# shellcheck shell=bash
# =============================================================================
#  "[Process completed (signal 9)]": il Phantom Process Killer di Android 12+
#
#  Due strade:
#   1) Opzioni sviluppatore → "Disattiva restrizioni processi figlio"
#      (Disable child process restrictions, Android 14+)
#   2) ADB wireless dal telefono stesso (android-tools in Termux), che applica
#      anche le impostazioni di sistema e toglie Termux dall'ottimizzazione batteria
#  Con DeX è comodissimo: Impostazioni e Termux affiancati in due finestre.
# =============================================================================

ADB_SERIAL=""

dev_settings_open() { am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS >/dev/null 2>&1 || true; }

adb_local_device() { # dispositivo locale già connesso, se c'è
  adb devices 2>/dev/null | awk '$2 == "device" && $1 ~ /^(127\.0\.0\.1|localhost):[0-9]+$/ {print $1}' | sed -n 1p
}

adb_try_mdns() { # porta di connessione scoperta via mDNS → "127.0.0.1:porta"
  local port out
  port=$(adb mdns services 2>/dev/null | awk '/_adb-tls-connect/ {n = split($NF, a, ":"); print a[n]}' | sed -n 1p) || port=""
  [[ $port =~ ^[0-9]+$ ]] || return 1
  out=$(timeout 6 adb connect "127.0.0.1:$port" 2>&1) || true
  grep -qi 'connected to' <<<"$out" || return 1
  printf '127.0.0.1:%s' "$port"
}

ph_port_from() { # "192.168.1.5:41235", " 41235 " → 41235
  local v=${1//[[:space:]]/}
  v=${v##*:}
  if [[ $v =~ ^[0-9]{2,5}$ ]]; then printf '%s' "$v"; else return 1; fi
}

ph_code_from() { # "123 456" → 123456
  local v=${1//[[:space:]-]/}
  if [[ $v =~ ^[0-9]{6}$ ]]; then printf '%s' "$v"; else return 1; fi
}

adb_scan_ports() { # porte TCP aperte su 127.0.0.1 (adbd ne sceglie una a caso tra le effimere)
  if ! have nmap; then pkg_install nmap >/dev/null 2>&1 || return 1; fi
  nmap -Pn -sT -T4 --open -p 32768-60999 127.0.0.1 -oG - 2>/dev/null | grep -o '[0-9][0-9]*/open' | cut -d/ -f1
}

adb_find_connect_port() { # adb_find_connect_port [porta da saltare] → "127.0.0.1:porta"
  local p out i
  # appena associato, adb si collega da solo (mDNS): qualche secondo d'attesa costa meno della scansione
  for ((i = 0; i < 8; i++)); do
    if p=$(adb_local_device) && [[ -n $p ]]; then printf '%s' "$p"; return 0; fi
    if p=$(adb_try_mdns); then printf '%s' "$p"; return 0; fi
    sleep 1
  done
  log "adb: niente collegamento automatico, cerco la porta"
  for p in $(adb_scan_ports); do
    if [[ $p == "${1:-}" ]]; then continue; fi
    out=$(timeout 3 adb connect "127.0.0.1:$p" 2>&1) || true
    if grep -qi 'connected to' <<<"$out"; then printf '127.0.0.1:%s' "$p"; return 0; fi
  done
  return 1
}

adb_connect_local() {
  local s pp code cp out tries=0
  if ! have adb; then run_step "android-tools" pkg_install android-tools || return 1; fi
  adb start-server >/dev/null 2>&1 || true
  s=$(adb_local_device) || s=""
  if [[ -n $s ]]; then ADB_SERIAL=$s; return 0; fi
  dev_settings_open
  ui_msg "$(t ph_adb_title)" "$(t ph_adb_steps)"
  sleep 1
  # già associato in passato? Solo mDNS, che è passivo: niente "adb connect" a tappeto
  # qui, perché toccare la porta di associazione col popup aperto la fa fallire
  if s=$(adb_try_mdns); then ADB_SERIAL=$s; return 0; fi
  while true; do
    tries=$((tries + 1))
    pp=$(ui_input "$(t ph_adb_title)" "$(t ph_pair_port)") || return 1
    code=$(ui_input "$(t ph_adb_title)" "$(t ph_pair_code)") || return 1
    if pp=$(ph_port_from "$pp") && code=$(ph_code_from "$code"); then
      # attenzione: adb pair può stampare "Failed" ed uscire comunque con 0
      out=$(timeout 25 adb pair "127.0.0.1:$pp" "$code" 2>&1) || true
      log "adb pair: $out"
      if grep -qi 'successfully paired' <<<"$out"; then ok "$(t ph_paired)"; break; fi
      ui_msg "$(t ph_adb_title)" "$(t ph_pair_failed "$out")"
    else
      ui_msg "$(t ph_adb_title)" "$(t ph_bad_input)"
    fi
    if (( tries >= 3 )); then return 1; fi
  done
  if s=$(adb_find_connect_port "$pp"); then ADB_SERIAL=$s; return 0; fi
  # ultima risorsa: la porta la scrive l'utente
  cp=$(ui_input "$(t ph_adb_title)" "$(t ph_conn_port)") || return 1
  cp=$(ph_port_from "$cp") || { err "$(t ph_bad_input)"; return 1; }
  out=$(timeout 10 adb connect "127.0.0.1:$cp" 2>&1) || true
  if ! grep -qi 'connected to' <<<"$out"; then err "$out"; return 1; fi
  ADB_SERIAL="127.0.0.1:$cp"
}

phantom_apply() {
  local -a sh=(priv_sh)
  local p
  "${sh[@]}" /system/bin/device_config set_sync_disabled_for_tests persistent || true
  "${sh[@]}" /system/bin/device_config put activity_manager max_phantom_processes 2147483647 || return 1
  "${sh[@]}" settings put global settings_enable_monitor_phantom_procs false || return 1
  for p in com.termux com.termux.x11; do
    # niente Doze/limiti in background per Termux e Termux:X11
    "${sh[@]}" cmd deviceidle whitelist "+$p" >/dev/null 2>&1 ||
      "${sh[@]}" dumpsys deviceidle whitelist "+$p" >/dev/null 2>&1 || true
    "${sh[@]}" cmd appops set "$p" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
  done
}

phantom_verify() {
  local a b
  a=$(priv_sh settings get global settings_enable_monitor_phantom_procs 2>/dev/null | tr -d '\r') || a=""
  b=$(priv_sh /system/bin/device_config get activity_manager max_phantom_processes 2>/dev/null | tr -d '\r') || b=""
  log "phantom: monitor=$a max=$b"
  PH_MONITOR=$a PH_MAX=$b
  [[ $a == false && $b == 2147483647 ]]
}

phantom_fix() {
  local m
  m=$(ui_menu "$(t ph_title)" "$(t ph_intro)" adb \
    adb "$(t ph_m_adb)" toggle "$(t ph_m_toggle)" skip "$(t ph_m_skip)") || m=skip
  case $m in
    adb)
      # un Annulla premuto per sbaglio, un codice scaduto, Blocco automatico acceso: si riprova finché
      # l'utente non sceglie un'altra strada (mai avanti da soli dopo un fallimento)
      while ! { { priv_ready || adb_connect_local; } && phantom_apply && phantom_verify; }; do
        warn "$(t ph_ko)"
        m=$(ui_menu "$(t ph_title)" "$(t ph_fail_text)" retry \
          retry "$(t ph_m_retry)" toggle "$(t ph_m_toggle)" skip "$(t ph_m_skip)") || m=retry
        case $m in
          retry) continue ;;
          toggle)
            dev_settings_open
            ui_msg "$(t ph_title)" "$(t ph_toggle_steps)"
            conf_set PHANTOM_FIX toggle
            return 0 ;;
          *) warn "$(t ph_skipped)"; return 1 ;;
        esac
      done
      ok "$(t ph_ok)"
      conf_set PHANTOM_FIX adb
      ui_msg "$(t ph_title)" "$(t ph_done_text)"
      ;;
    toggle)
      dev_settings_open
      ui_msg "$(t ph_title)" "$(t ph_toggle_steps)"
      conf_set PHANTOM_FIX toggle
      ;;
    *) warn "$(t ph_skipped)" ;;
  esac
}

phantom_unapply() { # come le imposta Android di fabbrica
  local -a sh=(priv_sh)
  local p
  "${sh[@]}" settings delete global settings_enable_monitor_phantom_procs >/dev/null 2>&1 || true
  "${sh[@]}" /system/bin/device_config delete activity_manager max_phantom_processes >/dev/null 2>&1 || true
  "${sh[@]}" /system/bin/device_config set_sync_disabled_for_tests none >/dev/null 2>&1 || true
  for p in com.termux com.termux.x11; do
    "${sh[@]}" cmd deviceidle whitelist "-$p" >/dev/null 2>&1 ||
      "${sh[@]}" dumpsys deviceidle whitelist "-$p" >/dev/null 2>&1 || true
    "${sh[@]}" cmd appops set "$p" RUN_ANY_IN_BACKGROUND default >/dev/null 2>&1 || true
  done
}

phantom_verify_default() {
  local a b
  a=$(priv_sh settings get global settings_enable_monitor_phantom_procs 2>/dev/null | tr -d '\r') || a=""
  b=$(priv_sh /system/bin/device_config get activity_manager max_phantom_processes 2>/dev/null | tr -d '\r') || b=""
  log "phantom (ripristino): monitor=$a max=$b"
  [[ $a != false && $b != 2147483647 ]]
}

phantom_restore() { # per il disinstallatore: 0 = ripristinato (o non serviva)
  local m
  m=$(ui_menu "$(t ph_title)" "$(t ph_restore_intro)" adb \
    adb "$(t ph_m_adb)" toggle "$(t ph_m_toggle)" skip "$(t ph_m_skip_restore)") || m=skip
  case $m in
    adb)
      if { priv_ready || adb_connect_local; } && phantom_unapply && phantom_verify_default; then
        ok "$(t ph_restored)"
        adb disconnect "$ADB_SERIAL" >/dev/null 2>&1 || true
        adb kill-server >/dev/null 2>&1 || true
        return 0
      fi
      warn "$(t ph_ko)"
      dev_settings_open
      ui_msg "$(t ph_title)" "$(t ph_restore_toggle_steps)"
      return 1
      ;;
    toggle)
      dev_settings_open
      ui_msg "$(t ph_title)" "$(t ph_restore_toggle_steps)"
      return 0
      ;;
    *) return 1 ;;
  esac
}

phantom_status() { # per "tod doctor": verifica reale se c'è Shizuku o ADB già connesso
  if priv_ready; then
    if phantom_verify; then echo "OK (adb: monitor=$PH_MONITOR, max=$PH_MAX)"; else echo "KO (adb: monitor=$PH_MONITOR, max=$PH_MAX)"; fi
  else
    echo "$(conf_get PHANTOM_FIX "$(t ph_unknown)")"
  fi
}
