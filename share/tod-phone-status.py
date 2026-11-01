#!/usr/bin/env python3
"""Il telefono nel desktop: batteria, Wi-Fi, rete mobile e notifiche veri (Termux:API).

  tod-phone-status.py demone        legge lo stato ogni 20 s in $TMPDIR/tod-phone.json e
                                    porta le notifiche nuove del telefono nel centro notifiche
  tod-phone-status.py batteria      riga per il plugin "genmon" della barra (icona + suggerimento)
  tod-phone-status.py rete          idem per Wi-Fi / rete mobile

Il demone e i comandi termux-* girano in Termux (non nel proot). La barra legge solo il file,
così un Termux:API lento non blocca mai il pannello.
"""
import json
import os
import shlex
import signal
import subprocess
import sys
import threading
import time

TMP = os.environ.get("TMPDIR", "/data/data/com.termux/files/usr/tmp")
STATE = os.path.join(TMP, "tod-phone.json")
PIDFILE = os.path.join(TMP, "tod-phone-status.pid")
HOME = os.environ.get("HOME", "/data/data/com.termux/files/home")
NOTIFY_OFF = os.path.join(HOME, ".config/tod/notifiche-telefono-spente")
TICK = 8   # secondi: notifiche entro 8 s, batteria ogni 32, rete ogni 64. Ogni lettura avvia un
# processo Java (Termux:API): ogni 5 s pesava sui telefoni meno potenti
# notifiche che non vanno inoltrate: il desktop stesso (Termux) e lo stato di sistema
QUIET = {"com.termux", "com.termux.x11", "com.termux.api", "com.termux.widget",
         "com.android.systemui", "android"}
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "")).startswith("it")
PANNELLO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tod-pannello")   # clic: il pannello della barra


def T(it, en):
    return it if ITALIAN else en


def api(cmd, want=dict):
    try:
        out = subprocess.run([cmd], capture_output=True, text=True, timeout=15).stdout
        d = json.loads(out or "null")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None if want is list else {}
    if want is list:   # None = lettura fallita, da non confondere con "nessuna notifica"
        return d if isinstance(d, list) else None
    return d if isinstance(d, dict) and "error" not in d else ({"error": d.get("error")} if isinstance(d, dict) else {})


# --- notifiche: quelle nuove del telefono diventano notifiche del desktop ------------------
def app_info(pkg):
    """Nome, icona e comando di apertura dall'app del telefono già nel menu Start."""
    name, icon, exe = pkg.rsplit(".", 1)[-1].capitalize(), "phone-symbolic", None
    try:
        for line in open(os.path.join(HOME, f".local/share/applications/tod-android-{pkg}.desktop")):
            if line.startswith("Name="):
                name = line[5:].strip()
            elif line.startswith("Exec="):
                exe = shlex.split(line[5:].strip())
    except OSError:
        pass
    png = os.path.join(HOME, f".local/share/icons/tod-android/{pkg}.png")
    if os.path.exists(png):
        icon = png
    return name, icon, exe


