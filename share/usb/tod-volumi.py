#!/usr/bin/env python3
"""I dischi USB in Esplora file come in una normale distribuzione: un "volume monitor" di GIO.

Su un PC i dischi sotto "Dispositivi" li descrive gvfs-udisks2-volume-monitor. Questo fa lo stesso per
i dischi USB letti da tod-lkl (share/usb/tod-usb): ogni partizione è un volume con il suo nome, l'icona
del suo disco (Scheda SD o Chiavetta USB) e il tasto di espulsione, che smonta solo lei. È già montata:
una cartella vera in /media/usb/<nome> (tod-fs.so), anche per la scrivania e per "Apri" e "Salva".

L'elenco delle partizioni lo scrive tod-usb in $TMPDIR/tod-usb/volumi (dai file lkl-<id>.volumi).
GIO lo trova con $PREFIX/share/gvfs/remote-volume-monitors/tod-dischi.monitor e lo avvia D-Bus
($PREFIX/share/dbus-1/services/org.gtk.vfs.TodVolumeMonitor.service): li installa `tod-usb monitor`.
"""
import os
import sys

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NOME_DBUS = "org.gtk.vfs.TodVolumeMonitor"
PERCORSO = "/org/gtk/Private/RemoteVolumeMonitor"
RUN = os.path.join(os.environ.get("TMPDIR", "/tmp"), "tod-usb")
ELENCO = os.path.join(RUN, "volumi")
TOD_USB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tod-usb")

DRIVE = "(ssssbbbbbbbbuasa{ss}sa{sv})"
VOLUME = "(ssssssbbssa{ss}sa{sv})"
MOUNT = "(ssssssbsassa{sv})"
XML = f"""<node><interface name='org.gtk.Private.RemoteVolumeMonitor'>
<method name='IsSupported'><arg type='b' direction='out'/></method>
<method name='List'><arg type='a{DRIVE}' direction='out'/><arg type='a{VOLUME}' direction='out'/>
  <arg type='a{MOUNT}' direction='out'/></method>
<method name='CancelOperation'><arg type='s' direction='in'/><arg type='b' direction='out'/></method>
<method name='MountUnmount'><arg type='s' direction='in'/><arg type='s' direction='in'/>
  <arg type='u' direction='in'/><arg type='s' direction='in'/></method>
<method name='VolumeMount'><arg type='s' direction='in'/><arg type='s' direction='in'/>
  <arg type='u' direction='in'/><arg type='s' direction='in'/></method>
<method name='DriveEject'><arg type='s' direction='in'/><arg type='s' direction='in'/>
  <arg type='u' direction='in'/><arg type='s' direction='in'/></method>
<method name='DrivePollForMedia'><arg type='s' direction='in'/><arg type='s' direction='in'/></method>
<method name='DriveStart'><arg type='s' direction='in'/><arg type='s' direction='in'/>
  <arg type='u' direction='in'/><arg type='s' direction='in'/></method>
<method name='DriveStop'><arg type='s' direction='in'/><arg type='s' direction='in'/>
  <arg type='u' direction='in'/><arg type='s' direction='in'/></method>
<method name='MountOpReply'><arg type='s' direction='in'/><arg type='i' direction='in'/>
  <arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='i' direction='in'/>
  <arg type='b' direction='in'/><arg type='i' direction='in'/></method>
<method name='MountOpReply2'><arg type='s' direction='in'/><arg type='i' direction='in'/>
  <arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='i' direction='in'/>
  <arg type='b' direction='in'/><arg type='i' direction='in'/><arg type='a{{sv}}' direction='in'/></method>
<signal name='DriveChanged'><arg type='s'/><arg type='s'/><arg type='{DRIVE}'/></signal>
<signal name='DriveConnected'><arg type='s'/><arg type='s'/><arg type='{DRIVE}'/></signal>
<signal name='DriveDisconnected'><arg type='s'/><arg type='s'/><arg type='{DRIVE}'/></signal>
<signal name='VolumeChanged'><arg type='s'/><arg type='s'/><arg type='{VOLUME}'/></signal>
<signal name='VolumeAdded'><arg type='s'/><arg type='s'/><arg type='{VOLUME}'/></signal>
<signal name='VolumeRemoved'><arg type='s'/><arg type='s'/><arg type='{VOLUME}'/></signal>
<signal name='MountAdded'><arg type='s'/><arg type='s'/><arg type='{MOUNT}'/></signal>
<signal name='MountRemoved'><arg type='s'/><arg type='s'/><arg type='{MOUNT}'/></signal>
<signal name='MountChanged'><arg type='s'/><arg type='s'/><arg type='{MOUNT}'/></signal>
</interface></node>"""

