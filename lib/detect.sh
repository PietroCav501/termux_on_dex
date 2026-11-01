# shellcheck shell=bash
# =============================================================================
#  Rilevamento: dispositivo, Android/One UI, GPU, Termux — e controlli iniziali
# =============================================================================

prop() { getprop "$1" 2>/dev/null || true; }

oneui_version() { # "80500" → "8.5"
  local v=${1:-}
  if [[ $v =~ ^[1-9][0-9]{4,5}$ ]]; then printf '%d.%d' $((v / 10000)) $(((v % 10000) / 100)); fi
}

detect_device() {
  local kb
  DEV_BRAND=$(prop ro.product.brand)
  DEV_MODEL=$(prop ro.product.model)
  DEV_NAME=$(prop ro.product.marketname)
  if [[ -z $DEV_NAME ]]; then DEV_NAME=$(prop ro.product.vendor.marketname); fi
  ANDROID_REL=$(prop ro.build.version.release)
  ANDROID_SDK=$(prop ro.build.version.sdk)
  ONEUI_VER=$(oneui_version "$(prop ro.build.version.oneui)")
  SOC_MODEL=$(prop ro.soc.model)
  SOC_MFR=$(prop ro.soc.manufacturer)
  ARCH=$(uname -m)
  KERNEL=$(uname -r)
  kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null) || kb=0
  RAM_MB=$(($(num "$kb") / 1024))
  kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}') || kb=0
  FREE_MB=$(($(num "$kb") / 1024))
  detect_gpu
}

detect_gpu() {
  GPU_EGL=$(prop ro.hardware.egl)
  GPU_VK=$(prop ro.hardware.vulkan)
  GPU_MODEL=""
  if [[ -r /sys/class/kgsl/kgsl-3d0/gpu_model ]]; then
    GPU_MODEL=$(tr -d '\0\n' </sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null) || GPU_MODEL=""
  fi
  gpu_classify "$GPU_MODEL" "$GPU_EGL" "$GPU_VK" "${SOC_MODEL:-}" "${SOC_MFR:-}"
}

# gpu_classify modello egl vulkan soc produttore  (pura, testabile)
# Imposta: GPU_FAMILY (adreno|mali|xclipse|other), GPU_ADRENO (es. 840), GPU_REV, GPU_LABEL
gpu_classify() {
  local model=${1,,} egl=${2,,} vk=${3,,} soc=${4^^} mfr=${5,,}
  GPU_FAMILY=other GPU_ADRENO="" GPU_REV=""
  if [[ $model == adreno* || $egl == adreno* || $vk == adreno* || -e /dev/kgsl-3d0 ]]; then
    GPU_FAMILY=adreno
  elif [[ $egl == mali* || $vk == mali* ]]; then
    GPU_FAMILY=mali
  elif [[ $mfr == samsung* || $soc == S5E* ]]; then
    GPU_FAMILY=xclipse
  fi
  if [[ $GPU_FAMILY == adreno ]]; then
    if [[ $model =~ ([0-9]{3}) ]]; then
      GPU_ADRENO=${BASH_REMATCH[1]}
    else
      case $soc in
        SM8850*) GPU_ADRENO=840 ;; SM8750*) GPU_ADRENO=830 ;; SM8650*) GPU_ADRENO=750 ;;
        SM8550*) GPU_ADRENO=740 ;; SM8475* | SM8450*) GPU_ADRENO=730 ;;
        SM8350*) GPU_ADRENO=660 ;; SM8250*) GPU_ADRENO=650 ;;
      esac
    fi
    if [[ $model =~ v([0-9]+)$ ]]; then GPU_REV=${BASH_REMATCH[1]}; fi
    GPU_LABEL="Adreno ${GPU_ADRENO:-?}${GPU_REV:+ v$GPU_REV}"
  else
    GPU_LABEL="${GPU_FAMILY^}${2:+ ($2)}"
  fi
}

detect_termux() {
  TERMUX_VER=${TERMUX_VERSION:-}
  TERMUX_SRC=${TERMUX_APP__APK_RELEASE:-${TERMUX_APK_RELEASE:-}}
  X11_APK=""
  if X11_APK=$("${TOD_PM:-/system/bin/pm}" path com.termux.x11 2>/dev/null); then
    X11_APK=$(sed -n '1s/^package://p' <<<"$X11_APK")
  else
    X11_APK=""
  fi
}

x11_app_installed() {
  local p=""
  p=$("${TOD_PM:-/system/bin/pm}" path com.termux.x11 2>/dev/null) || p=""
  [[ $p == package:* ]]
}

device_summary() {
  printf '  %-12s %s %s%s\n' "$(t lbl_device)" "${DEV_BRAND^}" "${DEV_NAME:-$DEV_MODEL}" "${DEV_NAME:+ ($DEV_MODEL)}"
  printf '  %-12s Android %s%s · kernel %s\n' "$(t lbl_system)" "$ANDROID_REL" "${ONEUI_VER:+ · One UI $ONEUI_VER}" "$KERNEL"
  printf '  %-12s %s · %s\n' "$(t lbl_soc)" "${SOC_MODEL:-?}" "$GPU_LABEL${GPU_MODEL:+ [$GPU_MODEL]}"
  printf '  %-12s %s MB RAM · %s MB %s\n' "$(t lbl_memory)" "$RAM_MB" "$FREE_MB" "$(t lbl_free)"
  printf '  %-12s %s%s\n' "Termux" "${TERMUX_VER:-?}" "${TERMUX_SRC:+ ($TERMUX_SRC)}"
}

preflight() { # 0 = ok, 1 = errore bloccante
  local fatal=0
  if [[ $PREFIX != */com.termux/files/usr ]]; then err "$(t pf_not_termux)"; fatal=1; fi
  if [[ $(id -u) == 0 ]]; then err "$(t pf_root)"; fatal=1; fi
  if [[ $ARCH != aarch64 ]]; then warn "$(t pf_arch "$ARCH")"; fi
  if [[ $ANDROID_SDK =~ ^[0-9]+$ ]] && (( ANDROID_SDK < 26 )); then err "$(t pf_android)"; fatal=1; fi
  if [[ $TERMUX_SRC == GOOGLE_PLAY_STORE ]]; then warn "$(t pf_playstore)"; fi
  if (( FREE_MB < 1500 )); then err "$(t pf_space "$FREE_MB")"; fatal=1
  elif (( FREE_MB < 4000 )); then warn "$(t pf_space "$FREE_MB")"; fi
  return "$fatal"
}
