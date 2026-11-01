#!/usr/bin/env python3
"""Dischi: chiavette, schede SD e dischi USB, come in una normale distribuzione (ma più semplice).

A sinistra i dischi collegati, a destra quello scelto: una barra con le sue partizioni e, sotto, ogni
partizione e ogni spazio libero con le azioni di tutti i giorni: aprire, montare e smontare, rinominare,
formattare (exFAT consigliato), controllare e riparare, eliminare, creare una partizione, inizializzare
il disco ed espellerlo.

I dischi li legge share/usb/lkl/tod-lkl (LKL): qui si leggono i suoi file in
$TMPDIR/tod-usb (lkl-<id>.parti, lkl-<id>.spazio) e si lavora con gli stessi comandi del terminale
(share/bin/tod-disco: fdisk, mkfs, fsck... col disco finto), che smontano e rimontano da soli.
Gira in Termux (PyGObject, GTK 3) con l'ambiente della sessione: `tod-usb dischi`.
"""
import os
import re
import subprocess
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")   # senza, Termux carica Gdk 4 e GTK 3 non parte
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402

GLib.set_prgname("tod-dischi")   # la barra riconosce la finestra (tod-dischi.desktop)

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
TMP = os.environ.get("TMPDIR", os.path.join(PREFIX, "tmp"))
RUN = os.path.join(TMP, "tod-usb")
HERE = os.path.dirname(os.path.abspath(__file__))
DISCO = os.path.join(HERE, "bin/tod-disco")
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "")).startswith("it")
LETTERE = "abcdefghijklmnopqrstuvwxyz"
MIB = 1024 * 1024


def T(it, en):
    return it if ITALIAN else en


