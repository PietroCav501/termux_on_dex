#!/usr/bin/env python3
"""Bordi invisibili per ridimensionare, come Windows 11.

  tod-edges.py            (lo avvia l'hook di sessione; una sola copia)

xfwm4 ridimensiona solo dove la cornice è disegnata: con un bordo elegante da 1 px bisognerebbe
mirare al pixel (Pietro: "devo essere iper preciso"), con 4-6 px si vede una cornice. Qui, attorno
alla finestra attiva, si mettono 8 strisce invisibili (InputOnly: non disegnano niente) larghe
GRAB px, appena fuori dal bordo: il cursore diventa quello di ridimensionamento e, al clic, la
finestra passa a xfwm4 con _NET_WM_MOVERESIZE (lo stesso che usano le app con la barra propria).
Niente strisce per finestre ingrandite, a schermo intero, non ridimensionabili, menu e pannelli,
né per quelle che hanno già i loro bordi invisibili (_GTK_FRAME_EXTENTS: app Electron, app GTK con
la barra propria). Solo ctypes e libX11.
"""
import ctypes
import ctypes.util
import os
import signal
import sys

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
TMP = os.environ.get("TMPDIR", os.path.join(PREFIX, "tmp"))
PIDFILE = os.path.join(TMP, "tod-edges.pid")
DEBUG = bool(os.environ.get("TOD_EDGES_DEBUG"))


def dbg(*a):
    if DEBUG:
        print("tod-edges:", *a, file=sys.stderr, flush=True)

ButtonPress, ConfigureNotify, UnmapNotify, MapNotify, PropertyNotify = 4, 22, 18, 19, 28
ButtonPressMask, StructureNotifyMask, PropertyChangeMask = 1 << 2, 1 << 17, 1 << 22
SubstructureNotifyMask, SubstructureRedirectMask = 1 << 19, 1 << 20   # per _NET_WM_MOVERESIZE
InputOnly, CWOverrideRedirect, CWEventMask, CWCursor = 2, 1 << 9, 1 << 11, 1 << 14
ClientMessage = 33

# (direzione _NET_WM_MOVERESIZE, cursore X) per: in alto a sx, in alto, in alto a dx, dx, in basso a dx,
# in basso, in basso a sx, sx
EDGES = [(0, 134), (1, 138), (2, 136), (3, 96), (4, 14), (5, 16), (6, 12), (7, 70)]


class XSetWindowAttributes(ctypes.Structure):
    _fields_ = [("background_pixmap", ctypes.c_ulong), ("background_pixel", ctypes.c_ulong),
                ("border_pixmap", ctypes.c_ulong), ("border_pixel", ctypes.c_ulong),
                ("bit_gravity", ctypes.c_int), ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int),
                ("backing_planes", ctypes.c_ulong), ("backing_pixel", ctypes.c_ulong),
                ("save_under", ctypes.c_int), ("event_mask", ctypes.c_long),
                ("do_not_propagate_mask", ctypes.c_long), ("override_redirect", ctypes.c_int),
                ("colormap", ctypes.c_ulong), ("cursor", ctypes.c_ulong)]


class XAnyEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong)]


class XButtonEvent(ctypes.Structure):
    _fields_ = XAnyEvent._fields_ + [("root", ctypes.c_ulong), ("subwindow", ctypes.c_ulong),
                                     ("time", ctypes.c_ulong), ("x", ctypes.c_int), ("y", ctypes.c_int),
                                     ("x_root", ctypes.c_int), ("y_root", ctypes.c_int),
                                     ("state", ctypes.c_uint), ("button", ctypes.c_uint)]


class XClientMessageEvent(ctypes.Structure):
    _fields_ = XAnyEvent._fields_ + [("message_type", ctypes.c_ulong), ("format", ctypes.c_int),
                                     ("data", ctypes.c_long * 5)]


class XEvent(ctypes.Union):
    _fields_ = [("type", ctypes.c_int), ("xany", XAnyEvent), ("xbutton", XButtonEvent),
                ("xclient", XClientMessageEvent), ("pad", ctypes.c_long * 24)]


