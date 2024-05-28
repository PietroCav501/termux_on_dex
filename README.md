# Termux On Dex

## Panoramica

L'ambiente desktop Linux Termux On Dex funziona direttamente su Android, senza bisogno di root. Il nome deriva dal progetto fallito di Samsung – Linux On Dex. Sebbene sia stato testato su dispositivi compatibili con DeX di Samsung, può essere utilizzato su qualsiasi dispositivo Android. Questo progetto è una combinazione di un desktop Termux nativo e di un proot che sono mescolati insieme per far sembrare il tutto nativo.

## Caratteristiche

- Esperienza completa del terminale Linux
- Accesso a un ampio repository di pacchetti Linux
- Capacità di eseguire script, codice e software Linux (aarch64 e arm64)
- Supporto per `apt-get` per installare pacchetti da repository Termux e proot.
  Ad esempio:
 ```sh
   apt-get install libreoffice
```
  Quando si utilizza `apt-get` il pacchetto verrà prima cercato all'interno dei repository di termux e se non viene trovato all'interno dei repository del proot

## Requisiti

- Dispositivo Android (preferibilmente con supporto Samsung DeX per un'esperienza ottimale)
- [Termux](https://termux.com)
- [Termux-X11](https://github.com/termux/termux-x11)

## Installazione

1. **Installa Termux:**
   Scarica e installa Termux da [F-Droid](https://f-droid.org/en/packages/com.termux/) o dal [sito web di Termux](https://termux.com).

2. **Installa Termux-X11:**
   Scarica e installa Termux da [github](https://github.com/termux/termux-x11) l'ultima versione disponibile.

3. **Configura l'Ambiente Termux:**
   Apri Termux e inserisci:
   ```
   pkg install wget -y ; wget https://raw.githubusercontent.com/PietroCav501/termux_on_dex/main/install ; bash install 
    ```

4. **Procedere con l'installazione guidata:**
    
## Utilizzo
Apri l'app Termux e inserisci 
```
termux_on_dex 
```

## ATTENZIONE
Seppur vero che è possibile utilizzare il sistema Linux sui dispositivi Android senza effettuare il root, ci sono alcune limitazioni. 
Non è eseguire alcun software ad eccezione di quelli conformi all'architettura arm64/armv8/aarch64. 

Non è possibile la compilazione di grandi quantità di codice come la creazione di un'applicazione Android, o la compilazione di kernel.

Non è possibile utilizzare gli strumenti di hacking/cracking, ad esempio per l'hacking Wi-Fi ecc.

I pacchetti SNAP/Docker/Flatpak non possono essere installati in nessun ambiente Linux. Il motivo principale è che entrambi richiedono moduli del kernel e del bus non disponibili nell'ambiente PRoot. Il secondo è che entrambi sono principalmente incentrati sulle architetture basate su Intel/AMD e non sull'architettura ARM.
