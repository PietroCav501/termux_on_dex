#!/data/data/com.termux/files/usr/bin/bash

extract_archive() {
    local archive="$1"
    local destination_directory="$2"

    # Controlla se il file di archivio esiste
    if [ ! -f "$archive" ]; then
        echo "Errore: il file di archivio '$archive' non esiste."
        return 1
    fi

    # Controlla se la directory di destinazione esiste
    if [ ! -d "$destination_directory" ]; then
        echo "La directory di destinazione '$destination_directory' non esiste. Creazione in corso..." > output.log
        mkdir -p "$destination_directory"
        if [ $? -ne 0 ]; then
            echo "Errore: impossibile creare la directory di destinazione '$destination_directory'."
            return 1
        fi
    fi

    # Determina il tipo di archivio e scompatta di conseguenza
    case "$archive" in
        *.tar.gz|*.tgz) tar --overwrite -xzf "$archive" -C "$destination_directory" &> output.log;;
        *.tar.bz2|*.tbz2) tar --overwrite -xjf "$archive" -C "$destination_directory" &> output.log;;
        *.tar.xz|*.txz) tar --overwrite -xJf "$archive" -C "$destination_directory" &> output.log;;
        *.tar) tar --overwrite -xf "$archive" -C "$destination_directory" &> output.log;;
        *.zip) unzip -o "$archive" -d "$destination_directory" &> output.log;;
        *)  
            echo "Errore: formato di archivio non supportato." &> output.log
            return 1
            ;;
    esac

    # Verifica il successo dell'operazione
    if [ $? -eq 0 ]; then
        echo "Archivio scompattato con successo in '$destination_directory'." > output.log
        return 0
    else
        echo "Errore durante l'estrazione dell'archivio."
        return 1
    fi
}

personalize (){
    archive="data/PiXflat2.zip"
    destination_directory="/data/data/com.termux/files/usr/share/themes/"
    extract_archive "$archive" "$destination_directory"
    archive="data/wallpaper.tar.gz"
    destination_directory="/data/data/com.termux/files/usr/share/backgrounds/"
    extract_archive "$archive" "$destination_directory"
    archive="data/wallpaper2.tar.gz"
    extract_archive "$archive" "$destination_directory"
    archive="data/PiXflat.zip"
    destination_directory="/data/data/com.termux/files/home/.icons/"
    extract_archive "$archive" "$destination_directory"
    archive="data/Windows-10-3.2.1.zip"
    destination_directory="/data/data/com.termux/files/home/.themes"
    extract_archive "$archive" "$destination_directory"
    archive="data/xfce4.zip"
    destination_directory="/data/data/com.termux/files/home/.config/xfce4/"
    extract_archive "$archive" "$destination_directory"
    
}