def load_x11():
    for name in (os.path.join(PREFIX, "lib/libX11.so"), ctypes.util.find_library("X11") or "", "libX11.so.6"):
        if name:
            try:
                return ctypes.CDLL(name)
            except OSError:
                pass
    return None


class Edges:
    def __init__(self, x, grab):
        self.x, self.grab = x, grab
        P, U, I, V = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_uint
        sig = {
            "XOpenDisplay": (P, [ctypes.c_char_p]), "XDefaultRootWindow": (U, [P]),
            "XInternAtom": (U, [P, ctypes.c_char_p, I]),
            "XGetWindowProperty": (I, [P, U, U, ctypes.c_long, ctypes.c_long, I, U, ctypes.POINTER(U),
                                       ctypes.POINTER(I), ctypes.POINTER(U), ctypes.POINTER(U), ctypes.POINTER(P)]),
            "XFree": (I, [P]), "XCreateFontCursor": (U, [P, V]),
            "XCreateWindow": (U, [P, U, I, I, V, V, V, I, V, P, U, ctypes.POINTER(XSetWindowAttributes)]),
            "XMoveResizeWindow": (I, [P, U, I, I, V, V]), "XMapRaised": (I, [P, U]), "XUnmapWindow": (I, [P, U]),
            "XSelectInput": (I, [P, U, ctypes.c_long]), "XNextEvent": (I, [P, ctypes.POINTER(XEvent)]),
            "XSendEvent": (I, [P, U, I, ctypes.c_long, ctypes.POINTER(XEvent)]),
            "XUngrabPointer": (I, [P, U]), "XFlush": (I, [P]), "XSync": (I, [P, I]),
            "XQueryTree": (I, [P, U, ctypes.POINTER(U), ctypes.POINTER(U), ctypes.POINTER(P), ctypes.POINTER(V)]),
            "XGetGeometry": (I, [P, U, ctypes.POINTER(U), ctypes.POINTER(I), ctypes.POINTER(I), ctypes.POINTER(V),
                                 ctypes.POINTER(V), ctypes.POINTER(V), ctypes.POINTER(V)]),
            "XSetErrorHandler": (P, [P]),
            "XChangeProperty": (I, [P, U, U, U, I, I, ctypes.POINTER(ctypes.c_long), I]),
        }
        for name, (res, args) in sig.items():
            f = getattr(x, name)
            f.restype, f.argtypes = res, args
        self.dpy = x.XOpenDisplay(None)
        if not self.dpy:
            raise OSError("display")
        # finestre che spariscono a metà di una domanda: errori X ignorati, non fatali
        self._err = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)(lambda d, e: 0)
        x.XSetErrorHandler(ctypes.cast(self._err, ctypes.c_void_p))
        self.root = x.XDefaultRootWindow(self.dpy)
        if not grab:   # 8 px a 96 dpi, in proporzione con il desktop (Xft.dpi, come il testo)
            x.XResourceManagerString.restype, x.XResourceManagerString.argtypes = ctypes.c_char_p, [P]
            res = (x.XResourceManagerString(self.dpy) or b"").decode(errors="replace")
            dpi = next((float(l.split(":", 1)[1]) for l in res.splitlines()
                        if l.startswith("Xft.dpi:") and l.split(":", 1)[1].strip().replace(".", "", 1).isdigit()), 96.0)
            self.grab = grab = max(6, int(round(8 * dpi / 96)))
        self.atoms = {}
        self.wins = []
        for direction, shape in EDGES:
            a = XSetWindowAttributes()
            a.override_redirect = 1
            a.event_mask = ButtonPressMask
            a.cursor = x.XCreateFontCursor(self.dpy, shape)
            w = x.XCreateWindow(self.dpy, self.root, 0, 0, 1, 1, 0, 0, InputOnly, None,
                                CWOverrideRedirect | CWEventMask | CWCursor, ctypes.byref(a))
            self.wins.append((w, direction))
        self.target = self.frame = 0
        self.shown = False
        x.XSelectInput(self.dpy, self.root, PropertyChangeMask)

    def atom(self, name):
        if name not in self.atoms:
            self.atoms[name] = self.x.XInternAtom(self.dpy, name.encode(), 0)
        return self.atoms[name]

    def prop(self, win, name):
        """Valori (32 bit) della proprietà, o None se manca."""
        typ, fmt = ctypes.c_ulong(), ctypes.c_int()
        n, after, data = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        if self.x.XGetWindowProperty(self.dpy, win, self.atom(name), 0, 64, 0, 0, ctypes.byref(typ),
                                     ctypes.byref(fmt), ctypes.byref(n), ctypes.byref(after),
                                     ctypes.byref(data)) != 0 or not data.value:
            return None
        try:
            if fmt.value != 32:
                return []
            return list(ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[:n.value])
        finally:
            self.x.XFree(data)

    def toplevel(self, win):
        """La finestra figlia della radice che contiene win (la cornice di xfwm4)."""
        root, parent = ctypes.c_ulong(), ctypes.c_ulong()
        kids, n = ctypes.c_void_p(), ctypes.c_uint()
        while win:
            if not self.x.XQueryTree(self.dpy, win, ctypes.byref(root), ctypes.byref(parent),
                                     ctypes.byref(kids), ctypes.byref(n)):
                return 0
            if kids.value:
                self.x.XFree(kids)
            if parent.value == root.value:
                return win
            win = parent.value
        return 0

    def geometry(self, win):
        root, x, y = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_int()
        w, h, b, d = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
        if not self.x.XGetGeometry(self.dpy, win, ctypes.byref(root), ctypes.byref(x), ctypes.byref(y),
                                   ctypes.byref(w), ctypes.byref(h), ctypes.byref(b), ctypes.byref(d)):
            return None
        return x.value, y.value, w.value, h.value

    def wanted(self, win):
        """La finestra attiva va servita? (normale o dialogo, ridimensionabile, non ingrandita)"""
        if not win or self.prop(win, "_GTK_FRAME_EXTENTS") is not None:
            return False
        types = self.prop(win, "_NET_WM_WINDOW_TYPE") or []
        if types and not ({self.atom("_NET_WM_WINDOW_TYPE_NORMAL"), self.atom("_NET_WM_WINDOW_TYPE_DIALOG")} & set(types)):
            return False
        state = set(self.prop(win, "_NET_WM_STATE") or [])
        if {self.atom("_NET_WM_STATE_FULLSCREEN"), self.atom("_NET_WM_STATE_HIDDEN")} & state:
            return False
        if {self.atom("_NET_WM_STATE_MAXIMIZED_VERT"), self.atom("_NET_WM_STATE_MAXIMIZED_HORZ")} <= state:
            return False
        hints = self.prop(win, "WM_NORMAL_HINTS") or []   # XSizeHints: flags, ..., min (5,6), max (7,8)
        if len(hints) > 8 and hints[0] & 16 and hints[0] & 32 and hints[5:7] == hints[7:9]:
            return False   # dimensione fissa
        return True

    def hide(self):
        if self.shown:
            for w, _d in self.wins:
                self.x.XUnmapWindow(self.dpy, w)
            self.shown = False

    def update(self):
        active = (self.prop(self.root, "_NET_ACTIVE_WINDOW") or [0])[0]
        # la cornice si cerca ogni volta: X riusa gli identificativi, e una finestra nuova può avere quello
        # di una appena chiusa (la cornice vecchia non esiste più)
        frame = self.toplevel(active) if active else 0
        if active != self.target or frame != self.frame:
            self.target = active
            if frame and frame != active:
                self.x.XSelectInput(self.dpy, frame, StructureNotifyMask)   # spostata, ridimensionata
            if active:
                self.x.XSelectInput(self.dpy, active, PropertyChangeMask)   # ingrandita, a schermo intero
            self.frame = frame
        if not self.frame or not self.wanted(self.target):
            dbg("niente strisce per", hex(self.target))
            self.hide()
            return
        geo = self.geometry(self.frame)
        if not geo:
            self.hide()
            return
        fx, fy, fw, fh = geo
        g, c = self.grab, self.grab * 2   # c: lato degli angoli, più comodi da prendere
        area = self.prop(self.root, "_NET_WORKAREA") or []
        ax, ay, aw, ah = area[:4] if len(area) >= 4 else (-10**6, -10**6, 2 * 10**6, 2 * 10**6)
        rects = {   # direzione → (x, y, w, h) appena fuori dal bordo
            0: (fx - g, fy - g, c, c), 1: (fx + c - g, fy - g, fw - 2 * c + 2 * g, g),
            2: (fx + fw - c + g, fy - g, c, c), 3: (fx + fw, fy + c - g, g, fh - 2 * c + 2 * g),
            4: (fx + fw - c + g, fy + fh - c + g, c, c), 5: (fx + c - g, fy + fh, fw - 2 * c + 2 * g, g),
            6: (fx - g, fy + fh - c + g, c, c), 7: (fx - g, fy + c - g, g, fh - 2 * c + 2 * g),
        }
        for w, d in self.wins:
            x, y, ww, hh = rects[d]
            # mai sopra la barra delle app: si taglia all'area di lavoro
            x0, y0 = max(x, ax), max(y, ay)
            x1, y1 = min(x + ww, ax + aw), min(y + hh, ay + ah)
            if x1 - x0 < 1 or y1 - y0 < 1:
                self.x.XUnmapWindow(self.dpy, w)
                continue
            self.x.XMoveResizeWindow(self.dpy, w, x0, y0, x1 - x0, y1 - y0)
            self.x.XMapRaised(self.dpy, w)
        self.shown = True
        dbg("strisce attorno a", hex(self.target), "cornice", (fx, fy, fw, fh))

    def start_resize(self, ev, direction):
        self.x.XUngrabPointer(self.dpy, 0)
        # xfwm4 prende il mouse con l'ora dell'ultimo evento che ha visto: senza questo è più vecchia
        # del nostro clic e il server X rifiuta la presa (il ridimensionamento non partiva). Una
        # proprietà cambiata sulla radice gli fa vedere un evento con l'ora attuale, prima del messaggio.
        stamp = (ctypes.c_long * 1)(ev.time)
        self.x.XChangeProperty(self.dpy, self.root, self.atom("_TOD_EDGES_TIME"), 6, 32, 0, stamp, 1)
        msg = XEvent()
        msg.xclient.type = ClientMessage
        msg.xclient.window = self.target
        msg.xclient.message_type = self.atom("_NET_WM_MOVERESIZE")
        msg.xclient.format = 32
        for i, v in enumerate((ev.x_root, ev.y_root, direction, ev.button, 1)):
            msg.xclient.data[i] = v
        self.x.XSendEvent(self.dpy, self.root, 0, SubstructureRedirectMask | SubstructureNotifyMask, ctypes.byref(msg))
        self.x.XFlush(self.dpy)

    def run(self):
        self.update()
        self.x.XFlush(self.dpy)
        ev = XEvent()
        mine = {w: d for w, d in self.wins}
        watched = (self.atom("_NET_ACTIVE_WINDOW"), self.atom("_NET_WM_STATE"), self.atom("_NET_WORKAREA"))
        while True:
            self.x.XNextEvent(self.dpy, ctypes.byref(ev))
            t, win = ev.type, ev.xany.window
            if t == ButtonPress:
                dbg("clic su", hex(win), "nostra" if win in mine else "non nostra", ev.xbutton.button)
            if t == ButtonPress and win in mine and ev.xbutton.button == 1:
                self.start_resize(ev.xbutton, mine[win])
                continue
            # il 6° campo è l'atomo (PropertyNotify) o la finestra cambiata (Configure/Map/Unmap)
            field = ctypes.cast(ctypes.byref(ev), ctypes.POINTER(ctypes.c_ulong))[5]
            if t == PropertyNotify:
                if field not in watched or win not in (self.root, self.target):
                    continue
            elif t in (ConfigureNotify, MapNotify, UnmapNotify):
                if field != self.frame:
                    continue
            else:
                continue
            self.update()
            self.x.XFlush(self.dpy)


def main():
    try:   # una copia sola: la nuova sessione sostituisce quella vecchia
        old = int(open(PIDFILE).read().strip())
        if old != os.getpid() and "tod-edges" in open(f"/proc/{old}/cmdline").read():
            os.kill(old, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    lib = load_x11()
    if not lib:
        return 1
    Edges(lib, 0).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
