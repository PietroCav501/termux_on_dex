# shellcheck shell=bash
# =============================================================================
#  Dischi USB (share/usb), dall'installazione. Senza root Android non dà a
#  Termux i dischi a blocchi: li legge tod-lkl, il codice di Linux come
#  libreria (LKL), dal dispositivo che termux-usb passa già aperto. I programmi
#  del desktop vedono le partizioni in /media/usb (tod-fs.so). USB_DISCHI=0 li
#  spegne del tutto.
#
#  I file compilati (liblkl.so, tod-lkl, tod-disco.so, tod-fs.so e le versioni
#  -glibc per il container) si scaricano dalla release lkl-$LKL_VERSIONE del
#  progetto, con l'impronta qui sotto; se non si può, si compilano qui
#  (share/usb/lkl/costruisci.sh, ~2 GB di sorgenti, 8-10 minuti).
#  share/usb/lkl/pacchetto.sh prepara un archivio nuovo e aggiorna queste righe.
# =============================================================================

# nmap (ncat: comandi a tod-lkl), util-linux (flock: un solo servizio), libusb (tod-lkl), termux-api (termux-usb),
# e gli strumenti dei dischi di ogni distribuzione (fdisk, mkfs, fsck: Dischi e il terminale)
USB_PKGS="nmap util-linux libusb termux-api fdisk dosfstools exfatprogs e2fsprogs"
LKL_VERSIONE=2
LKL_SHA256=a4b0706dc7fc995933ab22a8befd795bf8a624fb1dc416543a2e4b47427e89f6
# TOD_LKL_URL: un'altra fonte per le prove prima di pubblicare (l'impronta vale lo stesso)
LKL_URL=${TOD_LKL_URL:-"https://github.com/PietroCav501/termux_on_dex/releases/download/lkl-$LKL_VERSIONE/tod-lkl-aarch64.tar.xz"}
LKL_FILE="liblkl.so tod-lkl tod-disco.so tod-fs.so tod-disco-glibc.so tod-fs-glibc.so"

usb_on() { [[ $(conf_get USB_DISCHI 1) == 1 ]]; }

usb_data() { printf '%s/.local/share/tod-usb' "${TOD_TERMUX_HOME:-$HOME}"; }

usb_lkl_ok() { # ci sono tutti i file, della versione giusta
  local d f
  d=$(usb_data)
  for f in $LKL_FILE; do [[ -s $d/$f ]] || return 1; done
  [[ $(cat "$d/lkl-versione" 2>/dev/null) == "$LKL_VERSIONE" ]]
}

usb_lkl_scarica() { # l'archivio della release, controllato con l'impronta scritta qui
  local d a t
  d=$(usb_data)
  a="$TOD_CACHE_DIR/tod-lkl-$LKL_VERSIONE.tar.xz"
  # già accanto al progetto (un archivio portato a mano, prima della release): si usa quello, se l'impronta torna
  if [[ ! -f $a && -f $TOD_ROOT/dist/tod-lkl-aarch64.tar.xz ]] && sha256_ok "$TOD_ROOT/dist/tod-lkl-aarch64.tar.xz" "$LKL_SHA256"; then
    mkdir -p "$TOD_CACHE_DIR"
    cp -f "$TOD_ROOT/dist/tod-lkl-aarch64.tar.xz" "$a"
  fi
  net_download "$LKL_URL" "$a" "$LKL_SHA256" || return 1
  t=$(mktemp -d "$d.XXXXXX") || return 1
  if ! tar -xJf "$a" -C "$t"; then rm -rf "$t"; return 1; fi
  local f
  for f in $LKL_FILE; do [[ -s $t/$f ]] || { rm -rf "$t"; return 1; }; done
  mkdir -p "$d"
  for f in $LKL_FILE; do mv -f "$t/$f" "$d/$f"; done
  rm -rf "$t"
  echo "$LKL_VERSIONE" >"$d/lkl-versione"
}

usb_lkl_compila() { # come ripiego: dai sorgenti, qui
  progress_note - "$(t usb_compila)"
  bash "$TOD_ROOT/share/usb/lkl/costruisci.sh" || return 1
  echo "$LKL_VERSIONE" >"$(usb_data)/lkl-versione"
}

usb_install() { # passo dell'installazione: pacchetti, tod-lkl e librerie, i dischi in Esplora file
  usb_on || return 0
  # shellcheck disable=SC2086
  pkg_install $USB_PKGS || return 1
  if ! usb_lkl_ok; then
    usb_lkl_scarica || { warn "$(t usb_scarica_no)"; usb_lkl_compila; } || return 1
  fi
  # NTFS (formattare, controllare): Termux non ha ntfs-3g, il container sì (share/bin/tod-disco)
  if cx_installed && ! cx_pkg_installed ntfs-3g; then cx_pkg_install ntfs-3g || warn "ntfs-3g"; fi
  # i dischi in Esplora file: i file per GIO ci devono essere già al primo avvio del desktop (Esplora
  # file li legge solo quando parte, e il servizio parte dopo di lui)
  bash "$TOD_ROOT/share/usb/tod-usb" monitor
  desktop_dischi_entry
  usb_togli_macchina
}

usb_togli_macchina() { # una volta: la vecchia macchina dei dischi (QEMU, fino al 21 ottobre 2026)
  local d
  d=$(usb_data)
  rm -f "$d/disco.img" "$d/vmlinuz" "$d/initramfs" "$d/chiave" "$d/chiave.pub" \
    "$d/preparata" "$d/pacchetti" "$d/versione" "$PREFIX/lib/tod-libusb-android.so"
  rm -rf "$d/stato"   # l'istantanea della macchina: memoria, disco e firma
  rm -f "$TOD_STATE_DIR"/usb-installa.*
  # Dischi di GNOME (il nostro è share/tod-dischi.py) e il suo finto udisks2, nel container
  local p
  local -a via=()
  if cx_installed; then
    for p in gnome-disk-utility tod-udisks2; do if cx_pkg_installed "$p"; then via+=("$p"); fi; done
    if ((${#via[@]})); then
      cx_root "${via[@]}" <<<'TOD_MENU_SYNC=0 DEBIAN_FRONTEND=noninteractive apt-get remove -y -q "$@"' >/dev/null 2>&1 || true
    fi
  fi
  via=()
  for p in qemu-system-aarch64-headless qemu-utils qemu-common; do if pkg_installed "$p"; then via+=("$p"); fi; done
  if ((${#via[@]})); then apt-get remove -y "${via[@]}" >/dev/null 2>&1 || true; fi
  return 0
}

usb_cli() { # tod usb [prepara|stato]
  case ${1:-stato} in
    prepara | install) usb_install ;;
    stato | status) bash "$TOD_ROOT/share/usb/tod-usb" stato ;;
    *) die "tod usb prepara|stato" ;;
  esac
}
