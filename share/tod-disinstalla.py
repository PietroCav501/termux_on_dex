#!/usr/bin/env python3
"""Disinstallatore delle app, gemello dell'installer dei .deb (tod-installer.py).

  tod-disinstalla.py termux|debian|home pacchetto [nome]

Passi a sinistra (Riepilogo → Rimozione → Fatto). Prima di toccare qualcosa mostra cosa se ne va e
quanto spazio si libera: il programma, i componenti che servivano solo a lui, le voci del menu e, se
scelto, le sue impostazioni e i suoi dati (nel Cestino, recuperabili). Il lavoro lo fa tod
(`tod _app_piano`, `tod _app_rimuovi`, lib/disinstalla.sh); i documenti non si toccano mai.
"""
import os
import re
import subprocess
import sys
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")   # senza, Termux carica Gdk 4 e GTK 3 non parte
gi.require_version("Pango", "1.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

GLib.set_prgname("tod-disinstalla")

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
TOD = os.path.join(PREFIX, "bin/tod")
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "")).startswith("it")
HOME = os.environ.get("TOD_TERMUX_HOME", os.path.expanduser("~"))


def T(it, en):
    return it if ITALIAN else en


def human(kb):
    try:
        b = int(kb or 0) * 1024
    except ValueError:
        return ""
    for unit in ("byte", "KB", "MB", "GB"):
        if b < 1024 or unit == "GB":
            s = f"{b:.0f} {unit}" if unit in ("byte", "KB") else f"{b:.1f} {unit}"
            return s.replace(".", ",") if ITALIAN else s
        b /= 1024


def piano(dove, pkg):
    """le righe di `tod _app_piano`: programma, componenti, dati, voci"""
    out = {"programma": [], "componente": [], "dati": [], "voce": [], "protetta": []}
    try:
        r = subprocess.run(["bash", TOD, "_app_piano", dove, pkg], capture_output=True, text=True, timeout=300,
                           stdin=subprocess.DEVNULL)
        for line in r.stdout.splitlines():
            parti = line.split("\t")
            if parti[0] in out:
                out[parti[0]].append(parti[1:])
    except (OSError, subprocess.TimeoutExpired):
        pass
    return out


def breve(percorso):
    """percorsi leggibili: ~ per le home, e il container senza il suo lungo prefisso"""
    p = re.sub(r"^.*/proot-distro/(containers|installed-rootfs)/[^/]+(/rootfs)?/home/[^/]+", "~", percorso)
    return p.replace(HOME, "~", 1)


def kb(righe, col=1):
    tot = 0
    for r in righe:
        try:
            tot += int(r[col])
        except (IndexError, ValueError):
            pass
    return tot


