#!/usr/bin/env python3
"""Aggiornamenti, come Windows Update: un posto solo per Termux On DeX, Termux e Debian.

  tod-updates.py                     la finestra (Impostazioni → Aggiornamenti, o clic sull'avviso)
  tod-updates.py controlla           aggiorna gli elenchi e scrive ~/.local/state/tod/updates.json
  tod-updates.py controlla --ciclo   in sottofondo per la sessione: dopo 2 minuti, poi ogni 6 ore;
                                     se ci sono aggiornamenti nuovi lo dice con una notifica

Termux On DeX stesso (il codice da GitHub) lo controlla e lo aggiorna `tod _self_check` / `tod _self_update`.
Gira in Termux (PyGObject). Le app aperte che vanno aggiornate si chiudono prima (chiedendo) e si
riaprono dopo. Mai toccati: i pacchetti bloccati (apt-mark hold: i driver grafici) e
termux-x11-nightly, che deve restare abbinato all'app Termux:X11.
"""
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
HOME = os.environ.get("TOD_TERMUX_HOME") or os.environ.get("HOME", "/data/data/com.termux/files/home")
STATE_DIR = os.path.join(HOME, ".local/state/tod")
STATE = os.path.join(STATE_DIR, "updates.json")
LOG = os.path.join(STATE_DIR, "updates.log")
TMP = os.environ.get("TMPDIR", os.path.join(PREFIX, "tmp"))
PIDFILE = os.path.join(TMP, "tod-updates.pid")
TOD = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tod")   # questa copia di tod
PROTECTED = {"termux-x11-nightly"}
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "")).startswith("it")
# il primo controllo dopo 10 minuti: apt update di Termux e Debian è pesante, e appena acceso il
# desktop sta ancora sistemando le sue cose (sui telefoni meno potenti si sentiva)
FIRST_CHECK, EVERY = 600, 6 * 3600
APT_OPTS = ["-y", "-q", "-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold"]


def T(it, en):
    return it if ITALIAN else en


def log(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(time.strftime("%F %T ") + msg + "\n")
    except OSError:
        pass


def conf(key, default=""):
    try:
        for line in open(os.path.join(HOME, ".config/tod/tod.conf")):
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return default


DISTRO = conf("CX_DISTRO", "debian")


def rootfs():
    for p in (f"{PREFIX}/var/lib/proot-distro/containers/{DISTRO}/rootfs",
              f"{PREFIX}/var/lib/proot-distro/installed-rootfs/{DISTRO}"):
        if os.path.isdir(os.path.join(p, "usr")):
            return p
    return None


def run(cmd, timeout=900):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def cx(script, timeout=900):
    return run(["proot-distro", "login", DISTRO, "--", "sh", "-c", script], timeout)


UPG = re.compile(r"^([^/\s]+)/\S+\s+(\S+)\s+\S+\s+\[[^\]]*?(?:from|da):\s*([^\]]+)\]")


def parse_upgradable(text):
    out = []
    for line in text.splitlines():
        m = UPG.match(line.strip())
        if m:
            out.append({"name": m.group(1), "to": m.group(2), "from": m.group(3).strip()})
    return out


def short_names():
    """I nomi brevi dello Start (GIMP, Writer, Esplora file...), per chiamare le app allo stesso modo."""
    import ast
    try:
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "tod-start.py")).read()
        m = re.search(r"^SHORT_NAMES = (\{.*?^\})", src, re.S | re.M)
        return {k: v for k, v in ast.literal_eval(m.group(1)).items() if v}
    except (OSError, ValueError, SyntaxError, AttributeError):
        return {}


SHORT = short_names()


def app_of(pkg, info_dir, root=""):
    """Nome e icona dell'app (se il pacchetto ne ha una nel menu), sennò None.
    Con più voci (LibreOffice: Writer, Calc...) vale quella col nome più corto ("LibreOffice")."""
    entries = list(app_entries(pkg, info_dir, root))
    if not entries:
        return None
    if len(entries) == 1:
        return entries[0]
    best = min(entries, key=lambda e: len(e["raw"]))   # più app nello stesso pacchetto: il nome comune
    return dict(best, app=best["raw"])


