#!/data/data/com.termux/files/usr/bin/bash

# Funzione per mostrare la schermata di benvenuto
show_welcome() {
  dialog --title "$w_title" --ok-label "$next" --msgbox "$w_text" 10 40
}