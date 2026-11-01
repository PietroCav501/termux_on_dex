#!/usr/bin/env python3
"""Benvenuto: la prima accensione, come quella di macOS.

  tod-benvenuto.py CARTELLA [--avanzamento]

Si apre in Termux:X11 appena l'app c'è, e da lì in poi l'installazione si vede solo da qui: saluto,
lingua, account, aspetto, app; poi l'avanzamento, mentre dietro (Termux) si installano desktop,
Debian e la macchina dei dischi. Non installa niente da sé: parla con l'installazione (lib/benvenuto.sh)
con tre file nella CARTELLA:

  stato           dall'installazione: pct=, passo= (id del passo), fase=lavoro|errore|fatto, errore=, log=
  risposte.json   verso l'installazione: lingua, nome, utente, tema, accento, app
  comando         verso l'installazione: riprova | esci | avvia

Con --avanzamento (installazione ripresa, risposte già date) parte direttamente dall'avanzamento.
Gira senza window manager: la finestra copre tutto lo schermo e segue i suoi cambi di risoluzione.
"""
import json
import os
import re
import sys
import unicodedata

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")   # senza, Termux carica Gdk 4 e GTK 3 non parte
from gi.repository import Gdk, GLib, Gtk, Pango  # noqa: E402

GLib.set_prgname("tod-benvenuto")

DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TMPDIR", "/tmp"), "tod-benvenuto")
SOLO_AVANZAMENTO = "--avanzamento" in sys.argv

LINGUE = [("it", "Italiano"), ("en", "English"), ("es", "Español"), ("fr", "Français"),
          ("de", "Deutsch"), ("pt", "Português")]
SALUTI = ["Ciao", "Hello", "Hola", "Bonjour", "Hallo", "Olá"]
ACCENTI = [("blu", "#0067c0", "Blu", "Blue"), ("viola", "#8a5cf5", "Viola", "Purple"),
           ("rosa", "#c239b3", "Rosa", "Pink"), ("rosso", "#d13438", "Rosso", "Red"),
           ("arancione", "#ca5010", "Arancione", "Orange"), ("giallo", "#b58900", "Giallo", "Yellow"),
           ("verde", "#107c10", "Verde", "Green"), ("acqua", "#038387", "Verde acqua", "Teal"),
           ("grafite", "#68768a", "Grafite", "Graphite")]
APP_DESC = {
    "firefox": ("Il browser per navigare in internet", "The web browser"),
    "chromium": ("Il browser open source di Google", "Google's open source browser"),
    "code-oss": ("Editor per programmare", "Code editor"),
    "libreoffice": ("Documenti, fogli di calcolo e presentazioni", "Documents, spreadsheets and slides"),
    "gimp": ("Ritocco e modifica delle foto", "Photo editing"),
    "inkscape": ("Grafica vettoriale e disegno", "Vector graphics"),
    "vlc": ("Video e musica in ogni formato", "Plays any video or audio"),
    "thunderbird": ("Posta elettronica", "Email"),
    "blender": ("Grafica e animazione 3D", "3D modelling and animation"),
    "obs": ("Registra e trasmetti lo schermo", "Record and stream the screen"),
}
CONSIGLI = [
    ("Le chiavette e le schede SD compaiono in Esplora file, come su un PC.",
     "USB sticks and SD cards show up in the file manager, like on a PC."),
    ("Puoi installare le app con apt o da Software, come su ogni Linux.",
     "Install apps with apt or from Software, like on any Linux."),
    ("Spegni il desktop dal menu Start: chiude le app e spegne tutto in ordine.",
     "Shut down from the Start menu: it closes the apps and turns everything off in order."),
    ("Le cartelle Documenti, Download e Immagini sono quelle del telefono.",
     "Documents, Downloads and Pictures are the phone's own folders."),
    ("In Impostazioni cambi tema, colore, sfondo e dimensioni del testo.",
     "Change theme, colour, wallpaper and text size in Settings."),
]

# i passi dell'installazione con parole di tutti i giorni (niente nomi di pacchetti o di temi)
PASSI = {
    "desktop": ("Installo il desktop", "Installing the desktop"),
    "gpu": ("Preparo la grafica", "Setting up graphics"),
    "cx": ("Preparo l'ambiente per le app", "Setting up the app environment"),
    "cxgpu": ("Preparo la grafica per le app", "Setting up graphics for apps"),
    "apps": ("Installo le app che hai scelto", "Installing the apps you chose"),
    "look": ("Applico l'aspetto che hai scelto", "Applying your appearance"),
    "lingua": ("Traduco il desktop nella tua lingua", "Translating the desktop"),
    "usbvm": ("Preparo il supporto per chiavette e schede SD", "Setting up USB sticks and SD cards"),
    "dischi": ("Installo Dischi", "Installing Disks"),
    "integrate": ("Ultimi ritocchi", "Finishing touches"),
    "preseed": ("Preparo il primo avvio", "Preparing the first start"),
}
PRONTO = os.environ.get("TOD_BV_PRONTO", "")

