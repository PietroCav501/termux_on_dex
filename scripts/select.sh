#!/data/data/com.termux/files/usr/bin/bash

# Funzione per mostrare la schermata di selezione multipla del software
select_software() {
  SOFTWARE=$(dialog --stdout --separate-output --ok-label "$next" --cancel-label "$undo" --checklist "$s_text" 20 60 15 \
    1 "Mousepad" ON \
    2 "Gedit" OFF \
    3 "Synaptic Package Manager" OFF \
    4 "OpenJDK 17" ON \
    5 "Chromium" ON \
    6 "Firefox" OFF \
    7 "LibreOffice" ON \
    8 "Gimp" OFF \
    9 "Ristretto" ON \
    10 "Code OSS" OFF \
    11 "MariaDB" OFF)

  if [ $? -eq 0 ]; then
    # Imposta le variabili per l'installazione
    INSTALL_MOUSEPAD="OFF"
    INSTALL_GEDIT="OFF"
    INSTALL_SYNAPTIC="OFF"
    INSTALL_OPENJDK="OFF"
    INSTALL_CHROMIUM="OFF"
    INSTALL_FIREFOX="OFF"
    INSTALL_LIBREOFFICE="OFF"
    INSTALL_GIMP="OFF"
    INSTALL_RISTRETTO="OFF"
    INSTALL_CODE_OSS="OFF"
    INSTALL_MARIADB="OFF"

    for SOFTWARE_OPTION in $SOFTWARE; do
      case $SOFTWARE_OPTION in
        1) INSTALL_MOUSEPAD="ON" ;;
        2) INSTALL_GEDIT="OFF" ;;
        3) INSTALL_SYNAPTIC="OFF" ;;
        4) INSTALL_OPENJDK="ON" ;;
        5) INSTALL_CHROMIUM="ON" ;;
        6) INSTALL_FIREFOX="OFF" ;;
        7) INSTALL_LIBREOFFICE="ON" ;;
        8) INSTALL_GIMP="OFF" ;;
        9) INSTALL_RISTRETTO="ON" ;;
        10) INSTALL_CODE_OSS="OFF" ;;
        11) INSTALL_MARIADB="OFF" ;;
      esac
    done
  else
    dialog --msgbox "$aborted" 10 40
    clear
    exit 1
  fi

  clear
}