def fresh(items, seen):
    """Le notifiche da mostrare: chiave mai vista o testo cambiato (es. un nuovo messaggio
    nella stessa chat). seen è aggiornato; i riepiloghi di gruppo e i doppioni no."""
    out, texts = [], set()
    for n in items:
        pkg = n.get("packageName", "")
        title, body = (n.get("title") or "").strip(), (n.get("content") or "").strip()
        sig = (title, body)
        key = n.get("key") or f"{pkg}|{n.get('id')}"
        old = seen.get(key)
        seen[key] = sig
        if pkg in QUIET or not (title or body) or old == sig or (pkg, sig) in texts:
            continue
        texts.add((pkg, sig))
        out.append(n)
    for key in set(seen) - {n.get("key") or f"{n.get('packageName', '')}|{n.get('id')}" for n in items}:
        del seen[key]   # tolta dal telefono: se torna, è una notifica nuova
    return out


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def show(n):
    name, icon, exe = app_info(n.get("packageName", ""))
    title = (n.get("title") or "").strip() or name
    cmd = ["notify-send", "-a", name, "-i", icon, "-h", "string:desktop-entry:tod-android-" + n.get("packageName", ""),
           "-A", "default=" + T("Apri", "Open"), title, esc((n.get("content") or "").strip())]

    def wait():   # clic sulla notifica: apre l'app sul telefono (in DeX, una finestra)
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
            if exe and r.stdout.strip() == "default":
                subprocess.run(exe, capture_output=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            pass
    threading.Thread(target=wait, daemon=True).start()


def x_alive():
    d = os.environ.get("DISPLAY", ":0").split(":")[-1].split(".")[0] or "0"
    return any(os.path.exists(os.path.join(p, f"X{d}")) for p in (os.path.join(TMP, ".X11-unix"), "/tmp/.X11-unix"))


def daemon():
    # uno per sessione: quello di una sessione precedente (vecchio D-Bus, notifiche perse) si chiude
    try:
        old = int(open(PIDFILE).read())
        if old != os.getpid() and "tod-phone-status" in open(f"/proc/{old}/cmdline").read():
            os.kill(old, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    open(PIDFILE, "w").write(str(os.getpid()))
    state, n, gone, seen = {}, 0, 0, None
    while True:
        if not os.path.exists(NOTIFY_OFF):
            items = api("termux-notification-list", list)
            if items is None:
                pass
            elif seen is None:   # all'avvio: quelle già presenti sul telefono non si ripetono
                seen = {}
                fresh(items, seen)
            else:
                for note in fresh(items, seen)[:5]:
                    show(note)
        else:
            seen = None
        if n % 4 == 0:
            state["battery"] = api("termux-battery-status")
        if n % 8 == 0:   # la rete cambia meno spesso
            state["wifi"] = api("termux-wifi-connectioninfo")
            state["phone"] = api("termux-telephony-deviceinfo")
        if n % 4 == 0:
            state["time"] = time.time()
            tmp = STATE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(state, f)
            os.replace(tmp, STATE)
            gone = 0 if x_alive() else gone + 1
            if gone >= 3:   # sessione grafica finita
                break
        n += 1
        time.sleep(TICK)
    try:
        os.unlink(PIDFILE)
    except OSError:
        pass
    return 0


def load():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return {}


def genmon(icon, tip, click=None, text=None):
    out = f"<icon>{icon}</icon><tool>{tip}</tool>"
    if click:
        out += f"<iconclick>{click}</iconclick>"
    if text:
        out += f"<txt>{text}</txt>"
    return out


def battery(st=None):
    """riga genmon dell'icona della batteria (la barra la chiama da sé, senza avviare questo programma)"""
    b = (load() if st is None else st).get("battery") or {}
    if "percentage" not in b:
        return genmon("battery-missing-symbolic", T("Batteria: in attesa di Termux:API", "Battery: waiting for Termux:API"), f"{PANNELLO} batteria")
    p = int(b["percentage"])
    charging = b.get("status") in ("CHARGING", "FULL") or b.get("plugged") not in (None, "UNPLUGGED")
    level = min(100, (p + 5) // 10 * 10)
    if charging:
        icon = "battery-level-100-charged-symbolic" if p >= 99 else f"battery-level-{level}-charging-symbolic"
    else:
        icon = "battery-caution-symbolic" if p <= 10 else f"battery-level-{level}-symbolic"
    stato = T("in carica", "charging") if charging else T("con la batteria", "on battery")
    tip = f"{T('Batteria', 'Battery')}: {p}% · {stato}"
    if b.get("temperature"):
        tip += f" · {float(b['temperature']):.0f} °C"
    return genmon(icon, tip, f"{PANNELLO} batteria")   # come Windows 11: solo l'icona, la percentuale nel suggerimento


def network(st=None):
    st = load() if st is None else st
    w = st.get("wifi") or {}
    ph = st.get("phone") or {}
    if w.get("supplicant_state") == "COMPLETED" or (w.get("ip") not in (None, "0.0.0.0") and w.get("rssi", -127) > -127):
        rssi = int(w.get("rssi", -127))
        q = "excellent" if rssi >= -55 else "good" if rssi >= -67 else "ok" if rssi >= -75 else "weak"
        ssid = (w.get("ssid") or "").strip('"')
        if ssid in ("", "<unknown ssid>"):
            ssid = T("rete Wi-Fi", "Wi-Fi network")
        return genmon(f"network-wireless-signal-{q}-symbolic", f"Wi-Fi: {ssid} · {rssi} dBm", f"{PANNELLO} rete")
    if "error" in w and "LOCATION" in str(w.get("error")):
        return genmon("network-wireless-offline-symbolic",
                      T("Wi-Fi: dai a Termux:API il permesso Posizione", "Wi-Fi: grant Location to Termux:API"),
                      f"{PANNELLO} rete")
    if ph.get("data_state") == "connected" or ph.get("network_operator_name"):
        op = ph.get("network_operator_name") or ph.get("sim_operator_name") or T("rete mobile", "mobile network")
        kind = ph.get("network_type") or ""
        return genmon("network-cellular-signal-good-symbolic", f"{op} {kind}".strip(), f"{PANNELLO} rete")
    return genmon("network-offline-symbolic", T("Nessuna rete", "No network"), f"{PANNELLO} rete")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode in ("demone", "daemon"):
        return daemon()
    if mode in ("batteria", "battery"):
        print(battery())
    elif mode in ("rete", "network"):
        print(network())
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
