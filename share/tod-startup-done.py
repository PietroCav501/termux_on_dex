#!/usr/bin/env python3
"""Spegne il cursore di attesa appena compare la finestra dell'app.

  tod-startup-done.py <DESKTOP_STARTUP_ID>

Le app del container ricevono l'id di avvio, ma molte (Electron, WebKit come i
launcher) non mandano il "remove" della startup notification: il cursore restava acceso fino
alla scadenza. Qui si guarda l'elenco delle finestre: alla prima finestra nuova, o a quella con
il nostro _NET_STARTUP_ID, si manda noi "remove: ID=..." (spec freedesktop startup-notification).
Solo ctypes e libX11: nessun pacchetto in più. Si arrende dopo 90 s.
"""
import ctypes
import ctypes.util
import os
import sys
import time

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
TIMEOUT = 90
ClientMessage = 33
PropertyChangeMask = 1 << 22


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", ctypes.c_char * 40)]


class XEvent(ctypes.Union):
    _fields_ = [("xclient", XClientMessageEvent), ("pad", ctypes.c_long * 24)]


def load_x11():
    for name in (os.path.join(PREFIX, "lib/libX11.so"), ctypes.util.find_library("X11") or "", "libX11.so.6"):
        if name:
            try:
                return ctypes.CDLL(name)
            except OSError:
                pass
    return None


class X:
    def __init__(self, lib):
        self.x = lib
        lib.XOpenDisplay.restype = ctypes.c_void_p
        lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        lib.XDefaultRootWindow.restype = ctypes.c_ulong
        lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        lib.XInternAtom.restype = ctypes.c_ulong
        lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        lib.XGetWindowProperty.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int,
            ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]
        lib.XFree.argtypes = [ctypes.c_void_p]
        lib.XCreateSimpleWindow.restype = ctypes.c_ulong
        lib.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong] + [ctypes.c_int] * 2 + \
            [ctypes.c_uint] * 3 + [ctypes.c_ulong] * 2
        lib.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long,
                                   ctypes.POINTER(XEvent)]
        lib.XFlush.argtypes = [ctypes.c_void_p]
        lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.dpy = lib.XOpenDisplay(None)
        if not self.dpy:
            raise OSError("display")
        self.root = lib.XDefaultRootWindow(self.dpy)

    def atom(self, name):
        return self.x.XInternAtom(self.dpy, name.encode(), 0)

    def prop(self, win, name, want_windows=False):
        typ, fmt = ctypes.c_ulong(), ctypes.c_int()
        n, after, data = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        if self.x.XGetWindowProperty(self.dpy, win, self.atom(name), 0, 4096, 0, 0, ctypes.byref(typ),
                                     ctypes.byref(fmt), ctypes.byref(n), ctypes.byref(after),
                                     ctypes.byref(data)) != 0 or not data.value:
            return [] if want_windows else None
        try:
            if want_windows and fmt.value == 32:
                return list(ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[:n.value])
            if fmt.value == 8:
                return ctypes.string_at(data, n.value).decode("utf-8", "replace")
            return [] if want_windows else None
        finally:
            self.x.XFree(data)

    def clients(self):
        return set(self.prop(self.root, "_NET_CLIENT_LIST", want_windows=True))

    def startup_remove(self, sid):
        val = sid.replace("\\", "\\\\").replace('"', '\\"')
        msg = f'remove: ID="{val}"'.encode() + b"\0"
        win = self.x.XCreateSimpleWindow(self.dpy, self.root, -100, -100, 1, 1, 0, 0, 0)
        begin, more = self.atom("_NET_STARTUP_INFO_BEGIN"), self.atom("_NET_STARTUP_INFO")
        for i in range(0, len(msg), 20):
            ev = XEvent()
            ev.xclient.type = ClientMessage
            ev.xclient.send_event = 1
            ev.xclient.window = win
            ev.xclient.message_type = begin if i == 0 else more
            ev.xclient.format = 8
            ev.xclient.data = msg[i:i + 20].ljust(20, b"\0")
            self.x.XSendEvent(self.dpy, self.root, 0, PropertyChangeMask, ctypes.byref(ev))
        self.x.XFlush(self.dpy)


def main():
    if len(sys.argv) < 2 or not sys.argv[1]:
        return 1
    sid = sys.argv[1]
    lib = load_x11()
    if lib is None:
        return 1
    try:
        x = X(lib)
    except OSError:
        return 1
    before = x.clients()
    end = time.monotonic() + TIMEOUT
    while time.monotonic() < end:
        time.sleep(0.3)
        now = x.clients()
        new = now - before
        if new or any(x.prop(w, "_NET_STARTUP_ID") == sid for w in now):
            time.sleep(0.3)   # la finestra è comparsa: un attimo perché si disegni
            x.startup_remove(sid)
            return 0
    x.startup_remove(sid)   # scaduto: il cursore si spegne comunque
    return 0


if __name__ == "__main__":
    sys.exit(main())