def app_entries(pkg, info_dir, root=""):
    for cand in (f"{pkg}.list", f"{pkg}:arm64.list", f"{pkg}:aarch64.list"):
        try:
            paths = open(os.path.join(info_dir, cand)).read().split()
            break
        except OSError:
            paths = []
    for p in paths:
        if "/share/applications/" in p and p.endswith(".desktop"):
            name = icon = exe = None
            try:
                main = True
                for line in open(root + p, errors="replace"):
                    if line.startswith("["):
                        main = line.strip() == "[Desktop Entry]"
                    elif not main:
                        continue
                    elif line.startswith("NoDisplay=true"):
                        name = None
                        break
                    elif line.startswith(f"Name[{'it' if ITALIAN else 'en'}]=") or (line.startswith("Name=") and not name):
                        name = line.split("=", 1)[1].strip()
                    elif line.startswith("Icon="):
                        icon = line[5:].strip()
                    elif line.startswith("Exec="):
                        exe = os.path.basename(line[5:].split()[0]) if line[5:].split() else None
            except OSError:
                continue
            if name:
                base = os.path.basename(p)
                short = SHORT.get(base)
                yield {"app": short[0 if ITALIAN else 1] if short else name, "raw": name, "icon": icon, "exe": exe,
                       "desktop": base}


def tod_item(text):
    """L'uscita di `tod _self_check` → la voce "Termux On DeX" dell'elenco, o None se non c'è niente di nuovo."""
    d, titoli = {}, []
    for line in text.splitlines():
        k, _, v = line.partition("=")
        if k == "titolo":
            titoli.append(v)
        elif k:
            d[k] = v
    if d.get("stato") != "nuovo":
        return None
    n = d.get("novita", "")
    desc = (T("1 novità", "1 change") if n == "1" else T(f"{n} novità", f"{n} changes") if n not in ("", "0")
            else T("Nuova versione", "New version"))
    if titoli and ITALIAN:   # i titoli delle modifiche sono in italiano
        desc += " · " + titoli[0]
    return {"name": "termux-on-dex", "where": "tod", "app": "Termux On DeX", "icon": "tod-start",
            "from": d.get("da", ""), "to": d.get("a", ""), "desc": desc, "titoli": titoli}


def all_items(st):
    return st.get("tod", []) + st.get("termux", []) + st.get("debian", [])


def check(refresh=True):
    """Aggiorna gli elenchi (se refresh) e scrive cosa c'è da aggiornare. Ritorna lo stato."""
    st = {"time": time.time(), "tod": [], "termux": [], "debian": [], "error": ""}
    # Termux On DeX: il ramo su GitHub (senza refresh solo il confronto con l'ultimo scaricato)
    _, out = run(["bash", TOD, "_self_check"] + ([] if refresh else ["--locale"]), timeout=180)
    it = tod_item(out)
    if it:
        st["tod"].append(it)
    if refresh:
        rc, out = run(["nice", "-n", "10", "apt-get", "update", "-qq"])
        if rc != 0:
            st["error"] = T("Termux: elenchi non aggiornati (senza rete?)", "Termux: lists not refreshed (offline?)")
            log("apt-get update Termux: " + out[-300:])
    held = set(run(["apt-mark", "showhold"])[1].split()) | PROTECTED
    _, out = run(["apt", "list", "--upgradable"])
    for u in parse_upgradable(out):
        if u["name"] not in held:
            u["where"] = "termux"
            u.update(app_of(u["name"], f"{PREFIX}/var/lib/dpkg/info") or {})
            st["termux"].append(u)
    root = rootfs()
    if root:
        script = ("apt-get update -qq >/dev/null 2>&1; " if refresh else "") + \
                 "echo HOLD $(apt-mark showhold); apt list --upgradable 2>/dev/null"
        _, out = cx(script)
        hold = set()
        for line in out.splitlines():
            if line.startswith("HOLD"):
                hold = set(line.split()[1:])
        for u in parse_upgradable(out):
            if u["name"] not in hold:
                u["where"] = "debian"
                u.update(app_of(u["name"], f"{root}/var/lib/dpkg/info", root) or {})
                st["debian"].append(u)
    try:
        old = json.load(open(STATE))
        st["notified"] = old.get("notified", [])
    except (OSError, ValueError):
        st["notified"] = []
    save(st)
    return st


