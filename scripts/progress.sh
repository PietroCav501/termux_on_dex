#!/data/data/com.termux/files/usr/bin/bash

show_progress() {
  # Crea una directory temporanea
  TMP_DIR=$(mktemp -d)
  PROGRESS_FILE="$TMP_DIR/progress"
  CURRENT_PACKAGE_FILE="$TMP_DIR/current_package"

  # Inizializza il contatore
  echo 0 > "$PROGRESS_FILE"
  echo "" > "$CURRENT_PACKAGE_FILE"

  # Funzione per incrementare il contatore e aggiornare il pacchetto corrente
  increment_progress() {
    local progress
    progress=$(<"$PROGRESS_FILE")
    progress=$((progress + 1))
    echo $progress > "$PROGRESS_FILE"
  }

  # Funzione per aggiornare il pacchetto corrente
  update_current_package() {
    echo "$1" > "$CURRENT_PACKAGE_FILE"
  }

  # Definisci i pacchetti di base e opzionali
  base_packages=(
    "x11-repo"
    "termux-x11-nightly"
    "xfce xfce4-whiskermenu-plugin xfce4-taskmanager"
    "rsync"
    "termux-am"
    "pulseaudio"
    "xwayland"
    "wget"
    "tsu"
    "root-repo"
    "patchelf"
    "xorg-xrandr"
    "ncurses-utils"
    "hashdeep"
    "git git-lfs"
    "which"
  )
  
  optional_packages=()
  
  [[ $INSTALL_MARIADB == "ON" ]] && optional_packages+=("mariadb")
  [[ $INSTALL_MOUSEPAD == "ON" ]] && optional_packages+=("mousepad")
  [[ $INSTALL_GEDIT == "ON" ]] && optional_packages+=("gedit")
  [[ $INSTALL_SYNAPTIC == "ON" ]] && optional_packages+=("synaptic")
  [[ $INSTALL_OPENJDK == "ON" ]] && optional_packages+=("openjdk-17")
  [[ $INSTALL_CHROMIUM == "ON" ]] && optional_packages+=("tur-repo" "chromium")
  [[ $INSTALL_FIREFOX == "ON" ]] && optional_packages+=("firefox")
  [[ $INSTALL_GIMP == "ON" ]] && optional_packages+=("gimp")
  [[ $INSTALL_RISTRETTO == "ON" ]] && optional_packages+=("ristretto")
  [[ $INSTALL_CODE_OSS == "ON" ]] && optional_packages+=("tur-repo" "code-oss")
  

  # Calcola il numero totale di passi
  total_steps=$(( ${#base_packages[@]} + ${#optional_packages[@]} +1 ))
  # Avvia i comandi di installazione in background
  (
    for package in "${base_packages[@]}"; do
      update_current_package "$package"
      pkg install -y $package &> output.log && increment_progress
    done
    update_current_package "xdf-utils" && increment_progress
    pkg install xdg-utils -y &> output.log <<EOF
yes
lib
EOF
    for package in "${optional_packages[@]}"; do
      update_current_package "$package"
      pkg install -y $package &> output.log && increment_progress
    done
  ) &
  
  # Prendi il PID del processo in background
  BG_PID=$!
  
  # Mostra la barra di avanzamento
  while kill -0 $BG_PID 2>/dev/null; do
    progress=$(<"$PROGRESS_FILE")
    current_package=$(<"$CURRENT_PACKAGE_FILE")
    percent=$(( progress * 100 / total_steps ))
    echo $percent
    echo "XXX"
    echo "$p_text $progress/$total_steps: $current_package"
    echo "XXX"
    sleep 0.5
  done | dialog --gauge "$wait" 10 70 0

  # Rimuovi il file temporaneo e la directory
  rm -rf "$TMP_DIR"
}
