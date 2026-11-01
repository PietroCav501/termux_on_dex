# shellcheck shell=bash
# =============================================================================
#  Termux:API: l'app Android che dà al desktop batteria, rete e notifiche del
#  telefono (share/tod-phone-status.py). Va presa dalla stessa fonte di Termux
#  (le firme devono combaciare): con Termux di GitHub, dalla release di GitHub,
#  verificata con il suo checksums-sha256.txt. Poi i permessi: accesso alle
#  notifiche (da Impostazioni), posizione (nome del Wi-Fi) e telefono (rete
#  mobile), che Android chiede da sé alla prima richiesta.
# =============================================================================

TOD_API_APK="$TMPDIR/termux-api.apk"

api_app_installed() {
  "${TOD_PM:-/system/bin/pm}" path com.termux.api >/dev/null 2>&1
}

api_from_github() { [[ ${TERMUX_APP__APK_RELEASE:-${TERMUX_APK_RELEASE:-}} == GITHUB ]]; }

api_app_download() { # l'APK "github" dell'ultima release, controllato con il suo sha256
  local rel url name sums want got
  rel=$(net_get "https://api.github.com/repos/termux/termux-api/releases/latest") || return 1
  url=$(jq -r 'first(.assets[] | select(.name | test("^termux-api-app_.*github.*\\.apk$"))) | .browser_download_url' <<<"$rel")
  [[ -n $url && $url != null ]] || return 1
  name=${url##*/}
  name=${name//%2B/+}
  rm -f "$TOD_API_APK"
  log "Termux:API: scarico $url"
  net_download "$url" "$TOD_API_APK" || return 1
  sums=$(jq -r 'first(.assets[] | select(.name == "checksums-sha256.txt")) | .browser_download_url' <<<"$rel")
  if [[ -n $sums && $sums != null ]]; then
    want=$(net_get "$sums" | awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }') || want=""
    got=$(sha256sum "$TOD_API_APK" | cut -d' ' -f1)
    if [[ -n $want && $want != "$got" ]]; then
      err "$(t api_bad_sum)"
      rm -f "$TOD_API_APK"
      return 1
    fi
  fi
}

api_app_ensure() { # interattivo: non va dentro run_step
  local tries=0
  if ! api_from_github; then   # Termux da F-Droid o Play: Termux:API dalla stessa fonte
    while ! api_app_installed; do
      tries=$((tries + 1))
      if (( tries > 3 )); then warn "$(t api_missing)"; return 1; fi
      ui_msg "$(t api_title)" "$(t api_other_source)"
    done
    ok "$(t api_ok)"
    return 0
  fi
  while ! api_app_installed; do
    tries=$((tries + 1))
    if (( tries > 3 )); then warn "$(t api_missing)"; return 1; fi
    if ! priv_ready; then ui_msg "$(t api_title)" "$(t api_text)"; fi
    if [[ ! -s $TOD_API_APK ]]; then
      run_step "$(t api_dl)" api_app_download || { err "$(t api_dl_fail)"; continue; }
    fi
    # con ADB collegato si installa da sola
    if priv_ready && run_step "$(t apk_auto_run Termux:API)" apk_install_auto "$TOD_API_APK" && api_app_installed; then ok "$(t apk_auto_ok Termux:API)"; break; fi
    if (( tries == 1 )) && priv_ready; then ui_msg "$(t api_title)" "$(t apk_manual_note)"; fi
    if [[ ! -d $HOME/storage/downloads ]]; then termux-setup-storage >/dev/null 2>&1 || true; sleep 4; fi
    if [[ -d $HOME/storage/downloads ]]; then cp -f "$TOD_API_APK" "$HOME/storage/downloads/termux-api.apk" || true; fi
    termux-open "$TOD_API_APK" >/dev/null 2>&1 || true
    ui_msg "$(t api_title)" "$(t api_wait)"
    if ! api_app_installed; then
      am start -a android.intent.action.VIEW_DOWNLOADS >/dev/null 2>&1 || true
      ui_msg "$(t api_title)" "$(t api_manual)"
    fi
  done
  rm -f "$TOD_API_APK"
  ok "$(t api_ok)"
  api_permissions
}

api_permissions() { # interattivo: i permessi che servono al desktop
  if ! have termux-battery-status; then return 0; fi
  # accesso alle notifiche: solo da Impostazioni (Android non lo chiede da sé)
  ui_msg "$(t api_perm_title)" "$(t api_perm_notif)"
  am start -a android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS >/dev/null 2>&1 || true
  ui_msg "$(t api_perm_title)" "$(t api_perm_back)"
  # posizione (nome del Wi-Fi) e telefono (rete mobile): Android li chiede alla prima richiesta
  ui_msg "$(t api_perm_title)" "$(t api_perm_runtime)"
  timeout 30 termux-wifi-connectioninfo >/dev/null 2>&1 || true
  timeout 30 termux-telephony-deviceinfo >/dev/null 2>&1 || true
}