lingua = os.environ.get("TOD_BV_LANG", "it")


def T(it, en):
    return it if lingua == "it" else en


def nome_passo(ident):
    return T(*PASSI.get(ident, ("Preparazione", "Preparing")))


def _geometria():
    """Misure logiche (con GDK_SCALE=2 la metà dei pixel): quelle in cui GTK disegna."""
    mon = Gdk.Display.get_default().get_monitor(0)
    if mon is not None:
        g = mon.get_geometry()
        return g.width, g.height
    scr = Gdk.Screen.get_default()
    with __import__("warnings").catch_warnings():   # get_width è "deprecato", ma senza monitor è l'unico
        __import__("warnings").simplefilter("ignore")
        return scr.get_width(), scr.get_height()


def larghezza():
    return _geometria()[0]


def altezza():
    return _geometria()[1]


def etichetta(testo, classe, larghezza_max=40):
    """Testo centrato che va a capo (mai più largo dello schermo, anche in verticale)."""
    lab = Gtk.Label(label=testo, xalign=0.5, justify=Gtk.Justification.CENTER)
    lab.set_line_wrap(True)
    lab.set_max_width_chars(larghezza_max)
    lab.get_style_context().add_class(classe)
    return lab


def leggi_stato():
    s = {}
    try:
        with open(os.path.join(DIR, "stato"), encoding="utf-8") as f:
            for riga in f:
                k, _, v = riga.rstrip("\n").partition("=")
                if k:
                    s[k] = v
    except OSError:
        pass
    return s


