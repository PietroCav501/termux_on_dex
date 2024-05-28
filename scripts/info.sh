#!/data/data/com.termux/files/usr/bin/bash

show_info(){
FILE="info.txt"

info_text=$(cat "$FILE")
logo=$(cat "$LOGO")

dialog --title "$i_title" --ok-label "$next" --msgbox "$info" 15 60


}
