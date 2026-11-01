#!/usr/bin/env python3
"""Prestazioni: chi usa il telefono, misurato (tod prestazioni [secondi]).

Per N secondi (60) ogni 5 s legge da /proc i tempi di processore e la memoria dei nostri processi
(Termux, desktop, app di Debian, macchina dei dischi), la frequenza dei core rispetto al massimo
(calore: Android rallenta da solo), la memoria libera e la temperatura della batteria (Termux:API).
Scrive un resoconto in Download (tod-prestazioni-<data>.txt) e lo stampa. Solo lettura: non cambia niente.
Va eseguito in Termux: dal container proot /proc non mostra i processi veri.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

HZ = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")
HOME = os.environ.get("TOD_TERMUX_HOME") or os.path.expanduser("~")
OUT_DIR = os.path.join(HOME, "storage/downloads")
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "it")).startswith("it")


def T(it, en):
    return it if ITALIAN else en


def gruppo(cmd, comm):
    """Un nome comprensibile per il processo: i processi dello stesso programma si sommano."""
    a = cmd.split("\0")
    if a[0].endswith("tod-diretto/ld.so") and len(a) > 3 and a[1] == "--argv0":
        # app di Debian senza proot (lib/diretto.sh): ld.so --argv0 NOME PERCORSO ARGOMENTI → NOME ARGOMENTI
        cmd = "\0".join([a[2]] + a[4:])
    c = cmd.lower()
    if "termux-x11" in c or "com.termux.x11" in c:
        return "Termux:X11"
    if "virgl_test_server" in c:
        return T("Grafica virgl", "virgl graphics")
    for nome, chiave in (("tod-android-apps", T("Icone delle app del telefono", "Phone app icons")),
                         ("tod-phone-status", T("Stato del telefono", "Phone status")),
                         ("tod-updates", T("Aggiornamenti", "Updates")),
                         ("tod-start", T("Menu Start", "Start menu")),
                         ("tod-settings", T("Impostazioni", "Settings")),
                         ("tod-edges", T("Bordi delle finestre", "Window edges")),
                         ("tod-lkl", T("Dischi USB", "USB disks")),
                         ("share/usb/tod-usb", T("Dischi USB (servizio)", "USB disks (service)")),
                         ("tod-open-host", T("Link delle app Debian", "Debian app links"))):
        if nome in c:
            return chiave
    if "proot" in comm or c.startswith("proot"):
        return "proot (Debian)"
    for nome in ("xfwm4", "xfce4-panel", "xfdesktop", "xfsettingsd", "thunar", "pulseaudio", "dbus-daemon",
                 "chromium", "firefox", "libreoffice", "soffice", "gimp", "inkscape", "code", "apt", "dpkg"):
        if re.search(r"(^|/)" + nome, c):
            return nome
    argv0 = cmd.split("\0")[0].split(" ")[0]   # Electron e Chromium riscrivono il titolo con le opzioni
    if argv0.endswith(".asar"):   # .../<app>/resources/app.asar → <app>
        argv0 = argv0.rsplit("/resources/", 1)[0]
    prog = argv0.split("/")[-1] or comm
    if prog in ("python3", "python", "bash", "sh") and "\0" in cmd:   # script: il nome dello script
        args = [a for a in cmd.split("\0")[1:] if a and not a.startswith("-")]
        if args:
            prog = f"{prog} {args[0].split('/')[-1]}"
    return prog[:40]


def processi():
    """{pid: (gruppo, ticks di processore, memoria in kB)} dei processi leggibili (i nostri)."""
    out = {}
    for d in glob.glob("/proc/[0-9]*"):
        try:
            with open(d + "/stat") as f:
                st = f.read()
            comm = st[st.index("(") + 1:st.rindex(")")]
            campi = st[st.rindex(")") + 2:].split()
            ticks = int(campi[11]) + int(campi[12])
            rss = int(campi[21]) * PAGE // 1024
            with open(d + "/cmdline", "rb") as f:
                cmd = f.read().rstrip(b"\0").decode(errors="replace")
            out[int(d[6:])] = (gruppo(cmd or comm, comm), ticks, rss)
        except (OSError, ValueError, IndexError):
            continue
    return out


def frequenze():
    """[(core, attuale MHz, massima MHz)]: se l'attuale resta molto sotto, il telefono si sta proteggendo dal calore."""
    out = []
    for d in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq"), key=lambda p: int(re.search(r"cpu(\d+)", p)[1])):
        try:
            cur = int(open(d + "/scaling_cur_freq").read()) // 1000
            mx = int(open(d + "/cpuinfo_max_freq").read()) // 1000
            out.append((int(re.search(r"cpu(\d+)", d)[1]), cur, mx))
        except (OSError, ValueError):
            continue
    return out


def memoria():
    try:
        m = {k: int(v.split()[0]) for k, v in (l.split(":", 1) for l in open("/proc/meminfo"))}
        return m.get("MemTotal", 0) // 1024, m.get("MemAvailable", 0) // 1024
    except (OSError, ValueError):
        return 0, 0