def save(st):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE)


def load():
    try:
        st = json.load(open(STATE))
    except (OSError, ValueError):
        return {}
    for k in ("termux", "debian"):   # stati scritti da versioni precedenti
        for u in st.get(k, []):
            u.setdefault("where", k)
    st.setdefault("tod", [])
    return st


def summary(st):
    items = all_items(st)
    apps = [u["app"] for u in items if u.get("app")]
    n = len(items)
    if not n:
        return T("Il sistema è aggiornato", "Your system is up to date")
    if apps:
        more = n - 1
        first = apps[0]
        if more == 1:
            return T(f"{first} e un altro aggiornamento", f"{first} and 1 more update")
        return T(f"{first} e altri {more} aggiornamenti", f"{first} and {more} more updates") if more else first
    return T(f"{n} aggiornamenti di sistema", f"{n} system updates")


def notify(st):
    items = all_items(st)
    keys = sorted(f"{u['name']}={u['to']}" for u in items)
    if not keys or keys == sorted(st.get("notified", [])):
        return
    st["notified"] = keys
    save(st)
    me = os.path.abspath(__file__)

    def wait():
        try:
            r = subprocess.run(["notify-send", "-a", T("Aggiornamenti", "Updates"), "-i", "system-software-update",
                                "-A", "default=" + T("Apri", "Open"),
                                T("Aggiornamenti disponibili", "Updates available"), summary(st)],
                               capture_output=True, text=True, timeout=3600)
            if r.stdout.strip() == "default":
                subprocess.Popen([sys.executable, me], start_new_session=True)
        except (OSError, subprocess.TimeoutExpired):
            pass
    threading.Thread(target=wait, daemon=True).start()


def x_alive():
    d = os.environ.get("DISPLAY", ":0").split(":")[-1].split(".")[0] or "0"
    return any(os.path.exists(os.path.join(p, f"X{d}")) for p in (os.path.join(TMP, ".X11-unix"), "/tmp/.X11-unix"))


