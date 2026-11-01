# Termux On DeX 2

**Italiano** · [English](README.en.md)

Un desktop Linux per telefoni Android, fatto per usare il telefono con Samsung DeX
collegato a un monitor. Non serve il root.

La base è Termux con Termux:X11 e XFCE. Le app che Termux non ha arrivano da un container
Debian, e la grafica usa la GPU del telefono. Il nome viene dal vecchio *Linux on DeX* di
Samsung, che non esiste più.

È ancora una alpha. L'ho provato su un Galaxy S26 Ultra (Snapdragon, GPU Adreno) e su un
Galaxy S20+ (Exynos, GPU Mali); dovrebbe andare su qualsiasi Android 8 o successivo a 64 bit.
Se qualcosa non funziona apri una issue e allega il file che crea `tod doctor`.

## Installazione

Serve Termux scaricato da [GitHub](https://github.com/termux/termux-app/releases) (il file
`...arm64-v8a.apk`): quello del Play Store non va bene. Sui Samsung bisogna spegnere il
Blocco automatico (Impostazioni → Sicurezza e privacy), altrimenti Android non lascia
installare gli APK e non attiva il debug wireless.

Poi in Termux:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/PietroCav501/termux_on_dex/v2/install.sh)
```

Aggiungendo `--yes` in fondo non fa domande e usa le scelte predefinite.

Ci vogliono 30-40 minuti e circa 8 GB liberi. Se l'installazione si interrompe basta
rilanciare lo stesso comando: riprende dal passo in cui si era fermata.

All'inizio viene chiesto di collegare l'ADB wireless del telefono a sé stesso. Serve a
evitare che Android chiuda il desktop ("Process completed (signal 9)") e a installare da
sole Termux:X11 e Termux:API. Il debug wireless funziona solo con il telefono connesso a
una rete Wi-Fi (non mentre fa da hotspot). Si può saltare e farlo dopo con `tod phantom`;
da Android 14 in poi basta anche attivare "Disable child process restrictions" nelle
Opzioni sviluppatore.

## Cosa c'è

- Tema, icone, puntatore e sfondi propri (DeX OS), chiari o scuri, nel colore che scegli.
- Menu Start, barra delle applicazioni con le anteprime delle finestre, pannelli per
  notifiche, volume, calendario, batteria, memoria e rete.
- Impostazioni e aggiornamenti dei pacchetti con una finestra propria.
- Esplora file con le cartelle del telefono: Documenti, Download, Immagini, Musica, Video.
- Chiavette USB, dischi e schede SD in lettura e scrittura (ext4, exFAT, FAT, NTFS), con
  l'espulsione e un programma per formattarli. Senza root: i dischi li legge il kernel
  Linux compilato come libreria ([LKL](https://github.com/lkl/linux)). Dal terminale ci sono
  anche `lsblk`, `fdisk` e `mkfs`.
- Un solo `apt`: `sudo apt install gimp` prende il pacchetto di Termux se c'è, altrimenti
  quello di Debian, e l'app compare nello Start una volta sola.
- Le app Android installate nello Start, che si aprono in una finestra di DeX.
- Batteria, rete e notifiche del telefono nella barra (con Termux:API).
- Desktop in italiano, Firefox e LibreOffice.

XFCE gira direttamente in Termux. Le app di Debian, quando possibile, partono senza proot:
il caricatore di Debian corretto per Android e [fakechroot](https://github.com/dex4er/fakechroot)
bastano a far vedere all'app i file del container, e la grafica va circa al doppio della
velocità. Le app che così non partono tornano su proot da sole; `tod diretto off` spegne
questa modalità.

Con Termux da GitHub l'installazione mette una Termux:X11 modificata, che compone le
finestre con la GPU (glamor). Le modifiche e gli script per ricompilarla sono in `x11/`;
l'APK e i sorgenti completi sono nelle release.

## Limiti

- GPU Mali (Exynos, MediaTek): OpenGL passa da virgl, ma per Vulkan non c'è un driver
  accelerato senza root e le app Vulkan girano sul processore. Sulle Adreno c'è Turnip.
- La prima volta che colleghi una chiavetta Android chiede il permesso.
- La rete la gestisce Android: per cambiare Wi-Fi si aprono le sue impostazioni dal
  pannello. Il nome della rete si vede solo con la Posizione accesa.
- Sotto carico il telefono si scalda e rallenta da solo. In DeX conviene tenerlo in
  carica e al fresco.

## Comandi

Per l'uso normale non servono:

```
tod start | stop | restart | status   il desktop
tod doctor                            diagnosi (salva anche Download/tod-doctor.txt)
tod prestazioni                       processore, memoria e calore per un minuto
tod update                            aggiorna Termux On DeX
tod menu                              centro di controllo
tod gpu [status|probe|bench]          accelerazione grafica
tod display [auto|<dpi>]              grandezza di testo e icone
tod phantom                           collega ADB per il "signal 9"
tod cx pkexec off                     le app di Debian non chiedono più la password di amministratore
tod telefono [aggiorna|spento|acceso] le app del telefono nello Start
tod uninstall                         toglie tutto
```

I registri sono in `~/.local/state/tod/`: `tod.log` per installazione e comandi,
`session.log` per il desktop, `usb.log` per chiavette e schede.

## Sviluppo

```sh
bash tests/run.sh                      # i test, girano su qualsiasi Linux
python3 tests/lint_errexit.py tod install.sh lib/*.sh
```

`tod` e `lib/` sono in bash; le finestre (Start, barra, pannelli, Impostazioni,
installazione, dischi in `share/usb/`) in Python con GTK 3. Il tema DeX OS si genera da
`share/dexos/`.

## Crediti

[Termux](https://termux.dev), [Termux:X11](https://github.com/termux/termux-x11),
[Termux:API](https://github.com/termux/termux-api), [proot-distro](https://github.com/termux/proot-distro),
[fakechroot](https://github.com/dex4er/fakechroot), [LKL](https://github.com/lkl/linux),
[lfdevs](https://github.com/lfdevs) per i pacchetti Mesa Freedreno-KGSL, il progetto Mesa
(Freedreno, Turnip, Zink, virgl), il tema [Fluent](https://github.com/vinceliuice/Fluent-gtk-theme)
da cui parte quello di DeX OS e il carattere [Inter](https://rsms.me/inter/).

## Licenza

[GNU GPL versione 3](LICENSE). I pacchetti scaricati durante l'installazione hanno le loro
licenze.
