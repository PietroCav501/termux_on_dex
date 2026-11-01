# Termux:X11 di Termux On DeX (glamor)

`tod` installa questa versione di Termux:X11 al posto della nightly ufficiale, se Termux viene da GitHub
(variante sharedUid). Il file sta nella release `x11-glamor-1` del repository:
`termux-x11-glamor-shareduid.apk`, con accanto l'archivio completo dei sorgenti da cui è compilata
(`termux-x11-glamor-sorgenti.tar.xz`). Con Termux da F-Droid o dal Play Store `tod` resta sulla nightly
ufficiale (variante normale), che funziona come prima ma senza i miglioramenti qui sotto.

## Da cosa parte

- Termux:X11 nightly del 27 ottobre 2026, commit `6dfb8b4` (`termux-x11-universal-sharedUid-debug.apk`,
  SHA-256 `b85caf9ccdf1cc719ca97573761550cbf76de9354f1227f97c435b98df974a7b`).
- X server di freedesktop al commit `65d790bd208ec380b196eb98f144abb0b32e334d` (sottomodulo di Termux:X11).

## Cosa cambia

1. **Composizione con la GPU nel server X (glamor).** L'ufficiale disegna e compone tutto con la CPU (fb/EXA).
   Qui il server usa glamor con OpenGL ES 3 del telefono (EGL senza superficie): finestre, trasparenze,
   ombre del compositore e copie passano dalla GPU. Si accende con `TERMUX_X11_GLAMOR=1` nell'ambiente del
   server (`tod` lo fa con `X11_GLAMOR=1` in `tod.conf`); senza, il server è quello di sempre.
   - `lorie/tod-glamor.c`: contesto EGL, avvio di glamor, radice in un AHardwareBuffer che l'app mostra,
     DRI3 tramite AHardwareBuffer (i buffer dma-buf delle app Vulkan, per esempio Turnip, si copiano in un
     AHardwareBuffer che glamor usa come texture).
   - `InitOutput.c`: scelta tra EXA e glamor, pubblicazione della radice a ogni fotogramma.
2. **Correzioni di glamor per OpenGL ES** (`patch/xserver-glamor.patch`), valide con qualsiasi driver:
   precisione `highp`, formato BGRA in lettura, maschere dei trapezi, maschere A8 in memoria caricate con
   `glTexSubImage2D`, lunghezza di riga sempre impostata, vertici passati con `glBufferData` invece che in un
   buffer mappato senza sincronizzazione.
3. **Lettura dopo un disegno** (`glamor_pixmap.c`): prima di leggere una texture in cui la GPU ha appena
   disegnato, il server legge un pixel di quella texture, così il driver completa il disegno. Senza, su
   Adreno 840 una finestra usciva a volte compressa "a strisce" per un fotogramma (copia del compositore
   sullo schermo, finestra composta subito dopo un ridisegno). 1-3 attese per fotogramma sul desktop.
4. **Mouse e touchpad consegnati subito** (`patch/termux-x11-mouse.smali.patch`, in `MainActivity`):
   `requestUnbufferedDispatch` per i puntatori, non solo per il tocco.

## Come si ricompila

Gli script in `build/` sono quelli usati sul telefono (Termux, clang di Termux, cmake e ninja estratti dai
pacchetti in `~/src/x11-build/strumenti`); i percorsi vanno adattati.

1. Sorgenti di Termux:X11 al commit `6dfb8b4` con i sottomoduli (`sottomoduli.sh`), poi
   `patch -p1 < patch/termux-x11.patch` nella cartella di Termux:X11 e
   `patch -p1 < patch/xserver-glamor.patch` in `lorie/src/main/cpp/xserver`.
2. `epoxy-genera.sh` (sorgenti di libepoxy generati), `compila-server.sh` → `libXlorie.so`,
   `prepara-prove.sh` (toglie i simboli di debug e il RUNPATH: `togli-runpath.py`).
3. `nightly-prepara.sh` e `nightly-applica.sh`: dex della nightly con la correzione del mouse.
4. `apk-glamor.sh`: APK della nightly con il nuovo dex e la nuova `libXlorie.so`, allineata e firmata con
   la chiave pubblica di prova di Termux (`testkey_untrusted`), la stessa di Termux da GitHub: per questo
   può condividere l'UID con Termux.

## Licenza

Termux:X11 è sotto GPL-3.0, l'X server di freedesktop sotto licenza MIT/X11: queste modifiche hanno le stesse
licenze dei file che toccano.
