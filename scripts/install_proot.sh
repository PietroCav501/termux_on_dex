#!/data/data/com.termux/files/usr/bin/bash

pass=toor

show_prot_progress() {
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


  # Calcola il numero totale di passi
  optional_packages=()
  #[[ $INSTALL_GEDIT == "ON" ]] && optional_packages+=("gedit")
  [[ $INSTALL_LIBREOFFICE == "ON" ]] && optional_packages+=("libreoffice" "libreoffice-gtk3")
  total_steps=$(( 12 + ${#optional_packages[@]} ))

  # Avvia i comandi di installazione in background
  (
    
    setup_distro && increment_progress
    basic_task && increment_progress
    create_app_installer && increment_progress
    for package in "${optional_packages[@]}"; do
      #update_current_package "$package" && increment_progress
      #debian install $package -y &> output.log
      
      # Avvia il comando in background
	debian install $package -y &> output.log &
	pkg_pid=$!
	increment_progress
	(
	  	while kill -0 $pkg_pid 2>/dev/null; do
	    		if [ -s output.log ]; then
	      			while IFS= read -r line; do
					update_current_package "$line"
	      			done < output.log
	    		fi
	    		sleep 0.5 
	  	done
	)&

	wait $pkg_pid  
      
    done
    
    cat <<'EOF' > /data/data/com.termux/files/home/.bashrc
function cd {
	if [ "$1" == '/' ]; then
		builtin cd /data/data/com.termux/files
	else
		builtin cd "$@"
	fi
}

function apt-get {
	output=$(apt "$@" 2>&1 | tee /dev/tty)
	if echo $output | grep -q "Unable to locate package";then
		debian "$@"
	fi
}

EOF

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
    echo "$current_package"
    echo "XXX"
    sleep 0.5
  done | dialog --gauge "$wait" 10 70 0

  # Rimuovi il file temporaneo e la directory
  rm -rf "$TMP_DIR"
}

function package_install() {
	packs_list=($@)
	for package_name in "${packs_list[@]}"; do
        update_current_package "Installazione in corso di: $package_name" && increment_progress
        pkg install "$package_name" -y &> output.log
	    if [ $? -ne 0 ]; then
        apt --fix-broken install -y &> output.log
	    dpkg --Configuring -a &> output.log
    fi
done

}

function setup_distro() {
    DISTRO="debian"
    
    update_current_package "pkg update" && increment_progress
    pkg update -y -o Dpkg::Options::="--force-confold" &> output.log
    update_current_package "pkg upgrade" && increment_progress
    pkg upgrade -y -o Dpkg::Options::="--force-confold" &> output.log
    package_install "proot-distro"
    update_current_package "Installazione in corso di: $DISTRO" && increment_progress
    pd install $DISTRO &> output.log

    distro_path="$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO"
}



function basic_task() {
    update_current_package "apt update" && increment_progress
    proot-distro login $DISTRO --shared-tmp -- env DISPLAY=:0 apt update &> output.log
    
    echo "export PULSE_SERVER=127.0.0.1" >> "$distro_path/etc/profile"
    cat <<EOF > "$HOME/.${DISTRO}-sound-access"
pulseaudio --start --exit-idle-time=-1
pacmd load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1
EOF
    # Esegui il comando e redirigi l'output a output.log
    #update_current_package "Installazione in corso di: pulseaudio" && increment_progress
    #proot-distro login $DISTRO --shared-tmp -- env DISPLAY=:0 apt install sudo pulseaudio -y &> output.log
    
    update_current_package "Installazione in corso di: pulseaudio"
    proot-distro login $DISTRO --shared-tmp -- env DISPLAY=:0 apt install sudo pulseaudio -y &> output.log &
    pkg_pid=$!
    increment_progress
    (
	  while kill -0 $pkg_pid 2>/dev/null; do
	    	if [ -s output.log ]; then
	      		while IFS= read -r line; do
				update_current_package "$line"
	      		done < output.log
	    	fi
	    	sleep 0.5 
	  done
    )&

    wait $pkg_pid  

    #update_current_package "Installazione in corso di: pulseaudio" && increment_progress
    #proot-distro login $DISTRO --shared-tmp -- env DISPLAY=:0 apt install sudo pulseaudio -y &>/dev/null
    

    
    USERNAME="root"
        cat <<EOF > $HOME/useradd.sh
#!/bin/bash
useradd -m -s \$(which bash) ${USERNAME}
echo "${USERNAME}:${pass}" | chpasswd
chmod u+rw /etc/sudoers
echo "$USERNAME ALL=(ALL:ALL) ALL" >> /etc/sudoers
chmod u-w /etc/sudoers
rm useradd.sh
EOF
        proot-distro login $DISTRO -- /bin/sh -c 'mv /data/data/com.termux/files/home/useradd.sh $HOME'
        update_current_package "Configurazione utente" && increment_progress
        proot-distro login $DISTRO -- /bin/sh -c 'bash useradd.sh' &> output.log

}

function create_app_installer() {
    update_current_package "Fase preliminare" && increment_progress
    save_root_path="$distro_path/root"

    cat <<TOP_EOF > "$PREFIX/bin/$DISTRO"
#!/data/data/com.termux/files/usr/bin/bash

if [[ "\$#" -eq 0 ]]; then
    proot-distro login --user $USERNAME $DISTRO --shared-tmp

elif [[ "\$1" = "install" ]]; then
proot-distro login --user $USERNAME $DISTRO --shared-tmp -- env DISPLAY=:0 sudo apt install \${@:2}
cat <<EOF > "$save_root_path/packinstall.sh"
packages=(\${@:2})
EOF
cat <<'EOF' >> "$save_root_path/packinstall.sh"
for package_name in "\${packages[@]}"; do
desktop_files=\$(dpkg-query -W -f='\${binary:Package}\n' | grep "^\$package_name\(-.*\)\?\$" | xargs dpkg-query -L | grep "^/usr/share/applications/.*\.desktop\$")
if [ -z "\$desktop_files" ]; then
    echo " No .desktop files found for package '\$package_name' in/usr/share/applications."
else
    for desktop_files_name in \$desktop_files; do
        desktop_files_with_ext=\$(basename "\$desktop_files_name")
        sudo cp "/usr/share/applications/\${desktop_files_with_ext}" "/data/data/com.termux/files/usr/share/applications/"
        #sudo sed -i 's/Exec=/Exec=pdrun /g' "/data/data/com.termux/files/usr/share/applications/\${desktop_files_with_ext}"
        
        
        cat <<INS_EOF > "$PREFIX/bin/\$package_name"
#!/data/data/com.termux/files/usr/bin/bash
bash ~/.debian-sound-access
xhost +
proot-distro login --user $USERNAME $DISTRO --shared-tmp -- env DISPLAY=:0 $selected_pd_hw_method \$package_name \\\$@
INS_EOF
        chmod +x "$PREFIX/bin/\$package_name"


    done
    rsync -av --ignore-existing "/usr/share/icons/hicolor/" "/data/data/com.termux/files/usr/share/icons/hicolor/"
	rm /data/data/com.termux/files/usr/share/icons/hicolor/icon-theme.cache
	gtk-update-icon-cache /data/data/com.termux/files/usr/share/icons/hicolor/
fi
done
rm packinstall.sh
EOF
if [ \$? -ne 1 ]; then
    proot-distro login $DISTRO -- /bin/bash -c 'bash packinstall.sh'
else
    rm /data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/debian/root/packinstall.sh
fi
elif [[ "\$1" = "remove" ]] || [[ "\$1" = "remove" ]]; then
cat <<EOF > "$save_root_path/packremove.sh"
packages=(\${@:2})
EOF

cat <<'EOF' >> "$save_root_path/packremove.sh"
for package_name in "\${packages[@]}"; do
desktop_files=\$(dpkg-query -W -f='\${binary:Package}\n' | grep "^\$package_name\(-.*\)\?\$" | xargs dpkg-query -L | grep "^/usr/share/applications/.*\.desktop\$")
if [ -z "\$desktop_files" ]; then
    echo " No .desktop files found for package '\$package_name' in/usr/share/applications."
else
    apt remove \$package_name
    if [ \$? -ne 1 ]; then
        for desktop_files_name in \$desktop_files; do
            desktop_files_with_ext=\$(basename "\$desktop_files_name")
            sudo rm /data/data/com.termux/files/usr/share/applications/\${desktop_files_with_ext}
            sudo rm /data/data/com.termux/files/usr/bin/\${package_name}
        done
    fi
fi
done
rm packremove.sh
EOF
proot-distro login $DISTRO -- /bin/bash -c 'bash packremove.sh'
else
echo "sudo apt \$@
rm else.sh
" > $save_root_path/else.sh
proot-distro login $DISTRO -- /bin/sh -c 'bash else.sh'
fi

TOP_EOF

    chmod +x "$PREFIX/bin/$DISTRO"

    package_install "zenity"

}