ICONE = {   # icona, icona simbolica (GThemedIcon con alternative: non tutti i temi hanno la prima)
    "Scheda SD": (". GThemedIcon media-flash-sd media-flash-sd-mmc media-flash drive-removable-media",
                  ". GThemedIcon media-flash-sd-symbolic media-flash-symbolic drive-removable-media-symbolic"),
    "Chiavetta USB": (". GThemedIcon drive-removable-media-usb drive-removable-media",
                      ". GThemedIcon drive-removable-media-usb-symbolic drive-removable-media-symbolic"),
}


def alias_of(nome):   # come alias_of di tod-usb: "Scheda SD" -> "scheda-sd" (niente spazi né accenti)
    fuori = []
    for b in nome.encode():   # byte per byte: "À" (2 byte) diventa "--"
        c = chr(b)
        fuori.append("-" if c == " " else "_" if c == "/" else c.lower() if c.isascii() and (c.isalnum() or c in "._-") else "-")
    return "".join(fuori)


def leggi():
    """Unità e volumi dall'elenco di tod-usb: {disco: drive}, [volumi]."""
    righe = []
    try:
        with open(ELENCO) as f:
            for r in f.read().splitlines():
                c = r.split("\t")
                if len(c) >= 8 and c[0]:
                    righe.append(c)
    except OSError:
        pass
    # un'unità per partizione: Esplora file mostra solo i volumi, e il tasto di espulsione di un volume
    # espelle la sua unità; così smonta solo quella partizione (smontata l'ultima, tod-usb restituisce
    # il disco ad Android)
    dischi, volumi = {}, []
    for nome, disco, tipo, prodotto, byte, fs, etichetta, uuid in (c[:8] for c in righe):
        a = alias_of(nome)
        did, vid = f"tod-drive-{a}", f"tod-volume-{a}"
        dischi[a] = {"id": did, "nome": nome, "tipo": tipo, "volumi": [vid], "nomi": [nome], "disco": disco}
        uri = GLib.filename_to_uri(f"/media/usb/{nome}", None)
        volumi.append({"id": vid, "nome": nome, "tipo": tipo, "uuid": uuid, "uri": uri,
                       "drive": did, "etichetta": etichetta, "ordine": f"{disco}-{nome}",
                       "mount": f"tod-mount-{a}"})
    return dischi, volumi


def drive_struct(d):
    i, s = ICONE.get(d["tipo"], ICONE["Chiavetta USB"])
    return (d["id"], d["nome"], i, s, True, False, True, True, True, False, False, False, 0,
            d["volumi"], {}, d["id"], {"is-removable": GLib.Variant("b", True)})


def volume_struct(v):
    i, s = ICONE.get(v["tipo"], ICONE["Chiavetta USB"])
    ident = {"uuid": v["uuid"], "class": "device"}
    if v["etichetta"]:
        ident["label"] = v["etichetta"]
    return (v["id"], v["nome"], i, s, v["uuid"], v["uri"], not v["mount"], False, v["drive"], v["mount"], ident, v["ordine"],
            {"is-removable": GLib.Variant("b", True), "always-call-mount": GLib.Variant("b", False)})


def mount_struct(v):   # sempre montati, in /media/usb/<nome>
    i, s = ICONE.get(v["tipo"], ICONE["Chiavetta USB"])
    return (v["mount"], v["nome"], i, s, v["uuid"], v["uri"], True, v["id"], [], v["ordine"], {})