def batteria():
    try:
        r = subprocess.run(["termux-battery-status"], capture_output=True, text=True, timeout=15)
        return json.loads(r.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}


def prop(nome):
    try:
        return subprocess.run(["getprop", nome], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def main():
    durata = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 60
    passo = max(1, min(5, durata))
    print(T(f"Misuro per {durata} secondi: usa il telefono come al solito…",
            f"Measuring for {durata} seconds: use the phone as usual…"), flush=True)
    b0 = batteria()
    prima, t0 = processi(), time.time()
    freq = []
    mem_min = None
    while time.time() - t0 < durata:
        time.sleep(passo)
        freq.append(frequenze())
        _tot, libera = memoria()
        mem_min = libera if mem_min is None else min(mem_min, libera)
    dopo, t1 = processi(), time.time()
    b1 = batteria()
    sec = t1 - t0

    uso, mem = {}, {}
    for pid, (g, ticks, rss) in dopo.items():
        base = prima.get(pid, (g, 0, 0))[1] if pid in prima else 0   # nato durante la misura: tutto il suo tempo
        uso[g] = uso.get(g, 0) + max(0, ticks - base)
        mem[g] = mem.get(g, 0) + rss
    righe = sorted(((t / HZ / sec * 100, g) for g, t in uso.items()), reverse=True)
    totale = sum(p for p, _g in righe)
    ncore = os.cpu_count() or 1

    r = []
    modello = prop("ro.product.model") or "?"
    chip = prop("ro.soc.model") or prop("ro.board.platform") or "?"
    tot_mem, _ = memoria()
    r.append(T("Termux On DeX: prestazioni", "Termux On DeX: performance"))
    r.append(f"{time.strftime('%Y-%m-%d %H:%M')} · {modello} · {chip} · {ncore} core · {tot_mem // 1024 + 1} GB RAM")
    r.append(T(f"Durata: {sec:.0f} s", f"Duration: {sec:.0f} s"))
    r.append("")
    r.append(T(f"Processore usato da noi: {totale:.0f}% di un core (su {ncore} core = {totale / ncore:.0f}% del totale)",
               f"CPU used by us: {totale:.0f}% of one core ({ncore} cores = {totale / ncore:.0f}% of total)"))
    r.append(T("  % di un core   memoria   programma", "  % of one core  memory    program"))
    for p, g in righe[:15]:
        if p < 0.5:
            break
        r.append(f"  {p:6.1f}%      {mem.get(g, 0) // 1024:5d} MB   {g}")
    r.append("")
    if freq and freq[0]:
        r.append(T("Frequenza dei core (media durante la misura, rispetto al massimo):",
                   "Core frequency (average during the measurement, vs maximum):"))
        cores = {}
        for campione in freq:
            for c, cur, mx in campione:
                cores.setdefault(c, []).append((cur, mx))
        gruppi = {}
        for c, v in cores.items():
            mx = v[0][1]
            gruppi.setdefault(mx, []).append(sum(x for x, _m in v) / len(v))
        for mx, medie in sorted(gruppi.items()):
            m = sum(medie) / len(medie)
            r.append(f"  {len(medie)} core fino a {mx} MHz: {m:.0f} MHz ({m / mx * 100:.0f}%)" if ITALIAN else
                     f"  {len(medie)} cores up to {mx} MHz: {m:.0f} MHz ({m / mx * 100:.0f}%)")
        r.append(T("  (sotto carico una percentuale bassa vuol dire calore: Android rallenta per proteggersi)",
                   "  (a low percentage under load means heat: Android slows down to protect itself)"))
    else:
        r.append(T("Frequenza dei core: non leggibile su questo telefono", "Core frequency: not readable on this phone"))
    r.append("")
    if mem_min is not None:
        r.append(T(f"Memoria libera (minimo): {mem_min} MB su {tot_mem} MB",
                   f"Free memory (minimum): {mem_min} MB of {tot_mem} MB"))
    if b0 or b1:
        r.append(T(f"Batteria: {b0.get('percentage', '?')}% → {b1.get('percentage', '?')}%, "
                   f"temperatura {b0.get('temperature', '?')} → {b1.get('temperature', '?')} °C, {b1.get('status', '?')}",
                   f"Battery: {b0.get('percentage', '?')}% → {b1.get('percentage', '?')}%, "
                   f"temperature {b0.get('temperature', '?')} → {b1.get('temperature', '?')} °C, {b1.get('status', '?')}"))
    testo = "\n".join(r)
    print("\n" + testo)
    try:
        os.makedirs(OUT_DIR, exist_ok=True)
        f = os.path.join(OUT_DIR, f"tod-prestazioni-{time.strftime('%Y%m%d-%H%M')}.txt")
        with open(f, "w") as fh:
            fh.write(testo + "\n")
        print("\n" + T(f"Salvato in Download: {os.path.basename(f)}", f"Saved to Download: {os.path.basename(f)}"))
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