def scrivi(nome, testo):
    tmp = os.path.join(DIR, "." + nome + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(testo)
    os.replace(tmp, os.path.join(DIR, nome))


def nome_utente(nome):
    """"Pietro Rossi" → "pietro": minuscole, senza accenti, solo lettere e cifre (come files_user_valid)."""
    s = unicodedata.normalize("NFKD", nome.strip().split(" ")[0] if nome.strip() else "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = re.sub(r"[^a-z0-9_-]", "", s)
    s = re.sub(r"^[^a-z]+", "", s)
    return s[:32]


def utente_valido(u):
    return bool(re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", u)) and u not in ("home", "usr", "apps", "cache", "root")


def app_catalogo():
    out = []
    try:
        with open(os.path.join(DIR, "app"), encoding="utf-8") as f:
            for riga in f:
                p = riga.rstrip("\n").split("|")
                if len(p) == 3:
                    out.append((p[0], p[1], p[2] == "on"))
    except OSError:
        pass
    return out


CSS = """
window { background-image: linear-gradient(160deg, #0b1424 0%%, #0f2a4d 55%%, %(accento)s 140%%); color: #f2f5fa; }
* { font-family: "DejaVu Sans"; }
.saluto { font-family: "DejaVu Sans ExtraLight", "DejaVu Sans"; font-size: 64pt; color: #ffffff; }
.sotto { font-size: 12pt; color: alpha(#ffffff, 0.65); }
.titolo { font-size: 22pt; font-weight: bold; color: #ffffff; }
.spiega { font-size: 11pt; color: alpha(#ffffff, 0.72); }
.scheda { background-color: alpha(#ffffff, 0.07); border: 1px solid alpha(#ffffff, 0.12); border-radius: 18px; }
.riga { padding: 12px 18px; margin: 2px 8px; border-radius: 10px; color: #f2f5fa; font-size: 12pt; }
list, row { background: transparent; }
row.riga:hover { background-color: alpha(#ffffff, 0.06); }
row.riga:selected { background-color: %(accento)s; color: #ffffff; }
entry { background: alpha(#ffffff, 0.10); color: #ffffff; border: 1px solid alpha(#ffffff, 0.18);
        border-radius: 10px; padding: 10px 14px; font-size: 12pt; caret-color: #ffffff; box-shadow: none; }
entry:focus { border-color: %(accento)s; }
.etichetta { font-size: 10pt; color: alpha(#ffffff, 0.65); }
.errore-testo { color: #ff8f8f; font-size: 10pt; }
button { background-image: none; background-color: alpha(#ffffff, 0.10); color: #ffffff; border: none;
         border-radius: 10px; padding: 9px 22px; box-shadow: none; text-shadow: none; -gtk-icon-shadow: none; }
button:hover { background-color: alpha(#ffffff, 0.18); }
button.primario { background-color: %(accento)s; font-weight: bold; }
button.primario:hover { background-color: shade(%(accento)s, 1.15); }
button.primario:disabled { background-color: alpha(#ffffff, 0.10); color: alpha(#ffffff, 0.4); }
button.tondo { border-radius: 999px; padding: 14px; min-width: 28px; min-height: 28px; }
.avatar { background-color: %(accento)s; border-radius: 999px; min-width: 96px; min-height: 96px;
          font-size: 36pt; color: #ffffff; }
.tema { padding: 10px; border-radius: 14px; background-color: alpha(#ffffff, 0.05); }
.tema.scelto { box-shadow: inset 0 0 0 3px %(accento)s; }
.anteprima-chiaro { background-color: #f3f3f3; border-radius: 8px; min-width: 180px; min-height: 110px; }
.anteprima-scuro { background-color: #202020; border-radius: 8px; min-width: 180px; min-height: 110px; }
.barretta-chiaro { background-color: #ffffff; border-radius: 6px; margin: 10px; min-height: 60px; }
.barretta-scuro { background-color: #2c2c2c; border-radius: 6px; margin: 10px; min-height: 60px; }
.puntino { border-radius: 999px; min-width: 34px; min-height: 34px; padding: 0; }
.puntino.scelto { box-shadow: 0 0 0 3px #ffffff; }
.app { padding: 12px 16px; border-radius: 12px; background-color: alpha(#ffffff, 0.05); }
.app.scelto { background-color: alpha(%(accento)s, 0.35); box-shadow: inset 0 0 0 2px %(accento)s; }
.app-nome { font-weight: bold; font-size: 11pt; }
.app-desc { font-size: 9pt; color: alpha(#ffffff, 0.65); }
progressbar trough { background-color: alpha(#ffffff, 0.12); border: none; border-radius: 999px; min-height: 8px; }
progressbar progress { background-color: %(accento)s; border: none; border-radius: 999px; min-height: 8px; }
.sottile trough, .sottile progress { min-height: 4px; }
.consiglio { font-size: 11pt; color: alpha(#ffffff, 0.8); }
.piede { font-size: 9pt; color: alpha(#ffffff, 0.55); }
"""


class Benvenuto(Gtk.Window):
    def __init__(self):
        super().__init__(title="Termux On DeX")
        self.set_decorated(False)
        # proposta: la lingua del telefono, se è tra quelle del desktop
        proposta = os.environ.get("TOD_BV_LINGUA", lingua)
        if proposta not in dict(LINGUE):
            proposta = lingua
        self.risposte = {"lingua": proposta, "nome": os.environ.get("TOD_BV_NOME", ""),
                         "utente": os.environ.get("TOD_BV_UTENTE", ""), "tema": "chiaro", "accento": "blu",
                         "app": [i for i, _, on in app_catalogo() if on]}
        self.css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), self.css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.colora()
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT, transition_duration=350,
                               hhomogeneous=False, vhomogeneous=False)   # ogni pagina con la sua misura
        self.add(self.stack)
        self.stato = {}
        self.consiglio_n = 0
        self.saluto_n = 0
        self.connect("key-press-event", self.tasto)
        scr = Gdk.Screen.get_default()
        scr.connect("size-changed", lambda *_: self.adatta())
        if SOLO_AVANZAMENTO:
            self.costruisci_dopo_lingua()
            self.vai("installa", animato=False)
        else:
            self.stack.add_named(self.pagina_saluto(), "saluto")
            self.stack.add_named(self.pagina_lingua(), "lingua")
            self.vai("saluto", animato=False)
        if os.environ.get("TOD_BV_PROVA_PAGINA"):   # per le prove: si apre direttamente su quella pagina
            if not SOLO_AVANZAMENTO:
                self.costruisci_dopo_lingua()
            self.vai(os.environ["TOD_BV_PROVA_PAGINA"], animato=False)
        self.adatta()
        self.show_all()
        GLib.timeout_add(500, self.aggiorna)
        GLib.timeout_add(2200, self.cambia_saluto)
        GLib.timeout_add(700, self.davanti)

    def davanti(self):
        """Senza window manager l'ultima finestra aperta va sopra: le prove della grafica (finestre di
        glxinfo e glmark2 sullo stesso schermo) devono restare dietro."""
        gw = self.get_window()
        if gw is not None:
            gw.raise_()
        return True

    # --- finestra a tutto schermo, senza window manager ---------------------------------
    def adatta(self):
        w, h = larghezza(), altezza()
        self.move(0, 0)
        self.resize(w, h)
        self.set_size_request(w, h)
        return False

    def colora(self):
        hexa = dict((a[0], a[1]) for a in ACCENTI).get(self.risposte["accento"], "#0067c0")
        self.css.load_from_data((CSS % {"accento": hexa}).encode())

    def tasto(self, _w, ev):
        if ev.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter) and getattr(self, "avanti", None):
            b = self.avanti.get(self.stack.get_visible_child_name())
            if b is not None and b.get_sensitive():
                b.clicked()
                return True
        return False

    def vai(self, nome, animato=True, indietro=False):
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_RIGHT if indietro
                                       else Gtk.StackTransitionType.SLIDE_LEFT)
        if not animato:
            self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        self.stack.set_visible_child_name(nome)
        figlio = self.stack.get_child_by_name(nome)
        if getattr(figlio, "fuoco", None) is not None:
            GLib.idle_add(figlio.fuoco.grab_focus)

    # --- pezzi comuni --------------------------------------------------------------------
    def cornice(self, titolo, spiega, corpo, avanti_testo=None, avanti=None, indietro=None, nome="",
                indietro_testo=None):
        """Titolo e spiegazione in alto, il contenuto in una scheda al centro, i pulsanti in basso."""
        fuori = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        fuori.set_valign(Gtk.Align.CENTER)
        fuori.set_halign(Gtk.Align.CENTER)
        fuori.set_margin_start(16)
        fuori.set_margin_end(16)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        col.set_size_request(min(720, larghezza() - 48), -1)
        col.pack_start(etichetta(titolo, "titolo", 30), False, False, 0)
        if spiega:
            s = Gtk.Label(label=spiega, xalign=0.5, justify=Gtk.Justification.CENTER)
            s.set_line_wrap(True)
            s.set_max_width_chars(48)   # sennò chiede tutta la riga e su schermi stretti esce dai bordi
            s.get_style_context().add_class("spiega")
            col.pack_start(s, False, False, 0)
        scheda = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        scheda.get_style_context().add_class("scheda")
        scheda.set_margin_top(18)
        scheda.pack_start(corpo, True, True, 0)
        col.pack_start(scheda, False, False, 0)
        tasti = Gtk.Box(spacing=10)
        tasti.set_margin_top(18)
        if indietro:
            b = Gtk.Button(label=indietro_testo or T("Indietro", "Back"))
            b.connect("clicked", lambda *_: indietro())
            tasti.pack_start(b, False, False, 0)
        if avanti:
            b = Gtk.Button(label=avanti_testo or T("Continua", "Continue"))
            b.get_style_context().add_class("primario")
            b.connect("clicked", lambda *_: avanti())
            tasti.pack_end(b, False, False, 0)
            if not hasattr(self, "avanti"):
                self.avanti = {}
            self.avanti[nome] = b
            fuori.bottone = b
        col.pack_start(tasti, False, False, 0)
        col.pack_start(self.barra_piede(), False, False, 0)
        fuori.pack_start(col, False, False, 0)
        return fuori

    def barra_piede(self):
        """Mentre si risponde, l'installazione va avanti: una barra sottile lo fa vedere."""
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_margin_top(28)
        bar = Gtk.ProgressBar()
        bar.get_style_context().add_class("sottile")
        lab = Gtk.Label(xalign=0.5)
        lab.get_style_context().add_class("piede")
        lab.set_ellipsize(Pango.EllipsizeMode.END)
        box.pack_start(bar, False, False, 0)
        box.pack_start(lab, False, False, 0)
        if not hasattr(self, "piedi"):
            self.piedi = []
        self.piedi.append((bar, lab))
        return box

    # --- pagine --------------------------------------------------------------------------
    def pagina_saluto(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        self.saluto_rev = Gtk.Revealer(transition_type=Gtk.RevealerTransitionType.CROSSFADE,
                                       transition_duration=600, reveal_child=True)
        self.saluto = Gtk.Label(label=SALUTI[0])
        self.saluto.get_style_context().add_class("saluto")
        self.saluto_rev.add(self.saluto)
        box.pack_start(self.saluto_rev, False, False, 0)
        disp = os.environ.get("TOD_BV_DISPOSITIVO", "")
        sotto = Gtk.Label(label=("Termux On DeX" + (" · " + disp if disp else "")))
        sotto.get_style_context().add_class("sotto")
        box.pack_start(sotto, False, False, 0)
        b = Gtk.Button()
        b.add(Gtk.Image.new_from_icon_name("go-next-symbolic", Gtk.IconSize.LARGE_TOOLBAR))
        b.get_style_context().add_class("primario")
        b.get_style_context().add_class("tondo")
        b.set_halign(Gtk.Align.CENTER)
        b.set_margin_top(40)
        b.connect("clicked", lambda *_: self.vai("lingua"))
        box.pack_start(b, False, False, 0)
        self.avanti = {"saluto": b}
        box.fuoco = b
        return box

    def cambia_saluto(self):
        if self.stack.get_visible_child_name() != "saluto":
            return True
        self.saluto_rev.set_reveal_child(False)

        def dopo():
            self.saluto_n = (self.saluto_n + 1) % len(SALUTI)
            self.saluto.set_text(SALUTI[self.saluto_n])
            self.saluto_rev.set_reveal_child(True)
            return False
        GLib.timeout_add(650, dopo)
        return True

    def pagina_lingua(self):
        lb = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        lb.set_margin_top(8)
        lb.set_margin_bottom(8)
        scelta = None
        for code, nome in LINGUE:
            r = Gtk.ListBoxRow()
            r.code = code
            r.get_style_context().add_class("riga")
            lab = Gtk.Label(label=nome, xalign=0)
            r.add(lab)
            lb.add(r)
            if code == self.risposte["lingua"]:
                scelta = r
        if scelta is not None:
            lb.select_row(scelta)
        lb.connect("row-activated", lambda _l, _r: self.scegli_lingua(lb))
        p = self.cornice("Lingua · Language", T("Scegli la lingua del desktop.", "Choose the desktop language."),
                         lb, avanti=lambda: self.scegli_lingua(lb), indietro=lambda: self.vai("saluto", indietro=True),
                         nome="lingua")
        p.fuoco = lb
        return p

    def scegli_lingua(self, lb):
        global lingua
        r = lb.get_selected_row()
        if r is None:
            return
        self.risposte["lingua"] = r.code
        lingua = "it" if r.code == "it" else "en"   # le schermate parlano italiano o inglese
        self.costruisci_dopo_lingua()
        self.vai("account")

    def costruisci_dopo_lingua(self):
        for nome in ("account", "aspetto", "app", "installa", "errore", "fatto"):
            vecchia = self.stack.get_child_by_name(nome)
            if vecchia is not None:
                self.stack.remove(vecchia)
        self.piedi = []
        self.stack.add_named(self.pagina_account(), "account")
        self.stack.add_named(self.pagina_aspetto(), "aspetto")
        self.stack.add_named(self.pagina_app(), "app")
        self.stack.add_named(self.pagina_installa(), "installa")
        self.stack.add_named(self.pagina_errore(), "errore")
        self.stack.add_named(self.pagina_fatto(), "fatto")
        self.stack.show_all()
        self.aggiorna()

    def pagina_account(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_top(22)
        box.set_margin_bottom(22)
        box.set_margin_start(40)
        box.set_margin_end(40)
        self.avatar = Gtk.Label(label="?")
        self.avatar.get_style_context().add_class("avatar")
        self.avatar.set_halign(Gtk.Align.CENTER)
        box.pack_start(self.avatar, False, False, 6)
        l1 = Gtk.Label(label=T("Nome completo", "Full name"), xalign=0)
        l1.get_style_context().add_class("etichetta")
        self.e_nome = Gtk.Entry(text=self.risposte["nome"])
        l2 = Gtk.Label(label=T("Nome utente (la tua cartella)", "User name (your folder)"), xalign=0)
        l2.get_style_context().add_class("etichetta")
        self.e_utente = Gtk.Entry(text=self.risposte["utente"])
        self.utente_toccato = bool(self.risposte["utente"])
        self.e_err = Gtk.Label(xalign=0)
        self.e_err.get_style_context().add_class("errore-testo")
        for w in (l1, self.e_nome, l2, self.e_utente, self.e_err):
            box.pack_start(w, False, False, 0)
        l2.set_margin_top(8)
        self.e_nome.connect("changed", self.nome_cambiato)
        self.e_utente.connect("changed", self.utente_cambiato)
        self.e_nome.connect("activate", lambda *_: self.e_utente.grab_focus())
        p = self.cornice(T("Il tuo account", "Your account"),
                         T("Il nome che vedrai nel desktop e quello della tua cartella personale.",
                           "The name shown on the desktop and the name of your home folder."),
                         box, avanti=self.conferma_account, indietro=lambda: self.vai("lingua", indietro=True),
                         nome="account")
        p.fuoco = self.e_nome
        self.bottone_account = p.bottone
        self.verifica_account()
        return p

    def nome_cambiato(self, *_):
        if not self.utente_toccato:
            self.e_utente.handler_block_by_func(self.utente_cambiato)
            self.e_utente.set_text(nome_utente(self.e_nome.get_text()))
            self.e_utente.handler_unblock_by_func(self.utente_cambiato)
        self.verifica_account()

    def utente_cambiato(self, *_):
        self.utente_toccato = bool(self.e_utente.get_text())
        self.verifica_account()

    def verifica_account(self):
        n, u = self.e_nome.get_text().strip(), self.e_utente.get_text()
        self.avatar.set_text((n[:1] or u[:1] or "?").upper())
        ok = bool(n) and utente_valido(u)
        if u and not utente_valido(u):
            self.e_err.set_text(T("Solo lettere minuscole, cifre, - e _, e deve iniziare con una lettera.",
                                  "Lowercase letters, digits, - and _ only, starting with a letter."))
        else:
            self.e_err.set_text("")
        self.bottone_account.set_sensitive(ok)

    def conferma_account(self):
        self.risposte["nome"] = self.e_nome.get_text().strip()
        self.risposte["utente"] = self.e_utente.get_text()
        self.vai("aspetto")

    def pagina_aspetto(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        box.set_margin_top(24)
        box.set_margin_bottom(24)
        temi = Gtk.Box(spacing=24, halign=Gtk.Align.CENTER)
        self.temi = {}
        for chiave, nome in (("chiaro", T("Chiaro", "Light")), ("scuro", T("Scuro", "Dark"))):
            ev = Gtk.EventBox()
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            col.get_style_context().add_class("tema")
            ant = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            ant.get_style_context().add_class("anteprima-" + chiave)
            bar = Gtk.Box()
            bar.get_style_context().add_class("barretta-" + chiave)
            ant.pack_start(bar, True, True, 0)
            col.pack_start(ant, False, False, 0)
            col.pack_start(Gtk.Label(label=nome), False, False, 0)
            ev.add(col)
            ev.connect("button-press-event", lambda _w, _e, k=chiave: self.scegli_tema(k))
            temi.pack_start(ev, False, False, 0)
            self.temi[chiave] = col
        box.pack_start(temi, False, False, 0)
        lab = Gtk.Label(label=T("Colore", "Colour"))
        lab.get_style_context().add_class("etichetta")
        box.pack_start(lab, False, False, 0)
        punti = Gtk.Box(spacing=12, halign=Gtk.Align.CENTER)
        self.punti = {}
        prov = Gtk.CssProvider()
        prov.load_from_data("".join(".p-%s { background-color: %s; }" % (a[0], a[1]) for a in ACCENTI).encode())
        for chiave, _hex, it, en in ACCENTI:
            b = Gtk.Button()
            b.set_tooltip_text(T(it, en))
            sc = b.get_style_context()
            sc.add_provider(prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
            sc.add_class("puntino")
            sc.add_class("p-" + chiave)
            b.connect("clicked", lambda _b, k=chiave: self.scegli_accento(k))
            punti.pack_start(b, False, False, 0)
            self.punti[chiave] = b
        box.pack_start(punti, False, False, 0)
        self.scegli_tema(self.risposte["tema"])
        self.scegli_accento(self.risposte["accento"], ricolora=False)
        return self.cornice(T("Aspetto", "Appearance"),
                            T("Potrai cambiarlo quando vuoi da Impostazioni.", "You can change it any time in Settings."),
                            box, avanti=lambda: self.vai("app"), indietro=lambda: self.vai("account", indietro=True),
                            nome="aspetto")

    def scegli_tema(self, k):
        self.risposte["tema"] = k
        for chiave, w in self.temi.items():
            (w.get_style_context().add_class if chiave == k else w.get_style_context().remove_class)("scelto")
        return True

    def scegli_accento(self, k, ricolora=True):
        self.risposte["accento"] = k
        for chiave, w in self.punti.items():
            (w.get_style_context().add_class if chiave == k else w.get_style_context().remove_class)("scelto")
        if ricolora:
            self.colora()

    def pagina_app(self):
        grid = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=2, min_children_per_line=1,
                           column_spacing=10, row_spacing=10, homogeneous=True)
        grid.set_margin_top(16)
        grid.set_margin_bottom(16)
        grid.set_margin_start(16)
        grid.set_margin_end(16)
        self.app_box = {}
        for ident, nome, _on in app_catalogo():
            ev = Gtk.EventBox()
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            col.get_style_context().add_class("app")
            n = Gtk.Label(label=nome, xalign=0)
            n.get_style_context().add_class("app-nome")
            d = Gtk.Label(label=T(*APP_DESC.get(ident, ("", ""))), xalign=0)
            d.get_style_context().add_class("app-desc")
            d.set_ellipsize(Pango.EllipsizeMode.END)
            col.pack_start(n, False, False, 0)
            col.pack_start(d, False, False, 0)
            ev.add(col)
            ev.connect("button-press-event", lambda _w, _e, i=ident: self.cambia_app(i))
            grid.add(ev)
            self.app_box[ident] = col
            if ident in self.risposte["app"]:
                col.get_style_context().add_class("scelto")
        p = self.cornice(T("App", "Apps"),
                         T("Scegli le app da avere subito. Le altre le installi quando vuoi da Software.",
                           "Pick the apps you want right away. Install others any time from Software."),
                         grid, avanti_testo=T("Installa", "Install"), avanti=self.fine_domande,
                         indietro=lambda: self.vai("aspetto", indietro=True), nome="app")
        return p

    def cambia_app(self, ident):
        sc = self.app_box[ident].get_style_context()
        if ident in self.risposte["app"]:
            self.risposte["app"].remove(ident)
            sc.remove_class("scelto")
        else:
            self.risposte["app"].append(ident)
            sc.add_class("scelto")
        return True

    def fine_domande(self):
        scrivi("risposte.json", json.dumps(self.risposte, ensure_ascii=False))
        self.vai("installa")

    def pagina_installa(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        box.set_size_request(min(640, larghezza() - 48), -1)
        box.set_margin_start(24)
        box.set_margin_end(24)
        box.pack_start(etichetta(T("Stiamo preparando il tuo desktop", "Setting up your desktop"), "titolo", 30),
                       False, False, 0)
        box.pack_start(etichetta(T("Puoi lasciare il telefono collegato alla corrente: ci vuole un po'.",
                                   "Keep the phone on the charger: this takes a while."), "spiega", 48), False, False, 0)
        self.barra = Gtk.ProgressBar()
        self.barra.set_margin_top(26)
        box.pack_start(self.barra, False, False, 0)
        self.passo = Gtk.Label(xalign=0.5)
        self.passo.get_style_context().add_class("spiega")
        self.passo.set_ellipsize(Pango.EllipsizeMode.END)
        box.pack_start(self.passo, False, False, 0)
        self.consiglio = etichetta("", "consiglio", 48)
        self.consiglio.set_margin_top(48)
        self.consiglio_rev = Gtk.Revealer(transition_type=Gtk.RevealerTransitionType.CROSSFADE,
                                          transition_duration=500, reveal_child=True)
        self.consiglio_rev.add(self.consiglio)
        box.pack_start(self.consiglio_rev, False, False, 0)
        self.mostra_consiglio()
        GLib.timeout_add_seconds(9, self.prossimo_consiglio)
        return box

    def mostra_consiglio(self):
        self.consiglio.set_text(T(*CONSIGLI[self.consiglio_n % len(CONSIGLI)]))

    def prossimo_consiglio(self):
        self.consiglio_rev.set_reveal_child(False)

        def dopo():
            self.consiglio_n += 1
            self.mostra_consiglio()
            self.consiglio_rev.set_reveal_child(True)
            return False
        GLib.timeout_add(550, dopo)
        return True

    def pagina_errore(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_top(18)
        box.set_margin_bottom(18)
        box.set_margin_start(22)
        box.set_margin_end(22)
        self.err_testo = Gtk.Label(xalign=0)
        self.err_testo.set_line_wrap(True)
        box.pack_start(self.err_testo, False, False, 0)
        sw = Gtk.ScrolledWindow()
        sw.set_size_request(-1, 160)
        self.err_log = Gtk.Label(xalign=0, yalign=0, selectable=True)
        self.err_log.get_style_context().add_class("piede")
        self.err_log.set_line_wrap(True)
        sw.add(self.err_log)
        box.pack_start(sw, True, True, 0)
        p = self.cornice(T("Qualcosa non è andato", "Something went wrong"),
                         T("Spesso basta riprovare (per esempio se è mancata la rete).",
                           "Retrying is often enough (for example after a network hiccup)."),
                         box, avanti_testo=T("Riprova", "Try again"), avanti=lambda: self.comando("riprova"),
                         indietro=lambda: self.comando("esci"), nome="errore", indietro_testo=T("Esci", "Quit"))
        return p

    def pagina_fatto(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        self.fatto_titolo = Gtk.Label(justify=Gtk.Justification.CENTER)
        self.fatto_titolo.set_line_wrap(True)
        self.fatto_titolo.get_style_context().add_class("saluto")
        box.pack_start(self.fatto_titolo, False, False, 0)
        box.pack_start(etichetta(T("Il tuo desktop è pronto.", "Your desktop is ready."), "sotto"), False, False, 0)
        b = Gtk.Button(label=T("Inizia", "Get started"))
        b.get_style_context().add_class("primario")
        b.set_halign(Gtk.Align.CENTER)
        b.set_margin_top(36)
        b.connect("clicked", lambda *_: self.comando("avvia"))
        box.pack_start(b, False, False, 0)
        self.avanti["fatto"] = b
        box.fuoco = b
        return box

    def comando(self, c):
        # lo stato di adesso (errore, fatto) è già stato gestito: si aspetta quello nuovo dell'installazione
        self.stato_visto = leggi_stato()
        scrivi("comando", c + "\n")
        if c == "riprova":
            self.vai("installa", indietro=True)
        elif c == "avvia":
            self.copri()
        elif c == "esci":
            GLib.timeout_add(300, Gtk.main_quit)

    def copri(self):
        """Dopo "Inizia" il desktop parte qui sotto: una copertura (fuori dal window manager, sempre
        sopra) lo nasconde finché l'hook della sessione non ha sistemato icone, cartelle e aspetto."""
        c = Gtk.Window(type=Gtk.WindowType.POPUP)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=22)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        sp = Gtk.Spinner()
        sp.set_size_request(48, 48)
        sp.start()
        box.pack_start(sp, False, False, 0)
        box.pack_start(etichetta(T("Avvio del desktop…", "Starting the desktop…"), "sotto"), False, False, 0)
        c.add(box)
        c.move(0, 0)
        c.resize(larghezza(), altezza())
        c.set_size_request(larghezza(), altezza())
        c.show_all()
        self.copertura = c
        self.hide()
        self.coperta_da = GLib.get_monotonic_time()
        GLib.timeout_add(500, self.attendi_desktop)

    def davanti_copertura(self):
        gw = self.copertura.get_window()
        if gw is not None:
            gw.raise_()

    def attendi_desktop(self):
        self.davanti_copertura()
        passati = (GLib.get_monotonic_time() - self.coperta_da) / 1e6
        if (PRONTO and os.path.exists(PRONTO)) or passati > 150:
            # un attimo ancora: il desktop ridisegna icone e sfondo appena sistemati
            GLib.timeout_add(1500, Gtk.main_quit)
            return False
        return True

    # --- l'installazione, letta dal file di stato ------------------------------------------
    def aggiorna(self):
        st = leggi_stato()
        try:
            pct = max(0, min(100, int(st.get("pct", "0") or 0)))
        except ValueError:
            pct = 0
        passo = nome_passo(st.get("passo", ""))
        for bar, lab in getattr(self, "piedi", []):
            bar.set_fraction(pct / 100)
            lab.set_text(f"{passo} · {pct}%")
        if hasattr(self, "barra"):
            self.barra.set_fraction(pct / 100)
            self.passo.set_text(f"{passo} · {pct}%")
        fase = st.get("fase", "lavoro")
        if st == getattr(self, "stato_visto", None):
            fase = "lavoro"
        visibile = self.stack.get_visible_child_name()
        if fase == "errore" and visibile == "installa":
            self.err_testo.set_text(T("Non è riuscito: %s.", "This did not work: %s.") % nome_passo(st.get("errore", "")).lower())
            try:
                with open(st.get("log", ""), encoding="utf-8", errors="replace") as f:
                    self.err_log.set_text("".join(f.readlines()[-14:]))
            except OSError:
                self.err_log.set_text("")
            self.vai("errore")
        elif fase == "fatto" and visibile == "installa":
            nome = (self.risposte.get("nome") or "").split(" ")[0]
            self.fatto_titolo.set_text(T("Tutto pronto", "All set") + (f", {nome}" if nome else ""))
            self.vai("fatto")
        return True


def main():
    os.makedirs(DIR, exist_ok=True)
    w = Benvenuto()
    w.connect("destroy", Gtk.main_quit)
    Gtk.main()


if __name__ == "__main__":
    main()