class Monitor:
    def __init__(self, conn):
        self.conn = conn
        self.dischi, self.volumi = leggi()
        node = Gio.DBusNodeInfo.new_for_xml(XML)
        conn.register_object(PERCORSO, node.interfaces[0], self.chiamata, None, None)
        self.osserva = Gio.File.new_for_path(RUN).monitor_directory(Gio.FileMonitorFlags.NONE, None)
        self.osserva.connect("changed", self.cambiato)

    def segnale(self, nome, tipo, valore):
        self.conn.emit_signal(None, PERCORSO, "org.gtk.Private.RemoteVolumeMonitor", nome,
                              GLib.Variant(f"(ss{tipo})", (NOME_DBUS, valore[0], valore)))

    def cambiato(self, _mon, f, _altro, _evento):
        n = f.get_basename() or ""
        if n != "volumi":
            return
        prima_d, prima_v = self.dischi, {v["id"]: v for v in self.volumi}
        self.dischi, self.volumi = leggi()
        dopo_v = {v["id"]: v for v in self.volumi}
        prima_ids = {d["id"]: d for d in prima_d.values()}
        dopo_ids = {d["id"]: d for d in self.dischi.values()}
        for vid, v in prima_v.items():
            if vid not in dopo_v or dopo_v[vid] != v:
                self.segnale("MountRemoved", MOUNT, mount_struct(v))
                self.segnale("VolumeRemoved", VOLUME, volume_struct(v))
        for did, d in prima_ids.items():
            if did not in dopo_ids:
                self.segnale("DriveDisconnected", DRIVE, drive_struct(d))
        for did, d in dopo_ids.items():
            if did not in prima_ids:
                self.segnale("DriveConnected", DRIVE, drive_struct(d))
            elif prima_ids[did] != d:
                self.segnale("DriveChanged", DRIVE, drive_struct(d))
        for vid, v in dopo_v.items():
            if vid not in prima_v or prima_v[vid] != v:
                self.segnale("VolumeAdded", VOLUME, volume_struct(v))
                self.segnale("MountAdded", MOUNT, mount_struct(v))

    def chiamata(self, _conn, _mittente, _percorso, _interfaccia, metodo, args, invocazione):
        if metodo == "IsSupported":
            invocazione.return_value(GLib.Variant("(b)", (True,)))
        elif metodo == "List":
            invocazione.return_value(GLib.Variant(f"(a{DRIVE}a{VOLUME}a{MOUNT})", (
                [drive_struct(d) for d in self.dischi.values()],
                [volume_struct(v) for v in self.volumi], [mount_struct(v) for v in self.volumi])))
        elif metodo == "CancelOperation":
            invocazione.return_value(GLib.Variant("(b)", (False,)))
        elif metodo == "DriveEject":   # tasto di espulsione: tutte le partizioni del disco
            d = next((d for d in self.dischi.values() if d["id"] == args[0]), None)

            def fatto(pid, stato, _dati):
                GLib.spawn_close_pid(pid)
                if stato == 0:
                    invocazione.return_value(None)
                else:
                    invocazione.return_dbus_error("org.gtk.Private.RemoteVolumeMonitor.Failed",
                                                  "Il disco è ancora in uso")
            if d is None:
                invocazione.return_value(None)
                return
            cmd = " && ".join(f"bash {GLib.shell_quote(TOD_USB)} espelli {GLib.shell_quote(n)}" for n in d["nomi"])
            pid, *_ = GLib.spawn_async([GLib.find_program_in_path("sh"), "-c", cmd],
                                       flags=GLib.SpawnFlags.DO_NOT_REAP_CHILD)
            GLib.child_watch_add(GLib.PRIORITY_DEFAULT, pid, fatto, None)
        elif metodo == "MountUnmount":   # smonta: come l'espulsione di quella partizione
            v = next((v for v in self.volumi if v["mount"] == args[0]), None)
            if v is None:
                invocazione.return_value(None)
                return
            pid, *_ = GLib.spawn_async(["bash", TOD_USB, "espelli", v["nome"]], flags=GLib.SpawnFlags.DO_NOT_REAP_CHILD | GLib.SpawnFlags.SEARCH_PATH)
            GLib.child_watch_add(GLib.PRIORITY_DEFAULT, pid, lambda p, st, _d: (GLib.spawn_close_pid(p), invocazione.return_value(None)), None)
        elif metodo in ("MountOpReply", "MountOpReply2", "DrivePollForMedia"):
            invocazione.return_value(None)
        else:   # i volumi sono già montati; il resto non c'è
            invocazione.return_dbus_error("org.gtk.Private.RemoteVolumeMonitor.NotSupported",
                                          "Operazione non disponibile")


def main():
    loop = GLib.MainLoop()
    stato = {}

    def preso(conn, _nome):
        stato["m"] = Monitor(conn)

    Gio.bus_own_name(Gio.BusType.SESSION, NOME_DBUS, Gio.BusNameOwnerFlags.NONE,
                     preso, None, lambda *_: loop.quit())
    loop.run()


if __name__ == "__main__":
    sys.exit(main())