# file system che si possono creare: chiave, nome, spiegazione, lunghezza massima del nome, tipo MBR, tipo GPT
FORMATI = [
    ("exfat", "exFAT", T("Consigliato: funziona con Windows, Mac, Linux, TV e fotocamere", "Recommended: works with Windows, Mac, Linux, TVs and cameras"),
     11, "7", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"),
    ("vfat", "FAT32", T("Per i dispositivi più vecchi (file fino a 4 GB)", "For older devices (files up to 4 GB)"),
     11, "c", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"),
    ("ntfs", "NTFS", T("Per i dischi da usare soprattutto con Windows", "For disks used mostly with Windows"),
     32, "7", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"),
    ("ext4", "ext4", T("Per Linux (non si legge da Windows e Mac)", "For Linux (not readable on Windows and Mac)"),
     16, "83", "0FC63DAF-8483-4772-8E79-3D69D8477DE4"),
]
NOMI_FS = {"exfat": "exFAT", "vfat": "FAT", "ntfs": "NTFS", "ext2": "ext2", "ext3": "ext3", "ext4": "ext4",
           "btrfs": "Btrfs", "xfs": "XFS"}
COLORI = {"exfat": (0.04, 0.52, 1.0), "vfat": (0.19, 0.73, 0.30), "ntfs": (0.56, 0.36, 0.97),
          "ext4": (1.0, 0.62, 0.04), "ext3": (1.0, 0.62, 0.04), "ext2": (1.0, 0.62, 0.04),
          "btrfs": (0.19, 0.69, 0.78), "xfs": (1.0, 0.27, 0.23)}
GRIGIO = (0.56, 0.56, 0.58)

CSS = b"""
.side { background-color: alpha(@theme_fg_color, 0.035); border-right: 1px solid alpha(@theme_fg_color, 0.08); }
.side list, .side row { background: transparent; }
.side row { border-radius: 6px; margin: 1px 8px; padding: 6px 6px; }
.side row:selected { background-color: @theme_selected_bg_color; color: @theme_selected_fg_color; }
.pane-title { font-size: 17pt; font-weight: bold; }
.group { background-color: alpha(@theme_fg_color, 0.04); border: 1px solid alpha(@theme_fg_color, 0.08); border-radius: 10px; }
.group-row { padding: 10px 14px; }
.group-sep { background-color: alpha(@theme_fg_color, 0.08); min-height: 1px; }
.group-title { font-weight: bold; opacity: 0.75; margin: 8px 4px 2px 4px; }
.hint { opacity: 0.65; font-size: 9pt; }
.warn { color: #d13438; }
.empty-title { font-size: 15pt; font-weight: bold; }
"""


def misura(b):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if b < 1000 or u == "TB":
            s = f"{b:.1f}" if u != "B" and b < 100 else f"{b:.0f}"
            return (s.replace(".", ",") if ITALIAN else s) + " " + u
        b /= 1000


def tipo_testo(tipo):   # "Chiavetta USB" e "Scheda SD" sono nomi interni (tod-lkl, icone): da mostrare tradotti
    return {"Chiavetta USB": T("Chiavetta USB", "USB stick"), "Scheda SD": T("Scheda SD", "SD card")}.get(tipo, tipo)


# --- i dischi, dai file di tod-lkl ---------------------------------------------------------
def leggi_dischi():
    ids = []
    try:
        for f in os.listdir(RUN):
            m = re.fullmatch(r"lkl-(.+)\.parti", f)
            if m:
                ids.append(m.group(1))
    except OSError:
        return []
    ids.sort(key=lambda i: int(re.sub(r"\D", "", i) or 0))   # come tod-disco: usb2 prima di usb10 (sda, sdb...)
    out = []
    for k, i in enumerate(ids):
        d = {"id": i, "dev": "/dev/sd" + LETTERE[k], "parti": [], "byte": 0, "tipo": "", "prodotto": "", "tabella": "", "ro": False}
        spazio = {}
        try:
            for r in open(os.path.join(RUN, f"lkl-{i}.spazio"), errors="replace").read().splitlines():
                c = r.split("\t")
                if len(c) == 3:
                    spazio[int(c[0])] = (int(c[1]), int(c[2]))
        except (OSError, ValueError):
            pass
        try:
            righe = open(os.path.join(RUN, f"lkl-{i}.parti"), errors="replace").read().splitlines()   # un nome strano non ferma niente
        except OSError:
            continue
        for r in righe:
            c = r.split("\t") + [""] * 8
            try:
                n = int(c[0])
            except ValueError:
                continue
            if n == 0:
                d.update(byte=int(c[2]), tipo=c[3], prodotto=c[4], tabella=c[5], ro=c[6] == "1")
                continue
            nome = "" if c[6] == "-" else c[6]
            d["parti"].append({"n": n, "inizio": int(c[1]), "byte": int(c[2]), "fs": c[3], "etichetta": c[4],
                               "uuid": c[5], "nome": nome, "spazio": spazio.get(n), "dev": f"{d['dev']}{n}"})
        d["parti"].sort(key=lambda p: p["inizio"])
        d["liberi"] = spazi_liberi(d)
        out.append(d)
    return out


def spazi_liberi(d):
    """Gli spazi senza partizione di almeno 8 MB (allineati a 1 MiB, come fdisk). Senza tabella: nessuno."""
    if not d["tabella"] or not d["byte"]:
        return []
    fine_utile = d["byte"] - (MIB if d["tabella"] == "gpt" else 0)   # GPT: la copia della tabella in fondo
    liberi, pos = [], MIB
    for p in d["parti"]:
        if p["inizio"] - pos >= 8 * MIB:
            liberi.append((pos, p["inizio"] - pos))
        pos = max(pos, (p["inizio"] + p["byte"] + MIB - 1) // MIB * MIB)
    if fine_utile - pos >= 8 * MIB:
        liberi.append((pos, (fine_utile - pos) // MIB * MIB))
    return liberi


def ntfs_disponibile():
    for r in ("var/lib/proot-distro/containers/debian/rootfs", "var/lib/proot-distro/installed-rootfs/debian"):
        if os.path.exists(os.path.join(PREFIX, r, "usr/sbin/mkntfs")):
            return True
    return False


def nome_fs(fs):
    return NOMI_FS.get(fs, fs or T("Sconosciuto", "Unknown"))


# --- la finestra --------------------------------------------------------------------------
class Dischi(Gtk.Window):
    def __init__(self, app=None):
        super().__init__(title=T("Dischi", "Disks"), application=app)
        self.set_default_size(900, 600)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_icon_name("drive-removable-media")
        css = Gtk.CssProvider()
        css.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        if app is None:
            self.connect("destroy", Gtk.main_quit)
        self.dischi, self.scelto, self.occupato, self.rinfresco = [], None, False, 0

        outer = Gtk.Box()
        self.add(outer)
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        side.get_style_context().add_class("side")
        side.set_size_request(240, -1)
        outer.pack_start(side, False, False, 0)
        t = Gtk.Label(label=T("Dischi", "Disks"), xalign=0, margin=14)
        t.get_style_context().add_class("group-title")
        side.pack_start(t, False, False, 0)
        self.lista = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.lista.connect("row-selected", self.su_scelta)
        sw = Gtk.ScrolledWindow(vexpand=True)
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.add(self.lista)
        side.pack_start(sw, True, True, 0)

        self.destra = Gtk.ScrolledWindow(hexpand=True)
        self.destra.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        outer.pack_start(self.destra, True, True, 0)

        # i file di tod-lkl cambiano (disco collegato, comando finito): si rilegge, un attimo dopo
        try:
            os.makedirs(RUN, exist_ok=True)
            self.monitor = Gio.File.new_for_path(RUN).monitor_directory(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect("changed", self.su_cambio)
        except GLib.Error:
            self.monitor = None
        self.aggiorna_spazio()
        self.ricarica()
        self.show_all()

    # --- dati ---
    def aggiorna_spazio(self):
        for f in os.listdir(RUN) if os.path.isdir(RUN) else ():
            m = re.fullmatch(r"lkl-(.+)\.ctl", f)
            if m:
                threading.Thread(target=lambda p=os.path.join(RUN, f): _ctl(p, "aggiorna"), daemon=True).start()

    def su_cambio(self, _m, f, _o, _e):
        n = f.get_basename() or ""
        if not (n.endswith(".parti") or n.endswith(".spazio")) or self.occupato:
            return
        if self.rinfresco:
            GLib.source_remove(self.rinfresco)
        self.rinfresco = GLib.timeout_add(400, self.ricarica)

    def ricarica(self):
        self.rinfresco = 0
        self.dischi = leggi_dischi()
        scelto = self.scelto
        for r in self.lista.get_children():
            r.destroy()
        for d in self.dischi:
            r = Gtk.ListBoxRow()
            r.disco = d["id"]
            h = Gtk.Box(spacing=10)
            icona = "media-flash" if d["tipo"] == "Scheda SD" else "drive-removable-media"
            h.pack_start(Gtk.Image.new_from_icon_name(icona, Gtk.IconSize.DND), False, False, 0)
            v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1, valign=Gtk.Align.CENTER)
            v.pack_start(Gtk.Label(label=d["prodotto"] or tipo_testo(d["tipo"]), xalign=0, ellipsize=3), False, False, 0)
            sub = Gtk.Label(label=f"{misura(d['byte'])} · {tipo_testo(d['tipo'])}", xalign=0)
            sub.get_style_context().add_class("hint")
            v.pack_start(sub, False, False, 0)
            h.pack_start(v, True, True, 0)
            r.add(h)
            self.lista.add(r)
        self.lista.show_all()
        righe = self.lista.get_children()
        if not righe:
            self.scelto = None
            self.mostra_vuoto()
            return False
        giusta = next((r for r in righe if r.disco == scelto), righe[0])
        self.lista.select_row(giusta)
        self.mostra(giusta.disco)
        return False

    def su_scelta(self, _l, r):
        if r is not None and r.disco != self.scelto:
            self.mostra(r.disco)

    def disco(self):
        return next((d for d in self.dischi if d["id"] == self.scelto), None)

    # --- pagine ---
    def svuota(self):
        for c in self.destra.get_children():
            c.destroy()   # (remove lascerebbe in giro i menu delle righe)

    def mostra_vuoto(self):
        self.svuota()
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)
        v.pack_start(Gtk.Image.new_from_icon_name("drive-removable-media", Gtk.IconSize.DIALOG), False, False, 0)
        t = Gtk.Label(label=T("Nessun disco collegato", "No disks connected"))
        t.get_style_context().add_class("empty-title")
        v.pack_start(t, False, False, 0)
        h = Gtk.Label(label=T("Collega una chiavetta, una scheda SD o un disco USB.", "Connect a USB stick, an SD card or a USB disk."))
        h.get_style_context().add_class("hint")
        v.pack_start(h, False, False, 0)
        self.destra.add(v)
        self.destra.show_all()

    def mostra(self, did):
        self.scelto = did
        d = self.disco()
        if not d:
            return self.mostra_vuoto()
        self.svuota()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=28)
        box.set_margin_top(20)
        # intestazione: nome, misure, Espelli
        top = Gtk.Box(spacing=14)
        icona = "media-flash" if d["tipo"] == "Scheda SD" else "drive-removable-media"
        top.pack_start(Gtk.Image.new_from_icon_name(icona, Gtk.IconSize.DIALOG), False, False, 0)
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER)
        t = Gtk.Label(label=d["prodotto"] or tipo_testo(d["tipo"]), xalign=0, ellipsize=3)
        t.get_style_context().add_class("pane-title")
        v.pack_start(t, False, False, 0)
        tab = {"dos": T("tabella MBR", "MBR table"), "gpt": T("tabella GPT", "GPT table")}.get(d["tabella"], T("senza tabella delle partizioni", "no partition table"))
        s = Gtk.Label(label=f"{tipo_testo(d['tipo'])} · {misura(d['byte'])} · {tab} · {d['dev']}", xalign=0)
        s.get_style_context().add_class("hint")
        v.pack_start(s, False, False, 0)
        if d["ro"]:   # levetta della scheda, o chiavetta consumata che si è bloccata da sola
            w = Gtk.Label(label=T("Protetto da scrittura: si può leggere, ma non cambiare.",
                                  "Write-protected: it can be read but not changed."), xalign=0, wrap=True)
            w.get_style_context().add_class("warn")
            v.pack_start(w, False, False, 2)
        top.pack_start(v, True, True, 0)
        b = Gtk.Button(label=T("Espelli", "Eject"), valign=Gtk.Align.CENTER)
        b.set_image(Gtk.Image.new_from_icon_name("media-eject-symbolic", Gtk.IconSize.BUTTON))
        b.set_always_show_image(True)
        b.connect("clicked", lambda *a: self.espelli(d))
        top.pack_end(b, False, False, 0)
        box.pack_start(top, False, False, 4)
        # la barra delle partizioni
        area = Gtk.DrawingArea()
        area.set_size_request(-1, 38)
        area.connect("draw", self.disegna, d)
        box.pack_start(area, False, False, 6)
        # partizioni e spazi liberi, in ordine sul disco
        voci = [("p", p["inizio"], p) for p in d["parti"]] + [("l", ini, (ini, n)) for ini, n in d["liberi"]]
        voci.sort(key=lambda x: x[1])
        righe = [self.riga_parte(d, x) if k == "p" else self.riga_libera(d, *x) for k, _i, x in voci]
        if not righe:
            righe = [self.riga_testo(T("Nessuna partizione", "No partitions"),
                                     T("Il disco è vuoto o non ha una tabella delle partizioni: puoi inizializzarlo.",
                                       "The disk is empty or has no partition table: you can initialize it."))]
        self.gruppo(box, T("Partizioni", "Partitions"), righe)
        # tutto il disco
        r = self.riga_testo(T("Inizializza il disco", "Initialize disk"),
                            T("Cancella tutto e crea una sola partizione, pronta da usare.", "Erases everything and creates a single partition, ready to use."))
        bi = Gtk.Button(label=T("Inizializza…", "Initialize…"), valign=Gtk.Align.CENTER, sensitive=not d["ro"])
        bi.get_style_context().add_class("destructive-action")
        bi.connect("clicked", lambda *a: self.inizializza(d))
        r.pack_end(bi, False, False, 0)
        self.gruppo(box, T("Disco", "Disk"), [r])
        self.destra.add(box)
        self.destra.show_all()

    def gruppo(self, box, titolo, righe):
        t = Gtk.Label(label=titolo, xalign=0)
        t.get_style_context().add_class("group-title")
        box.pack_start(t, False, False, 0)
        g = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        g.get_style_context().add_class("group")
        for i, r in enumerate(righe):
            if i:
                sep = Gtk.Box()
                sep.get_style_context().add_class("group-sep")
                g.pack_start(sep, False, False, 0)
            g.pack_start(r, False, False, 0)
        box.pack_start(g, False, False, 0)

    def riga_testo(self, testo, sotto=None, colore=None):
        h = Gtk.Box(spacing=12)
        h.get_style_context().add_class("group-row")
        if colore:
            pallino = Gtk.DrawingArea()
            pallino.set_size_request(12, 12)
            pallino.set_valign(Gtk.Align.CENTER)
            pallino.connect("draw", lambda w, cr, c=colore: (cr.set_source_rgb(*c), cr.arc(6, 6, 6, 0, 6.3), cr.fill()))
            h.pack_start(pallino, False, False, 0)
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3, valign=Gtk.Align.CENTER)
        v.pack_start(Gtk.Label(label=testo, xalign=0, wrap=True), False, False, 0)
        if sotto:
            hl = Gtk.Label(label=sotto, xalign=0, wrap=True)
            hl.get_style_context().add_class("hint")
            v.pack_start(hl, False, False, 0)
        h.v = v
        h.pack_start(v, True, True, 0)
        return h

    def riga_parte(self, d, p):
        nome = p["etichetta"] or p["nome"] or T("Senza nome", "Unnamed")
        sotto = f"{nome_fs(p['fs'])} · {misura(p['byte'])}"
        if p["spazio"]:
            usati, tot = p["spazio"]
            sotto += " · " + T(f"{misura(tot - usati)} liberi", f"{misura(tot - usati)} free")
        sotto += " · " + (T("montata", "mounted") if p["nome"] else T("non montata", "not mounted")) + f" · {p['dev']}"
        r = self.riga_testo(nome, sotto, COLORI.get(p["fs"], GRIGIO))
        if p["spazio"]:
            usati, tot = p["spazio"]
            pb = Gtk.ProgressBar(fraction=min(1.0, usati / tot) if tot else 0)
            pb.set_size_request(220, -1)
            r.v.pack_start(pb, False, False, 2)
        noto = p["fs"] in ("exfat", "vfat", "ntfs", "ext2", "ext3", "ext4")
        scrivibile = not d["ro"]
        voci = [(T("Rinomina…", "Rename…"), lambda: self.rinomina(d, p), noto and scrivibile),
                (T("Controlla e ripara", "Check and repair"), lambda: self.controlla(d, p), noto and scrivibile),
                (T("Formatta…", "Format…"), lambda: self.formatta(d, p), scrivibile),
                None,
                (T("Elimina la partizione…", "Delete partition…"), lambda: self.elimina(d, p), bool(d["tabella"]) and scrivibile)]
        # il menu nasce al clic (un Gtk.MenuButton col suo menu, distrutto a ogni ridisegno, riempie il
        # registro di avvisi di GTK 3)
        altro = Gtk.Button(valign=Gtk.Align.CENTER)
        altro.add(Gtk.Image.new_from_icon_name("view-more-symbolic", Gtk.IconSize.BUTTON))
        altro.connect("clicked", lambda b, v=voci: self.menu(b, v))
        r.pack_end(altro, False, False, 0)
        if p["nome"]:
            b = Gtk.Button(label=T("Smonta", "Unmount"), valign=Gtk.Align.CENTER)
            b.connect("clicked", lambda *a: self.lavora(T("Smonto…", "Unmounting…"), [["umount", p["dev"]]]))
            r.pack_end(b, False, False, 0)
            a = Gtk.Button(label=T("Apri", "Open"), valign=Gtk.Align.CENTER)
            a.connect("clicked", lambda *a: self.apri(p))
            r.pack_end(a, False, False, 0)
        elif noto or p["fs"] in ("btrfs", "xfs"):
            b = Gtk.Button(label=T("Monta", "Mount"), valign=Gtk.Align.CENTER)
            b.connect("clicked", lambda *a: self.lavora(T("Monto…", "Mounting…"), [["mount", p["dev"]]]))
            r.pack_end(b, False, False, 0)
        return r

    def menu(self, bottone, voci):
        self._menu = m = Gtk.Menu()
        for v in voci:
            if v is None:
                m.append(Gtk.SeparatorMenuItem())
                continue
            it = Gtk.MenuItem(label=v[0])
            it.set_sensitive(v[2])
            it.connect("activate", lambda _i, cb=v[1]: GLib.idle_add(lambda: (cb(), False)[1]))
            m.append(it)
        m.show_all()
        m.popup_at_widget(bottone, Gdk.Gravity.SOUTH_EAST, Gdk.Gravity.NORTH_EAST, None)

    def riga_libera(self, d, inizio, byte):
        r = self.riga_testo(T("Spazio libero", "Free space"), misura(byte), GRIGIO)
        b = Gtk.Button(label=T("Crea partizione…", "Create partition…"), valign=Gtk.Align.CENTER, sensitive=not d["ro"])
        b.connect("clicked", lambda *a: self.crea(d, inizio, byte))
        r.pack_end(b, False, False, 0)
        return r

    def disegna(self, w, cr, d):
        larg, alt = w.get_allocated_width(), w.get_allocated_height()
        tot = d["byte"] or 1
        cr.set_source_rgba(*GRIGIO, 0.25)
        cr.rectangle(0, 0, larg, alt)
        cr.fill()
        for p in d["parti"]:
            x, l = p["inizio"] / tot * larg, max(3, p["byte"] / tot * larg)
            cr.set_source_rgb(*COLORI.get(p["fs"], GRIGIO))
            cr.rectangle(x + 1, 0, l - 2, alt)
            cr.fill()
            if p["spazio"] and p["spazio"][1]:   # la parte usata più scura
                cr.set_source_rgba(0, 0, 0, 0.22)
                cr.rectangle(x + 1, 0, (l - 2) * p["spazio"][0] / p["spazio"][1], alt)
                cr.fill()
        return False

    # --- azioni ---
    def apri(self, p):   # una cartella vera, /media/usb/<nome> (tod-fs.so)
        subprocess.Popen(["exo-open", "--launch", "FileManager", f"/media/usb/{p['nome']}"],
                         start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def espelli(self, d):
        self.lavora(T("Espello…", "Ejecting…"), [["eject", d["dev"]]],
                    fatto=T("Puoi scollegare il disco.", "You can now disconnect the disk."))

    def conferma(self, titolo, testo, azione):
        m = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                              buttons=Gtk.ButtonsType.NONE, text=titolo)
        m.format_secondary_text(testo)
        m.add_button(T("Annulla", "Cancel"), Gtk.ResponseType.CANCEL)
        b = m.add_button(azione, Gtk.ResponseType.OK)
        b.get_style_context().add_class("destructive-action")
        ok = m.run() == Gtk.ResponseType.OK
        m.destroy()
        return ok

    def scheda(self, titolo, testo_ok, nome="", con_tabella=False, max_byte=None):
        """Finestra per nome, formato (e tabella, e misura): dict o None."""
        dl = Gtk.Dialog(title=titolo, transient_for=self, modal=True)
        dl.add_button(T("Annulla", "Cancel"), Gtk.ResponseType.CANCEL)
        ok = dl.add_button(testo_ok, Gtk.ResponseType.OK)
        ok.get_style_context().add_class("destructive-action" if not max_byte else "suggested-action")
        g = Gtk.Grid(column_spacing=12, row_spacing=10, margin=16)
        dl.get_content_area().add(g)
        g.attach(Gtk.Label(label=T("Nome", "Name"), xalign=1), 0, 0, 1, 1)
        e = Gtk.Entry(text=nome, activates_default=True, hexpand=True)
        g.attach(e, 1, 0, 1, 1)
        g.attach(Gtk.Label(label=T("Formato", "Format"), xalign=1), 0, 1, 1, 1)
        fmt = Gtk.ComboBoxText()
        ntfs = ntfs_disponibile()
        for k, n, spieg, *_ in FORMATI:
            fmt.append(k, n if k != "ntfs" or ntfs else n + T(" (installa ntfs-3g)", " (install ntfs-3g)"))
        fmt.set_active_id("exfat")
        g.attach(fmt, 1, 1, 1, 1)
        spieg = Gtk.Label(xalign=0, wrap=True)
        spieg.get_style_context().add_class("hint")
        g.attach(spieg, 1, 2, 1, 1)
        fmt.connect("changed", lambda *a: spieg.set_text(next(f[2] for f in FORMATI if f[0] == fmt.get_active_id())))
        spieg.set_text(FORMATI[0][2])
        riga = 3
        tab = None
        if con_tabella:
            g.attach(Gtk.Label(label=T("Tabella", "Table"), xalign=1), 0, riga, 1, 1)
            tab = Gtk.ComboBoxText()
            tab.append("dos", T("MBR (consigliata: la leggono tutti)", "MBR (recommended: works everywhere)"))
            tab.append("gpt", T("GPT (dischi oltre 2 TB)", "GPT (disks over 2 TB)"))
            tab.set_active_id("dos")
            g.attach(tab, 1, riga, 1, 1)
            riga += 1
        dim = None
        if max_byte:
            g.attach(Gtk.Label(label=T("Misura (MB)", "Size (MB)"), xalign=1), 0, riga, 1, 1)
            mb = max_byte // 1000000
            dim = Gtk.SpinButton.new_with_range(8, mb, 1)
            dim.set_value(mb)
            g.attach(dim, 1, riga, 1, 1)
        dl.set_default_response(Gtk.ResponseType.OK)
        dl.show_all()
        while True:
            if dl.run() != Gtk.ResponseType.OK:
                dl.destroy()
                return None
            f = next(x for x in FORMATI if x[0] == fmt.get_active_id())
            if f[0] == "ntfs" and not ntfs:
                self.avviso(T("NTFS non è installato", "NTFS is not installed"),
                            T("Installalo dal terminale con: sudo apt install ntfs-3g", "Install it from the terminal with: sudo apt install ntfs-3g"))
                continue
            n = e.get_text().strip()
            if f[0] == "vfat":
                n = n.upper()
            out = {"nome": n[:f[3]], "fmt": f, "tabella": tab.get_active_id() if tab else None,
                   "byte": int(dim.get_value()) * 1000000 if dim else None}
            dl.destroy()
            return out

    def mkfs(self, s, dev):
        k, n = s["fmt"][0], s["nome"]
        return {"exfat": ["mkfs.exfat"] + (["-L", n] if n else []) + [dev],
                "vfat": ["mkfs.vfat", "-F", "32"] + (["-n", n] if n else []) + [dev],
                "ntfs": ["mkntfs", "-f"] + (["-L", n] if n else []) + [dev],
                "ext4": ["mkfs.ext4", "-F"] + (["-L", n] if n else []) + [dev]}[k]

    def tipo_parte(self, d, s):
        return s["fmt"][4] if d["tabella"] == "dos" else s["fmt"][5]

    def formatta(self, d, p):
        s = self.scheda(T(f"Formatta {p['etichetta'] or p['dev']}", f"Format {p['etichetta'] or p['dev']}"),
                        T("Formatta", "Format"), p["etichetta"])
        if not s or not self.conferma(T("Cancellare tutti i dati della partizione?", "Erase all data on the partition?"),
                                      T(f"Tutto quello che c'è in {p['etichetta'] or p['dev']} verrà cancellato.",
                                        f"Everything on {p['etichetta'] or p['dev']} will be erased."), T("Formatta", "Format")):
            return
        cmd = []
        if d["tabella"]:
            cmd.append(["sfdisk", "--part-type", d["dev"], str(p["n"]), self.tipo_parte(d, s)])
        cmd.append(self.mkfs(s, p["dev"]))
        self.lavora(T("Formatto…", "Formatting…"), cmd)

    def rinomina(self, d, p):
        f = next((x for x in FORMATI if x[0] == ("ext4" if p["fs"].startswith("ext") else p["fs"])), None)
        dl = Gtk.Dialog(title=T("Rinomina", "Rename"), transient_for=self, modal=True)
        dl.add_button(T("Annulla", "Cancel"), Gtk.ResponseType.CANCEL)
        dl.add_button(T("Rinomina", "Rename"), Gtk.ResponseType.OK).get_style_context().add_class("suggested-action")
        e = Gtk.Entry(text=p["etichetta"], activates_default=True, margin=16)
        e.set_max_length(f[3] if f else 32)
        dl.get_content_area().add(e)
        dl.set_default_response(Gtk.ResponseType.OK)
        dl.show_all()
        ok = dl.run() == Gtk.ResponseType.OK
        n = e.get_text().strip()
        dl.destroy()
        if not ok:
            return
        cmd = {"exfat": ["exfatlabel", p["dev"], n], "vfat": ["fatlabel", p["dev"], n.upper()],
               "ntfs": ["ntfslabel", p["dev"], n]}.get(p["fs"], ["e2label", p["dev"], n])
        self.lavora(T("Rinomino…", "Renaming…"), [cmd])

    def controlla(self, d, p):
        cmd = {"exfat": ["fsck.exfat", "-y", p["dev"]], "vfat": ["fsck.vfat", "-a", "-w", p["dev"]],
               "ntfs": ["ntfsfix", p["dev"]]}.get(p["fs"], ["e2fsck", "-f", "-y", p["dev"]])
        self.lavora(T("Controllo…", "Checking…"), [cmd], fatto=T("Controllo finito: nessun problema, o problemi riparati.",
                                                                  "Check finished: no problems, or problems repaired."),
                    accetta=(0, 1))   # fsck: 1 = errori corretti

    def elimina(self, d, p):
        if self.conferma(T("Eliminare la partizione?", "Delete the partition?"),
                         T(f"{p['etichetta'] or p['dev']} e tutti i suoi dati spariranno dal disco.",
                           f"{p['etichetta'] or p['dev']} and all its data will be removed from the disk."), T("Elimina", "Delete")):
            self.lavora(T("Elimino…", "Deleting…"), [["sfdisk", "--delete", d["dev"], str(p["n"])]])

    def crea(self, d, inizio, byte):
        s = self.scheda(T("Nuova partizione", "New partition"), T("Crea", "Create"), "", max_byte=byte)
        if not s:
            return
        settori = min(byte, s["byte"]) // 512 // 2048 * 2048
        riga = f"start={inizio // 512}, size={settori}, type={self.tipo_parte(d, s)}\n"
        def dopo():   # il numero della partizione nuova: quella che comincia lì
            for x in leggi_dischi():
                if x["id"] == d["id"]:
                    for p in x["parti"]:
                        if p["inizio"] == inizio:
                            return [self.mkfs(s, p["dev"])]
            return []
        self.lavora(T("Creo la partizione…", "Creating the partition…"), [(["sfdisk", "--append", d["dev"]], riga), dopo])

    def inizializza(self, d):
        s = self.scheda(T(f"Inizializza {d['prodotto'] or d['dev']}", f"Initialize {d['prodotto'] or d['dev']}"),
                        T("Inizializza", "Initialize"), d["prodotto"][:11] if d["prodotto"] else "", con_tabella=True)
        if not s or not self.conferma(T("Cancellare tutto il disco?", "Erase the whole disk?"),
                                      T(f"Tutte le partizioni e tutti i dati di {d['prodotto'] or d['dev']} verranno cancellati.",
                                        f"All partitions and all data on {d['prodotto'] or d['dev']} will be erased."),
                                      T("Cancella tutto", "Erase everything")):
            return
        d2 = dict(d, tabella=s["tabella"])
        tabella = f"label: {s['tabella']}\n,,{self.tipo_parte(d2, s)}\n"
        self.lavora(T("Inizializzo il disco…", "Initializing the disk…"),
                    [(["sfdisk", "--wipe", "always", "--wipe-partitions", "always", d["dev"]], tabella), self.mkfs(s, d["dev"] + "1")])

    def avviso(self, titolo, testo, errore=False):
        m = Gtk.MessageDialog(transient_for=self, modal=True,
                              message_type=Gtk.MessageType.ERROR if errore else Gtk.MessageType.INFO,
                              buttons=Gtk.ButtonsType.OK, text=titolo)
        m.format_secondary_text(testo)
        m.run()
        m.destroy()

    def lavora(self, titolo, comandi, fatto=None, accetta=(0,)):
        """I comandi (tod-disco) uno dopo l'altro in sottofondo, con una finestrella che gira. Un comando è
        una lista, una coppia (lista, testo da mandargli) o una funzione che dà i comandi seguenti."""
        self.occupato = True
        dl = Gtk.Dialog(title=T("Dischi", "Disks"), transient_for=self, modal=True, deletable=False)
        h = Gtk.Box(spacing=14, margin=22)
        sp = Gtk.Spinner()
        sp.start()
        h.pack_start(sp, False, False, 0)
        h.pack_start(Gtk.Label(label=titolo, xalign=0), True, True, 0)
        dl.get_content_area().add(h)
        dl.show_all()

        def gira():
            coda, err = list(comandi), None
            while coda and not err:
                c = coda.pop(0)
                if callable(c):
                    coda = c() + coda
                    continue
                argv, dati = (c, None) if isinstance(c, list) else c
                try:
                    r = subprocess.run(["bash", DISCO] + argv, input=dati, capture_output=True, text=True, timeout=1800)
                    if r.returncode not in accetta:
                        err = (r.stderr.strip() or r.stdout.strip() or f"errore {r.returncode}").splitlines()[-6:]
                except (OSError, subprocess.TimeoutExpired) as x:
                    err = [str(x)]
            GLib.idle_add(finito, err)

        def finito(err):
            dl.destroy()
            self.occupato = False
            self.aggiorna_spazio()
            GLib.timeout_add(700, self.ricarica)   # tod-lkl rimonta e riscrive i suoi file
            if err:
                self.avviso(T("Non è riuscito", "It didn't work"), "\n".join(err), errore=True)
            elif fatto:
                self.avviso(fatto, "")
            return False

        threading.Thread(target=gira, daemon=True).start()


def _ctl(percorso, comando):
    import socket
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(10)
        s.connect(percorso)
        s.sendall((comando + "\n").encode())
        s.recv(16)
        s.close()
    except OSError:
        pass


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.termuxondex.Dischi")
        self.win = None

    def do_activate(self):
        if not self.win:
            try:
                self.win = Dischi(self)
            except Exception as e:   # mai un Dischi acceso senza finestra (le aperture dopo finirebbero lì)
                import traceback
                traceback.print_exc()
                m = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.OK,
                                      text=T("Dischi non si è aperto", "Disks did not open"))
                m.format_secondary_text(str(e))
                m.run()
                m.destroy()
                for w in self.get_windows():
                    w.destroy()
                self.quit()
                return
        self.win.present()


if __name__ == "__main__":
    App().run(None)