def loop():
    try:   # uno per sessione
        old = int(open(PIDFILE).read())
        if old != os.getpid() and "tod-updates" in open(f"/proc/{old}/cmdline").read():
            os.kill(old, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    next_at = time.time() + FIRST_CHECK
    while x_alive():
        if time.time() >= next_at:
            st = check()
            log(f"controllo: Termux On DeX {len(st['tod'])}, Termux {len(st['termux'])}, Debian {len(st['debian'])} {st['error']}")
            notify(st)
            next_at = time.time() + EVERY
        time.sleep(30)
    return 0


# --- installazione ------------------------------------------------------------------------
def running_pids(exe):
    """PID dei processi principali di un'app (per nome del programma)."""
    pids = []
    if not exe:
        return pids
    for p in os.listdir("/proc"):
        if not p.isdigit() or int(p) == os.getpid():
            continue
        try:
            args = open(f"/proc/{p}/cmdline", "rb").read().split(b"\0")
        except OSError:
            continue
        if args and os.path.basename(args[0].decode(errors="replace")) == exe and \
                not any(a.startswith(b"--type=") for a in args):
            pids.append(int(p))
    return pids


def with_deps(pkgs):
    """Termux è "rolling" e i suoi pacchetti spesso non dicono quale versione delle librerie vogliono:
    aggiornare solo GIMP lo lascia con una libreria vecchia (15 ottobre: gimp 3.2.6-2 voleva
    libgexiv2-0.16, rimasta 0.14 → non partiva più). Insieme all'app si aggiorna quindi tutto ciò che
    è legato a lei e ha un aggiornamento: le sue dipendenze e, a catena, gli altri pacchetti installati
    che usano le stesse librerie (se una libreria cambia versione, Termux ricompila anche loro).
    Mai i pacchetti bloccati né i driver grafici (mesa)."""
    held = set(run(["apt-mark", "showhold"])[1].split()) | PROTECTED
    upgradable = {u["name"] for u in parse_upgradable(run(["apt", "list", "--upgradable"])[1])} - held
    upgradable = {n for n in upgradable if not n.startswith("mesa")}
    flags = ["--installed", "--no-recommends", "--no-suggests", "--no-conflicts", "--no-breaks", "--no-replaces",
             "--no-enhances"]

    def names(out):
        return {l.strip().lstrip("|").strip() for l in out.splitlines() if l.strip() and not l.strip().startswith(("<", "Reverse"))
                and ":" not in l}
    chosen, todo = set(pkgs), set(pkgs)
    while todo:
        deps = names(run(["apt-cache", "depends", "--recurse"] + flags + sorted(todo))[1])
        rdeps = names(run(["apt-cache", "rdepends"] + flags + sorted(todo | (deps & upgradable)))[1])
        todo = ((deps | rdeps) & upgradable) - chosen
        chosen |= todo
    extra = sorted(chosen - set(pkgs))
    if extra:
        log("con i pacchetti legati: " + " ".join(extra))
    return list(pkgs) + extra


def human_mb(n):
    return (f"{n / 1e9:.1f} GB" if n >= 1e9 else f"{n / 1e6:.0f} MB" if n >= 1e6 else f"{max(n, 0) / 1e3:.0f} kB").replace(".", ",")


def parse_size(num, unit):
    # "1.234 kB" / "1,234 kB" (migliaia) e "12,3 MB" / "12.3 MB" (decimali), in italiano e in inglese
    if re.fullmatch(r"\d{1,3}([.,]\d{3})+", num):
        num = re.sub(r"[.,]", "", num)
    try:
        v = float(num.replace(",", "."))
    except ValueError:
        return 0
    return v * {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9}.get(unit, 1)


def tod_update(progress, base, span):
    """Termux On DeX dal suo ramo su GitHub (tod _self_update, poi i passi del codice nuovo). → (ok, nota)"""
    progress(base, T("Scaricamento di Termux On DeX…", "Downloading Termux On DeX…"))
    try:   # anche stderr: i messaggi di errore di tod (err, warn) vanno lì
        r = subprocess.run(["bash", TOD, "_self_update"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           timeout=1800)
        rc, out = r.returncode, re.sub(r"\x1b\[[0-9;]*m", "", r.stdout)
    except (OSError, subprocess.TimeoutExpired) as e:
        rc, out = 1, str(e)
    log("tod _self_update: " + out[-600:])
    if rc != 0:
        righe = [r.strip() for r in out.splitlines() if r.strip()]
        errori = [r for r in righe if r.startswith(("✘", "!"))]   # err/warn di tod: dopo viene "dettagli nel registro"
        return False, (errori or righe or [T("aggiornamento non riuscito", "update failed")])[-1].lstrip("✘! ")
    progress(base + span, T("Termux On DeX aggiornato", "Termux On DeX updated"))
    nota = T("Termux On DeX è aggiornato: barra, Start e finestre cambiano al prossimo avvio del desktop.",
             "Termux On DeX is updated: the taskbar, Start menu and windows change the next time the desktop starts.")
    if "x11=nuova" in out:   # installarla chiude Termux (sharedUid): non da qui
        nota += " " + T("C'è anche una nuova Termux:X11: installala da Termux con tod update (il desktop si chiude per un momento).",
                        "There's also a new Termux:X11: install it from Termux with tod update (the desktop closes for a moment).")
    return True, nota


def install(items, progress):
    """Aggiorna queste voci: Termux On DeX, poi Termux, poi Debian. progress(fraction, testo). → (ok, messaggio)

    Avanzamento vero da apt (APT::Status-Fd: "dlstatus" per lo scaricamento, "pmstatus" per
    l'installazione): ogni gruppo vale metà scaricamento e metà installazione, e durante lo
    scaricamento si mostrano MB fatti/totali, velocità e tempo che manca (Pietro: "non mi fa capire
    che sta lavorando, specialmente durante il download")."""
    names = {u["name"]: u.get("app") or u["name"] for u in items}
    groups = [(w, [u["name"] for u in items if u.get("where") == w]) for w in ("tod", "termux", "debian")]
    groups = [(w, p) for w, p in groups if p]
    nota = ""
    for gi, (where, pkgs) in enumerate(groups):
        base, span = gi / len(groups), 1 / len(groups)
        if where == "tod":
            ok, nota = tod_update(progress, base, span)
            if not ok:
                return False, nota
            continue
        progress(base, T("Preparazione…", "Preparing…"))
        status = ["-o", "APT::Status-Fd=1"]
        if where == "termux":
            pkgs = with_deps(pkgs)
            cmd = ["apt-get"] + APT_OPTS + status + ["install", "--only-upgrade"] + pkgs
        else:
            cmd = ["proot-distro", "login", DISTRO, "--", "apt-get"] + APT_OPTS + status + ["install", "--only-upgrade"] + pkgs
        log("installo: " + " ".join(cmd))
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 env=dict(os.environ, DEBIAN_FRONTEND="noninteractive"))
        except OSError as e:
            return False, str(e)
        tail, size, t0 = [], 0, None
        for line in p.stdout:
            line = line.rstrip()
            if not line.startswith(("dlstatus:", "pmstatus:")):
                tail = (tail + [line])[-8:]
            m = re.search(r"(?:Need to get|scaricare|prelevare) ([\d.,]+) ([kMG]?B)", line)
            if m:
                size = parse_size(*m.groups())
            parts = line.split(":", 3)
            if parts[0] == "dlstatus" and len(parts) == 4:
                pct = float(parts[2] or 0)
                t0 = t0 or time.time()
                txt = T("Scaricamento", "Downloading")
                if size:
                    got = size * pct / 100
                    txt += f" {human_mb(got)} {T('di', 'of')} {human_mb(size)}"
                    el = time.time() - t0
                    if el > 2 and got > 0:
                        speed = got / el
                        left = int((size - got) / speed)
                        txt += f" · {human_mb(speed)}/s"
                        if left > 0:
                            txt += " · " + (T(f"ancora {left // 60} min", f"{left // 60} min left") if left >= 90
                                            else T(f"ancora {left} s", f"{left} s left"))
                else:
                    txt += f"… {pct:.0f}%"
                progress(base + span * 0.5 * pct / 100, txt)
            elif parts[0] == "pmstatus" and len(parts) == 4:
                pct, pkg = float(parts[2] or 0), parts[1].split(":")[0]
                progress(base + span * (0.5 + 0.5 * pct / 100),
                         T(f"Installazione di {names.get(pkg, pkg)}…", f"Installing {names.get(pkg, pkg)}…"))
        if p.wait() != 0:
            log("errore:\n" + "\n".join(tail))
            return False, "\n".join(tail[-3:])
    progress(1.0, T("Fatto", "Done"))
    return True, nota


# --- finestra -----------------------------------------------------------------------------
def gui():
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")   # senza, Termux può caricare Gdk 4 e GTK 3 non parte
    gi.require_version("Pango", "1.0")
    from gi.repository import Gio, GLib, Gtk, Pango
    GLib.set_prgname("tod-updates")   # la barra riconosce la finestra (tod-updates.desktop) e ne mostra l'icona

    class Win(Gtk.Window):
        def __init__(self):
            super().__init__(title=T("Aggiornamenti", "Updates"))
            self.set_default_size(620, 560)
            self.set_icon_name("system-software-update")
            self.set_position(Gtk.WindowPosition.CENTER)
            self.closed_apps = []
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, margin=24)
            self.add(box)
            head = Gtk.Box(spacing=16)
            box.pack_start(head, False, False, 0)
            self.icon = Gtk.Image.new_from_icon_name("system-software-update", Gtk.IconSize.DIALOG)
            self.icon.set_pixel_size(56)
            head.pack_start(self.icon, False, False, 0)
            txt = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            txt.set_valign(Gtk.Align.CENTER)
            head.pack_start(txt, True, True, 0)
            self.title = Gtk.Label(xalign=0)
            self.title.set_line_wrap(True)
            txt.pack_start(self.title, False, False, 0)
            self.sub = Gtk.Label(xalign=0)
            self.sub.get_style_context().add_class("dim-label")
            txt.pack_start(self.sub, False, False, 0)
            self.check_btn = Gtk.Button(label=T("Controlla aggiornamenti", "Check for updates"))
            self.check_btn.set_valign(Gtk.Align.CENTER)
            self.check_btn.connect("clicked", lambda *a: self.recheck())
            head.pack_end(self.check_btn, False, False, 0)

            # barra con l'avanzamento vero e, accanto, una rotellina che gira sempre: si vede che lavora
            # anche quando apt resta qualche secondo sullo stesso punto
            self.bar = Gtk.ProgressBar(show_text=True)
            self.spin = Gtk.Spinner()
            prog = Gtk.Box(spacing=10)
            prog.pack_start(self.spin, False, False, 0)
            prog.pack_start(self.bar, True, True, 0)
            prog.set_no_show_all(True)
            self.spin.show()
            self.bar.show()
            self.prog = prog
            box.pack_start(prog, False, False, 0)

            sw = Gtk.ScrolledWindow()
            sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
            sw.add(self.list)
            box.pack_start(sw, True, True, 0)

            foot = Gtk.Box(spacing=8)
            box.pack_end(foot, False, False, 0)
            self.go = Gtk.Button(label=T("Aggiorna tutto", "Update all"))
            self.go.get_style_context().add_class("suggested-action")
            self.go.connect("clicked", lambda *a: self.start_install())
            self.row_buttons = []
            foot.pack_end(self.go, False, False, 0)
            self.st = load()
            self.fill()
            if not self.st or time.time() - self.st.get("time", 0) > 3600:
                self.recheck()

        def fill(self):
            for c in self.list.get_children():
                self.list.remove(c)
            st = self.st
            items = all_items(st)
            apps = [u for u in items if u.get("app")]
            system = [u for u in items if not u.get("app")]
            n = len(items)
            self.title.set_markup(f"<span size='x-large' weight='bold'>{GLib.markup_escape_text(summary(st) if n else T('Il sistema è aggiornato', 'Your system is up to date'))}</span>")
            when = time.strftime("%H:%M", time.localtime(st["time"])) if st.get("time") else "—"
            self.sub.set_text((st.get("error") + " · " if st.get("error") else "") +
                              T(f"Ultimo controllo: {when}", f"Last checked: {when}"))
            self.go.set_sensitive(n > 0)
            self.icon.set_from_icon_name("emblem-ok-symbolic" if not n else "system-software-update", Gtk.IconSize.DIALOG)
            self.row_buttons = []
            for u in apps:
                self.list.add(self.row(u["app"], u.get("icon") or "application-x-executable",
                                       u.get("desc") or f"{u['from']} → {u['to']}", [u]))
            if system:
                names = ", ".join(u["name"] for u in system[:12]) + ("…" if len(system) > 12 else "")
                self.list.add(self.row(T(f"Componenti di sistema ({len(system)})", f"System components ({len(system)})"),
                                       "preferences-system", names, system))
            self.list.show_all()

        def row(self, name, icon, sub, items=None):
            r = Gtk.ListBoxRow()
            h = Gtk.Box(spacing=14, margin=10)
            img = Gtk.Image()
            if icon.startswith("/"):
                img.set_from_gicon(Gio.FileIcon.new(Gio.File.new_for_path(icon)), Gtk.IconSize.DND)
            else:
                img.set_from_icon_name(icon, Gtk.IconSize.DND)
            img.set_pixel_size(32)
            h.pack_start(img, False, False, 0)
            v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            a = Gtk.Label(label=name, xalign=0)
            b = Gtk.Label(label=sub, xalign=0)
            b.set_ellipsize(Pango.EllipsizeMode.END)
            b.get_style_context().add_class("dim-label")
            v.pack_start(a, False, False, 0)
            v.pack_start(b, False, False, 0)
            h.pack_start(v, True, True, 0)
            if items:   # aggiornare una sola app (o i soli componenti di sistema)
                btn = Gtk.Button(label=T("Aggiorna", "Update"))
                btn.set_valign(Gtk.Align.CENTER)
                btn.connect("clicked", lambda *a: self.start_install(items))
                h.pack_end(btn, False, False, 0)
                self.row_buttons.append(btn)
            r.add(h)
            return r

        def busy(self, on, text=""):
            self.check_btn.set_sensitive(not on)
            for b in getattr(self, "row_buttons", []):
                b.set_sensitive(not on)
            self.go.set_sensitive(not on and bool(all_items(self.st)))
            self.prog.set_visible(on)
            (self.spin.start if on else self.spin.stop)()
            if on:
                self.bar.set_text(text)
                self.bar.set_fraction(0)

        def recheck(self):
            self.busy(True, T("Ricerca di aggiornamenti…", "Checking for updates…"))
            pulse = GLib.timeout_add(150, lambda: self.bar.pulse() or True)

            def work():
                st = check()
                GLib.idle_add(done, st)

            def done(st):
                GLib.source_remove(pulse)
                self.st = st
                self.busy(False)
                self.fill()
            threading.Thread(target=work, daemon=True).start()

        def start_install(self, items=None):
            if items is None:
                items = all_items(self.st)
            open_apps = [(u, running_pids(u.get("exe"))) for u in items if u.get("app")]
            open_apps = [(u, p) for u, p in open_apps if p]
            if open_apps:
                names = ", ".join(u["app"] for u, _ in open_apps)
                d = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                      buttons=Gtk.ButtonsType.NONE,
                                      text=T("Alcune app sono aperte", "Some apps are open"))
                d.format_secondary_text(T(f"Per aggiornare {names} bisogna chiuderle. Si riapriranno da sole alla fine. "
                                          "Salva prima il tuo lavoro.",
                                          f"To update {names} they must be closed. They will reopen when done. "
                                          "Save your work first."))
                d.add_buttons(T("Annulla", "Cancel"), Gtk.ResponseType.CANCEL,
                              T("Chiudi e aggiorna", "Close and update"), Gtk.ResponseType.OK)
                ok = d.run() == Gtk.ResponseType.OK
                d.destroy()
                if not ok:
                    return
                for u, pids in open_apps:
                    for p in pids:
                        try:
                            os.kill(p, signal.SIGTERM)
                        except OSError:
                            pass
                    self.closed_apps.append(u)
                for _ in range(40):   # fino a 10 s perché si chiudano
                    if not any(running_pids(u.get("exe")) for u, _ in open_apps):
                        break
                    time.sleep(0.25)
            self.busy(True, T("Preparazione…", "Preparing…"))

            def progress(frac, text):
                GLib.idle_add(lambda: (self.bar.set_fraction(frac), self.bar.set_text(text)) and False)

            def work():
                ok, msg = install(items, progress)
                st = check(refresh=False)
                GLib.idle_add(done, ok, msg, st)

            def done(ok, msg, st):
                self.st = st
                self.busy(False)
                self.fill()
                if not ok:
                    self.sub.set_text(T("Qualcosa non è andato: ", "Something went wrong: ") + msg.splitlines()[-1] if msg else "")
                elif msg:   # dopo Termux On DeX: cosa cambia e quando
                    self.sub.set_text(msg)
                    self.sub.set_line_wrap(True)
                for u in self.closed_apps:   # si riaprono le app chiuse per l'aggiornamento
                    for prefix in ("", "tod-cx-"):
                        try:
                            Gio.DesktopAppInfo.new(prefix + u["desktop"]).launch([], None)
                            break
                        except (TypeError, GLib.Error):
                            continue
                self.closed_apps = []
            threading.Thread(target=work, daemon=True).start()

    w = Win()
    w.connect("destroy", Gtk.main_quit)
    w.show_all()
    Gtk.main()
    return 0


def main():
    args = sys.argv[1:]
    if args[:1] in (["controlla"], ["check"]):
        if "--ciclo" in args or "--loop" in args:
            return loop()
        st = check()
        print(json.dumps({k: len(st[k]) for k in ("tod", "termux", "debian")}))
        return 0
    return gui()


if __name__ == "__main__":
    sys.exit(main())