class Disinstallatore(Gtk.Window):
    STEPS = [("intro", T("Riepilogo", "Summary")), ("lavoro", T("Rimozione", "Removal")), ("fatto", T("Fatto", "Done"))]

    def __init__(self, dove, pkg, nome):
        super().__init__(title=T("Disinstalla app", "Uninstall app"))
        self.dove, self.pkg, self.nome = dove, pkg, nome or pkg
        self.liberati = 0
        self.set_default_size(720, 500)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_icon_name("edit-delete")
        self.connect("destroy", Gtk.main_quit)
        css = Gtk.CssProvider()
        css.load_from_data(b"""
            .side { background-color: alpha(@theme_fg_color, 0.04); }
            .step { padding: 6px 4px; opacity: 0.55; }
            .step.current { opacity: 1; font-weight: bold; }
            .big { font-size: 20pt; font-weight: bold; }
            .warn { color: #b25e00; }
            .voce { padding: 4px 0; }
        """)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        outer = Gtk.Box()
        self.add(outer)
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin=20)
        side.set_size_request(190, -1)
        side.get_style_context().add_class("side")
        outer.pack_start(side, False, False, 0)
        self.side_icon = Gtk.Image.new_from_icon_name("edit-delete", Gtk.IconSize.DIALOG)
        self.side_icon.set_pixel_size(64)
        self.side_icon.set_margin_bottom(16)
        side.pack_start(self.side_icon, False, False, 0)
        self.step_labels = {}
        for key, title in self.STEPS:
            lab = Gtk.Label(label="•  " + title, xalign=0)
            lab.get_style_context().add_class("step")
            side.pack_start(lab, False, False, 0)
            self.step_labels[key] = lab

        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin=24, spacing=16)
        outer.pack_start(right, True, True, 0)
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT)
        right.pack_start(self.stack, True, True, 0)
        buttons = Gtk.Box(spacing=8)
        right.pack_end(buttons, False, False, 0)
        self.back = Gtk.Button(label=T("Annulla", "Cancel"))
        self.back.connect("clicked", lambda *a: self.destroy())
        buttons.pack_start(self.back, False, False, 0)
        self.next = Gtk.Button(label=T("Disinstalla", "Uninstall"))
        self.next.get_style_context().add_class("destructive-action")
        self.next.connect("clicked", self.on_next)
        buttons.pack_end(self.next, False, False, 0)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, valign=Gtk.Align.CENTER)
        sp = Gtk.Spinner()
        sp.start()
        box.pack_start(sp, False, False, 0)
        box.pack_start(Gtk.Label(label=T("Controllo di cosa si può togliere…", "Checking what can be removed…")),
                       False, False, 0)
        self.stack.add_named(box, "attesa")
        self.go("attesa")
        self.next.set_sensitive(False)
        threading.Thread(target=lambda: GLib.idle_add(self.mostra_piano, piano(dove, pkg)), daemon=True).start()

    def go(self, page):
        self.stack.set_visible_child_name(page)
        for key, lab in self.step_labels.items():
            ctx = lab.get_style_context()
            (ctx.add_class if key == page or (page == "attesa" and key == "intro") else ctx.remove_class)("current")

    def icona(self, voci):
        """l'icona dell'app, dalla sua voce del menu (anche la copia esportata del container)"""
        for v in voci:
            for i in (v[0], "tod-cx-" + v[0]):
                try:
                    info = Gio.DesktopAppInfo.new(i)
                except TypeError:
                    info = None
                if info and info.get_icon():
                    return info.get_icon()
        return None

    # --- riepilogo ------------------------------------------------------------------------------
    def mostra_piano(self, p):
        self.p = p
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        head = Gtk.Box(spacing=16)
        box.pack_start(head, False, False, 0)
        gicon = self.icona(p["voce"])
        img = Gtk.Image.new_from_gicon(gicon, Gtk.IconSize.DIALOG) if gicon else \
            Gtk.Image.new_from_icon_name("application-x-executable", Gtk.IconSize.DIALOG)
        img.set_pixel_size(72)
        if gicon:
            self.side_icon.set_from_gicon(gicon, Gtk.IconSize.DIALOG)
            self.side_icon.set_pixel_size(64)
        head.pack_start(img, False, False, 0)
        t = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, valign=Gtk.Align.CENTER)
        head.pack_start(t, True, True, 0)
        title = Gtk.Label(label=T(f"Disinstallare {self.nome}?", f"Uninstall {self.nome}?"), xalign=0)
        title.get_style_context().add_class("big")
        title.set_line_wrap(True)
        t.pack_start(title, False, False, 0)
        self.sub = Gtk.Label(xalign=0)
        self.sub.get_style_context().add_class("dim-label")
        t.pack_start(self.sub, False, False, 0)

        if p["protetta"]:
            n = Gtk.Label(label=T(f"{self.nome} fa parte del desktop e non si disinstalla.",
                                  f"{self.nome} is part of the desktop and cannot be uninstalled."), xalign=0)
            n.get_style_context().add_class("warn")
            box.pack_start(n, False, False, 0)
            self.stack.add_named(box, "intro")
            box.show_all()
            self.go("intro")
            return False

        elenco = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        sw = Gtk.ScrolledWindow(vexpand=True)
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.add(elenco)
        box.pack_start(sw, True, True, 0)
        elenco.pack_start(self.riga(T("Il programma", "The program"), kb(p["programma"])), False, False, 0)
        if p["componente"]:
            elenco.pack_start(self.riga(T(f"Componenti usati solo da quest'app ({len(p['componente'])})",
                                          f"Components used only by this app ({len(p['componente'])})"),
                                        kb(p["componente"]), [c[0] for c in p["componente"]]), False, False, 0)
        elenco.pack_start(self.riga(T("Voci del menu, associazioni dei file, app fissate",
                                      "Menu entries, file associations, pinned apps"), None), False, False, 0)
        self.dati = Gtk.CheckButton()
        if p["dati"]:
            self.dati.set_active(True)
            lab = T(f"Anche impostazioni e dati dell'app ({human(kb(p['dati']))}), nel Cestino",
                    f"Also the app's settings and data ({human(kb(p['dati']))}), to the Trash")
            r = self.riga(lab, None, [breve(d[0]) for d in p["dati"]], check=self.dati)
            elenco.pack_start(r, False, False, 0)
            self.dati.connect("toggled", lambda *a: self.aggiorna_totale())
        else:
            n = Gtk.Label(label=T("Nessuna impostazione o dato dell'app da togliere.",
                                  "No app settings or data to remove."), xalign=0)
            n.get_style_context().add_class("dim-label")
            elenco.pack_start(n, False, False, 6)
        nota = Gtk.Label(label=T("I tuoi documenti non vengono toccati. Quello che va nel Cestino si può recuperare.",
                                 "Your documents are not touched. What goes to the Trash can be recovered."),
                         xalign=0, wrap=True)
        nota.get_style_context().add_class("dim-label")
        box.pack_start(nota, False, False, 0)
        self.aggiorna_totale()
        self.stack.add_named(box, "intro")
        box.show_all()
        self.go("intro")
        self.next.set_sensitive(True)
        return False

    def riga(self, testo, dim, dettagli=None, check=None):
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        h = Gtk.Box(spacing=10)
        h.get_style_context().add_class("voce")
        if check is not None:
            h.pack_start(check, False, False, 0)
        else:
            ok = Gtk.Image.new_from_icon_name("emblem-ok-symbolic", Gtk.IconSize.MENU)
            h.pack_start(ok, False, False, 4)
        lab = Gtk.Label(label=testo, xalign=0, wrap=True)
        h.pack_start(lab, True, True, 0)
        if dim:
            d = Gtk.Label(label=human(dim))
            d.get_style_context().add_class("dim-label")
            h.pack_end(d, False, False, 0)
        v.pack_start(h, False, False, 0)
        if dettagli:
            exp = Gtk.Expander(label=T("Mostra", "Show"))
            exp.set_margin_start(30)
            l2 = Gtk.Label(label="\n".join(dettagli), xalign=0, selectable=True)
            l2.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            l2.get_style_context().add_class("dim-label")
            exp.add(l2)
            v.pack_start(exp, False, False, 0)
        return v

    def aggiorna_totale(self):
        self.liberati = kb(self.p["programma"]) + kb(self.p["componente"]) + \
            (kb(self.p["dati"]) if self.dati.get_active() else 0)
        self.sub.set_text(T(f"Libera circa {human(self.liberati)}", f"Frees about {human(self.liberati)}"))

    def on_next(self, *a):
        if self.stack.get_visible_child_name() == "intro":
            self.avvia()
        else:
            self.destroy()

    # --- rimozione ------------------------------------------------------------------------------
    def avvia(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, valign=Gtk.Align.CENTER)
        lab = Gtk.Label(label=T(f"Disinstallazione di {self.nome}…", f"Uninstalling {self.nome}…"), xalign=0)
        lab.get_style_context().add_class("big")
        lab.set_line_wrap(True)
        box.pack_start(lab, False, False, 0)
        self.bar = Gtk.ProgressBar(show_text=True)
        self.bar.set_text(T("Preparazione…", "Preparing…"))
        box.pack_start(self.bar, False, False, 0)
        exp = Gtk.Expander(label=T("Mostra i dettagli", "Show details"))
        self.log = Gtk.TextView(editable=False, monospace=True, cursor_visible=False)
        self.log.set_wrap_mode(Gtk.WrapMode.CHAR)
        sw = Gtk.ScrolledWindow(min_content_height=160)
        sw.add(self.log)
        exp.add(sw)
        box.pack_start(exp, False, False, 0)
        self.stack.add_named(box, "lavoro")
        box.show_all()
        self.go("lavoro")
        self.next.set_sensitive(False)
        self.back.set_sensitive(False)
        self.pulse = GLib.timeout_add(120, lambda: self.bar.pulse() or True)
        threading.Thread(target=self.lavora, args=(self.dati.get_active(),), daemon=True).start()

    def lavora(self, dati):
        fasi = {"programma": (0.3, T("Rimozione del programma…", "Removing the program…")),
                "componenti": (0.5, T("Rimozione dei componenti…", "Removing components…")),
                "dati": (0.75, T("Impostazioni e dati nel Cestino…", "Settings and data to the Trash…")),
                "pulizia": (0.9, T("Pulizia di menu e associazioni…", "Cleaning menus and associations…"))}
        tail = []
        try:
            p = subprocess.Popen(["bash", TOD, "_app_rimuovi", self.dove, self.pkg, "1" if dati else "0"],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, stdin=subprocess.DEVNULL,
                                 env=dict(os.environ, DEBIAN_FRONTEND="noninteractive"))
            for line in p.stdout:
                line = re.sub(r"\x1b\[[0-9;]*m", "", line)
                tail = (tail + [line.rstrip()])[-12:]
                m = re.match(r"FASE (\w+)", line)
                if m and m.group(1) in fasi:
                    GLib.idle_add(self.progresso, *fasi[m.group(1)])
                    continue
                GLib.idle_add(self.append, line)
            rc = p.wait()
        except OSError as e:
            rc, tail = 1, [str(e)]
        GLib.idle_add(self.fine, rc == 0, tail)

    def progresso(self, frac, text):
        if self.pulse:
            GLib.source_remove(self.pulse)
            self.pulse = None
        self.bar.set_fraction(max(self.bar.get_fraction(), frac))
        self.bar.set_text(text)

    def append(self, line):
        buf = self.log.get_buffer()
        buf.insert(buf.get_end_iter(), line)
        self.log.scroll_to_iter(buf.get_end_iter(), 0, False, 0, 0)

    def fine(self, ok, tail):
        if self.pulse:
            GLib.source_remove(self.pulse)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, valign=Gtk.Align.CENTER)
        icon = Gtk.Image.new_from_icon_name("emblem-ok-symbolic" if ok else "dialog-error-symbolic", Gtk.IconSize.DIALOG)
        icon.set_pixel_size(64)
        box.pack_start(icon, False, False, 0)
        lab = Gtk.Label(label=T(f"{self.nome} è stata disinstallata", f"{self.nome} was uninstalled") if ok
                        else T("Disinstallazione non riuscita", "Uninstall failed"), wrap=True)
        lab.get_style_context().add_class("big")
        box.pack_start(lab, False, False, 0)
        if ok:
            sub = T(f"Spazio liberato: circa {human(self.liberati)}.", f"Space freed: about {human(self.liberati)}.")
        else:
            utili = [l for l in tail if l.strip() and not l.startswith(("Reading", "Lettura", "Building", "Generazione"))]
            sub = T("Non è stato possibile completare la disinstallazione:", "The uninstall could not be completed:") + \
                "\n" + "\n".join(utili[-3:])
        box.pack_start(Gtk.Label(label=sub, wrap=True, justify=Gtk.Justification.CENTER, selectable=not ok), False, False, 0)
        self.stack.add_named(box, "fatto")
        box.show_all()
        self.go("fatto")
        self.next.set_label(T("Chiudi", "Close"))
        self.next.get_style_context().remove_class("destructive-action")
        self.next.set_sensitive(True)
        self.back.hide()
        return False


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("termux", "debian", "home"):
        print(__doc__)
        return 2
    win = Disinstallatore(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    win.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
