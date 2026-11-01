# shellcheck shell=bash
# =============================================================================
#  Shizuku: i permessi di ADB (utente "shell") sempre a disposizione, senza
#  rifare l'abbinamento del Debug wireless a ogni volta. tod lo usa con "rish",
#  la shell di Shizuku per i terminali; senza Shizuku ripiega su ADB.
#  Serve a: blocco del "signal 9" (phantom), log di Android, tod doctor.
#  rish chiama /system/bin/app_process: funziona solo in Termux, non nel proot.
# =============================================================================

SHIZUKU_PKG=moe.shizuku.privileged.api

shizuku_dir() { printf '%s' "$PREFIX/libexec/tod-rish"; }

shizuku_apk() { # un APK di Shizuku da cui prendere rish (installato, o la copia scaricata)
  # da Android 11 Termux non "vede" le altre app: pm path spesso non trova Shizuku anche se c'è
  local p f
  p=$(pm path "$SHIZUKU_PKG" 2>/dev/null | sed -n 's/^package://p' | sed -n 1p) || p=""
  if [[ -n $p && -r $p ]]; then printf '%s' "$p"; return 0; fi
  for f in "$(files_termux_home)"/.cache/tod/shizuku/*.apk "$(files_termux_home)"/Download/shizuku/*.apk \
    "$FILES_PHONE"/Download/shizuku*.apk; do
    if [[ -f $f ]]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

shizuku_installed_dir() { # cartella dell'app installata, chiesta ad Android come utente "shell" (ADB)
  local p
  p=$(adb -s "$ADB_SERIAL" shell pm path "$SHIZUKU_PKG" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | sed -n 1p) || p=""
  if [[ -n $p ]]; then printf '%s' "${p%/base.apk}"; return 0; fi
  return 1
}

shizuku_rish_install() { # rish + rish_shizuku.dex dall'APK di Shizuku → $PREFIX/bin/rish
  local apk d
  apk=$(shizuku_apk) || return 1
  d=$(shizuku_dir)
  mkdir -p "$d"
  rm -f "$d/rish_shizuku.dex"
  unzip -p "$apk" assets/rish_shizuku.dex >"$d/rish_shizuku.dex" || return 1
  chmod 400 "$d/rish_shizuku.dex"   # da Android 14 app_process rifiuta i dex scrivibili
  unzip -p "$apk" assets/rish | sed 's/RISH_APPLICATION_ID="PKG"/RISH_APPLICATION_ID="com.termux"/' >"$d/rish" || return 1
  chmod 755 "$d/rish"
  ln -sfn "$d/rish" "$PREFIX/bin/rish"
  log "shizuku: rish installato da $apk"
}

SHIZUKU_OK=""

shizuku_ready() { # Shizuku attivo e Termux autorizzato (risultato ricordato per questo processo)
  if [[ -z $SHIZUKU_OK ]]; then
    SHIZUKU_OK=no
    if [[ -x $PREFIX/bin/rish ]] && [[ $(timeout 8 rish -c 'echo tod-ok' 2>/dev/null | tr -d '\r') == tod-ok ]]; then
      SHIZUKU_OK=yes
    fi
  fi
  [[ $SHIZUKU_OK == yes ]]
}

shizuku_start_via_adb() { # avvia il servizio di Shizuku con ADB già collegato (dopo un riavvio del telefono)
  local dir
  dir=$(shizuku_installed_dir) || return 1
  adb -s "$ADB_SERIAL" shell "$dir/lib/arm64/libshizuku.so" >>"$TOD_LOG" 2>&1
}

priv_sh() { # priv_sh comando argomenti... → eseguito come utente "shell" (Shizuku, sennò ADB)
  if shizuku_ready; then
    rish -c "$(printf '%q ' "$@")"
  else
    adb -s "$ADB_SERIAL" shell "$@"
  fi
}

priv_ready() { # c'è un modo per i comandi da ADB? (Shizuku, o ADB locale già collegato)
  local s
  if shizuku_ready; then return 0; fi
  if have adb; then s=$(adb_local_device) || s=""; else s=""; fi
  if [[ -n $s ]]; then ADB_SERIAL=$s; return 0; fi
  return 1
}

apk_install_auto() { # apk_install_auto file.apk → installata senza tocchi, se ADB è collegato
  # In due tempi (copia, poi pm install) e non "adb install": sui Samsung l'installazione a flusso
  # via ADB senza fili restava appesa in silenzio (S20+, 17 ottobre). La shell di Android non legge la
  # cartella di Termux: il file va copiato in /data/local/tmp.
  local out wait=${TOD_ADB_INSTALL_WAIT:-120} dst=/data/local/tmp/tod-install.apk
  have adb || return 1
  ADB_SERIAL=$(adb_local_device) || ADB_SERIAL=""
  [[ -n $ADB_SERIAL ]] || return 1
  out=$(timeout "$wait" adb -s "$ADB_SERIAL" push "$1" "$dst" 2>&1) || { log "adb push ${1##*/}: non riuscito: $out"; return 1; }
  log "adb push ${1##*/}: $(tail -n 1 <<<"$out")"
  # Play Protect controlla le app installate via ADB ("Verifica app tramite USB") e sul S20+ restava
  # appeso senza mostrare niente: spento solo per questa installazione, poi rimesso com'era
  local ver
  ver=$(timeout 20 adb -s "$ADB_SERIAL" shell settings get global verifier_verify_adb_installs 2>/dev/null | tr -d '\r') || ver=""
  if [[ $ver != 0 ]]; then timeout 20 adb -s "$ADB_SERIAL" shell settings put global verifier_verify_adb_installs 0 >/dev/null 2>&1 || true; fi
  out=$(timeout "$wait" adb -s "$ADB_SERIAL" shell pm install -r "$dst" 2>&1) || true
  log "adb pm install ${1##*/}: ${out:-nessuna risposta (tempo scaduto)} (verifica ADB: ${ver:-?}, rimessa)"
  if [[ $ver == null || -z $ver ]]; then
    timeout 20 adb -s "$ADB_SERIAL" shell settings delete global verifier_verify_adb_installs >/dev/null 2>&1 || true
  elif [[ $ver != 0 ]]; then
    timeout 20 adb -s "$ADB_SERIAL" shell settings put global verifier_verify_adb_installs "$ver" >/dev/null 2>&1 || true
  fi
  timeout 20 adb -s "$ADB_SERIAL" shell rm -f "$dst" >/dev/null 2>&1 || true
  grep -q '^Success' <<<"$out"
}

shizuku_status() {
  if [[ ! -x $PREFIX/bin/rish ]]; then
    if shizuku_apk >/dev/null; then t sz_no_rish; else t sz_missing; fi
    return 0
  fi
  if shizuku_ready; then t sz_ok; else t sz_not_running; fi
}

shizuku_cli() { # tod shizuku [stato|configura]
  case ${1:-stato} in
    stato | status) info "Shizuku: $(shizuku_status)" ;;
    configura | setup)
      shizuku_apk >/dev/null || die "$(t sz_missing)"
      shizuku_rish_install || die "$(t sz_rish_fail)"
      SHIZUKU_OK=""
      if ! shizuku_ready && priv_ready && [[ -n ${ADB_SERIAL:-} ]]; then shizuku_start_via_adb || true; SHIZUKU_OK=""; fi
      if shizuku_ready; then ok "$(t sz_ok)"; else warn "$(t sz_allow)"; fi
      ;;
    *) die "tod shizuku stato|configura" ;;
  esac
}
