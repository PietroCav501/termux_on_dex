#!/usr/bin/env python3
"""App del telefono nel desktop Linux: una voce di menu (con la sua icona) per ogni app Android.

Va eseguito in Termux (non nel proot): usa cmd/pm di Android, aapt2, dwebp e rsvg-convert.
Per ogni app avviabile scrive ~/.local/share/applications/tod-android-<pacchetto>.desktop,
che la apre con "am start" in una finestra di DeX. Le icone moderne sono "adattive" (sfondo +
simbolo, spesso vettoriali): le ricompone in SVG e le rende in PNG, con gli angoli arrotondati.
Tutto è tenuto in cache per versione dell'app: le esecuzioni successive sono rapide.

uso: tod-android-apps.py [--only pacchetto] [--force]
"""
import base64
import json
import os
import re
import subprocess
import sys
import tempfile

HOME = os.environ.get("TOD_TERMUX_HOME") or os.path.expanduser("~")
PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
APPS = os.path.join(HOME, ".local/share/applications")
ICONS = os.path.join(HOME, ".local/share/icons/tod-android")
CACHE = os.path.join(HOME, ".cache/tod/android-apps.json")
SIZE = 128
DENSITIES = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi", "anydpi", ""]


def run(*cmd, timeout=120):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              errors="replace").stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def run_bytes(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return b""


# ---------------------------------------------------------------- elenco delle app
def launcher_activities():
    out = run("cmd", "package", "query-activities", "--brief", "--user", "0",
              "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER")
    comps = {}
    for line in out.splitlines():
        line = line.strip()
        if "/" in line and " " not in line:
            pkg, act = line.split("/", 1)
            if act.startswith("."):
                act = pkg + act
            comps.setdefault(pkg, f"{pkg}/{act}")
    return comps


def versions():
    out = run("cmd", "package", "list", "packages", "--show-versioncode", "--user", "0")
    v = {}
    for line in out.splitlines():
        m = re.match(r"package:(\S+) versionCode:(\d+)", line.strip())
        if m:
            v[m.group(1)] = m.group(2)
    return v


def apk_paths(pkg):
    """[base, pezzi...]: le app "divise" tengono le icone nei pezzi per densità (split_config.xxhdpi.apk)"""
    out = run("pm", "path", pkg)
    paths = [line[8:] for line in out.splitlines() if line.startswith("package:") and line.endswith(".apk")]
    # base.apk per le app scaricate, Nome.apk per quelle di sistema (es. SecSettings.apk)
    paths.sort(key=lambda p: (not p.endswith("/base.apk"), "dpi" not in p, p))
    return paths


def apk_path(pkg):
    paths = apk_paths(pkg)
    return paths[0] if paths else None


# ---------------------------------------------------------------- lettura dell'APK
class Apk:
    def __init__(self, path, splits=()):
        self.path = path
        self.splits = [p for p in splits if p != path]
        self._res = None

    def badging(self):
        out = run("aapt2", "dump", "badging", self.path)
        label = label_it = icon = None
        best = -1
        for line in out.splitlines():
            if line.startswith("application-label-it:"):
                label_it = line.split(":", 1)[1].strip().strip("'")
            elif line.startswith("application-label:"):
                label = line.split(":", 1)[1].strip().strip("'")
            m = re.match(r"application-icon-(\d+):'(.+)'", line)
            if m and int(m.group(1)) > best:
                best, icon = int(m.group(1)), m.group(2)
            if line.startswith("application:") and icon is None:
                m = re.search(r"icon='([^']+)'", line)
                if m:
                    icon = m.group(1)
        if not icon:   # badging a volte non la trova (icona solo in drawable-xxx): dal manifest
            icon = self.manifest_icon()
        return (label_it or label), icon

    def manifest_icon(self):
        tree = self.xmltree("AndroidManifest.xml")
        in_app = False
        for line in tree.splitlines():
            if "E: application" in line:
                in_app = True
            m = re.search(r":icon\(0x01010002\)=(@0x[0-9a-f]+)", line)
            if in_app and m:
                r = self.resolve(m.group(1))
                return r[1] if r and r[0] == "file" else None
        return None

    def read(self, name):
        for p in [self.path] + self.splits:
            data = run_bytes("unzip", "-p", p, name)
            if data:
                return data
        return b""

    def xmltree(self, name):
        for p in [self.path] + self.splits:   # il file può stare in un pezzo (split_config.xxhdpi.apk)
            out = run("aapt2", "dump", "xmltree", "--file", name, p)
            if "E: " in out:
                return out
        return ""

    def resources(self):
        """id (0x7f...) → [(config, valore)] per i tipi che servono alle icone"""
        if self._res is None:
            self._res = {}
            out = run("aapt2", "dump", "resources", self.path, timeout=300)
            for sp in self.splits:   # i pezzi per densità aggiungono i file delle icone
                if "dpi" in sp:
                    out += "\n" + run("aapt2", "dump", "resources", sp, timeout=300)
            cur = None
            for line in out.splitlines():
                m = re.match(r"\s+resource (0x[0-9a-f]+) (\w+)/", line)
                if m:
                    cur = m.group(1) if m.group(2) in ("mipmap", "drawable", "color") else None
                    if cur:
                        self._res.setdefault(cur, [])
                    continue
                if cur:
                    m = re.match(r"\s+\(([^)]*)\) (.*)", line)
                    if m:
                        self._res[cur].append((m.group(1), m.group(2).strip()))
        return self._res

    def resolve(self, ref):
        """@0x7f.. → ("file", percorso) | ("color", "#rrggbb", alfa) | None"""
        rid = ref.lstrip("@").lower()
        if rid.startswith("0x01"):   # risorsa di Android (es. @android:color/white di Chrome)
            return ("color",) + FRAMEWORK_COLORS.get(rid, ("#ffffff", 1.0))
        vals = self.resources().get(ref.lstrip("@").lower())
        if not vals:
            return None
        def rank(cfg):
            for i, d in enumerate(DENSITIES):
                if d and d in cfg:
                    return i
            return len(DENSITIES)
        vals = sorted(vals, key=lambda cv: rank(cv[0]))
        for cfg, v in vals:
            if "night" in cfg:
                continue
            if v.startswith("(file)"):
                return ("file", v.split()[1])
            m = re.search(r"#([0-9a-f]{6,8})", v)
            if m:
                return ("color",) + argb(m.group(1))
            m = re.match(r"@(0x[0-9a-f]+)", v)
            if m:
                return self.resolve(m.group(1))
        return None


FRAMEWORK_COLORS = {
    "0x01060000": ("#000000", 1.0),   # background_dark
    "0x01060001": ("#ffffff", 1.0),   # background_light
    "0x0106000b": ("#ffffff", 1.0),   # white
    "0x0106000c": ("#000000", 1.0),   # black
    "0x0106000d": ("#000000", 0.0),   # transparent
}


def argb(h):
    h = h.lower()
    if len(h) == 8:
        return "#" + h[2:], int(h[:2], 16) / 255
    return "#" + h, 1.0


# ---------------------------------------------------------------- disegni → SVG
def kind(apk, path):
    """dal contenuto, non dal nome (Chrome offusca i nomi: res/ima): png | webp | xml | None"""
    head = apk.read(path)[:16]
    if head.startswith(b"\x89PNG"):
        return "png"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    if head[:2] == b"\x03\x00":
        return "xml"
    return None


def image_href(apk, path):
    data = apk.read(path)
    if not data:
        return None
    k = "png" if data.startswith(b"\x89PNG") else "webp" if data[8:12] == b"WEBP" else None
    if k == "webp":
        with tempfile.TemporaryDirectory() as d:
            src, dst = os.path.join(d, "i.webp"), os.path.join(d, "i.png")
            open(src, "wb").write(data)
            run("dwebp", "-quiet", src, "-o", dst)
            if not os.path.exists(dst):
                return None
            data = open(dst, "rb").read()
    elif k != "png":
        return None
    return "data:image/png;base64," + base64.b64encode(data).decode()


# attributi senza nome (APK offuscati, es. Netflix: "A: (0x01010199)=@0x..."): dal loro id
ATTR_IDS = {
    "0x01010199": "drawable", "0x01010119": "src", "0x010104b5": "inset",
    "0x01010402": "viewportWidth", "0x01010403": "viewportHeight",
    "0x01010404": "fillColor", "0x01010405": "pathData", "0x01010406": "strokeColor",
    "0x01010407": "strokeWidth", "0x010101a5": "color",
}


def xml_nodes(tree):
    """xmltree di aapt2 → lista di (profondità, tag, {attr: valore})"""
    nodes = []
    for line in tree.splitlines():
        m = re.match(r"(\s*)E: (\S+)", line)
        if m:
            nodes.append([len(m.group(1)), m.group(2), {}])
            continue
        name = val = None
        m = re.match(r"\s*A: (?:\S*:)?(\w+)\(0x[0-9a-f]+\)=(.*)", line)
        if m:
            name, val = m.group(1), m.group(2)
        else:
            m = re.match(r"\s*A: \((0x[0-9a-f]+)\)=(.*)", line)
            if m and m.group(1) in ATTR_IDS:
                name, val = ATTR_IDS[m.group(1)], m.group(2)
            else:
                m = re.match(r"\s*A: (?:\S*:)?(\w+)=(.*)", line)
                if m:
                    name, val = m.group(1), m.group(2)
        if name and nodes:
            v = val.strip()
            v = re.sub(r'^"(.*)"(?: \(Raw: .*\))?$', r"\1", v)
            nodes[-1][2][name] = v
    return nodes


def color_of(apk, v):
    if v is None:
        return None, 1.0
    m = re.match(r"#([0-9a-f]{6,8})$", v.lower())
    if m:
        return argb(m.group(1))
    m = re.search(r"0x([0-9a-f]{8})$", v.lower())   # (type 0x1d)0xff4285f4
    if m:
        return argb(m.group(1))
    if v.startswith("@"):
        r = apk.resolve(v)
        if r and r[0] == "color":
            return r[1], r[2]
    return None, 1.0


def num(v, d=0.0):
    try:
        return float(re.sub(r"^\(type 0x\w+\)", "", v).rstrip("dip"))
    except (TypeError, ValueError):
        return d


def vector_svg(apk, nodes):
    """VectorDrawable → (viewport_w, viewport_h, contenuto SVG)"""
    root = nodes[0][2]
    vw = num(root.get("viewportWidth"), 24)
    vh = num(root.get("viewportHeight"), 24)
    out, stack = [], []
    for depth, tag, a in nodes[1:]:
        while stack and stack[-1] >= depth:
            out.append("</g>")
            stack.pop()
        if tag == "group":
            px, py = num(a.get("pivotX")), num(a.get("pivotY"))
            t = (f"translate({num(a.get('translateX'))} {num(a.get('translateY'))}) "
                 f"translate({px} {py}) rotate({num(a.get('rotation'))}) "
                 f"scale({num(a.get('scaleX'), 1)} {num(a.get('scaleY'), 1)}) translate({-px} {-py})")
            out.append(f'<g transform="{t}">')
            stack.append(depth)
        elif tag == "path" and a.get("pathData"):
            fill, fa = color_of(apk, a.get("fillColor"))
            stroke, sa = color_of(apk, a.get("strokeColor"))
            alpha = num(a.get("fillAlpha"), 1.0) * fa
            rule = "evenodd" if a.get("fillType", "").endswith("1") or "evenOdd" in a.get("fillType", "") else "nonzero"
            s = (f'<path d="{a["pathData"]}" fill="{fill or "none"}" fill-opacity="{alpha:.3f}" fill-rule="{rule}"')
            if stroke:
                s += f' stroke="{stroke}" stroke-opacity="{sa:.3f}" stroke-width="{num(a.get("strokeWidth"), 1)}"'
            out.append(s + "/>")
        elif tag == "clip-path" and a.get("pathData"):
            pass   # raro nelle icone: ignorato
    out.extend("</g>" for _ in stack)
    return vw, vh, "".join(out)


def layer(apk, ref, inset=0.0):
    """un livello dell'icona adattiva (108x108) come frammento SVG"""
    if ref is None:
        return ""
    if ref.startswith("#") or ref.startswith("(type"):
        c, a = color_of(apk, ref)
        return f'<rect width="108" height="108" fill="{c}" fill-opacity="{a:.3f}"/>' if c else ""
    r = apk.resolve(ref)
    if r is None:
        return ""
    if r[0] == "color":
        return f'<rect width="108" height="108" fill="{r[1]}" fill-opacity="{r[2]:.3f}"/>'
    path = r[1]
    box = 108 * inset
    size = 108 - 2 * box
    if kind(apk, path) in ("png", "webp"):
        href = image_href(apk, path)
        if not href:
            return ""
        return f'<image x="{box}" y="{box}" width="{size}" height="{size}" href="{href}"/>'
    nodes = xml_nodes(apk.xmltree(path))
    if not nodes:
        return ""
    tag = nodes[0][1]
    if tag == "vector":
        vw, vh, body = vector_svg(apk, nodes)
        return (f'<svg x="{box}" y="{box}" width="{size}" height="{size}" viewBox="0 0 {vw} {vh}" '
                f'preserveAspectRatio="none">{body}</svg>')
    if tag == "inset":
        a = nodes[0][2]
        return layer(apk, a.get("drawable"), inset + inset_fraction(a.get("inset")))
    if tag in ("bitmap",):
        return layer(apk, nodes[0][2].get("src"), inset)
    if tag == "layer-list":
        return "".join(layer(apk, a.get("drawable"), inset) for d, t, a in nodes if t == "item" and a.get("drawable"))
    if tag == "shape":
        for d, t, a in nodes:
            if t == "solid":
                c, al = color_of(apk, a.get("color"))
                if c:
                    return f'<rect width="108" height="108" fill="{c}" fill-opacity="{al:.3f}"/>'
    return ""


def inset_fraction(v):
    """frazione di Android (TYPE_FRACTION, "(type 0x6)0x147ae30") → 0.01"""
    if not v:
        return 0.0
    m = re.search(r"\(type 0x6\)0x([0-9a-f]+)", v)
    if not m:
        return 0.0
    x = int(m.group(1), 16)
    if x & 0x80000000:
        x -= 1 << 32
    mant = x & ~0xff
    radix = (x >> 4) & 3
    return mant * [1.0, 1.0 / (1 << 7), 1.0 / (1 << 15), 1.0 / (1 << 23)][radix] / (1 << 8)


def icon_svg(apk, icon):
    """→ SVG completo dell'icona, o None"""
    clip = '<clipPath id="c"><rect x="18" y="18" width="72" height="72" rx="17" ry="17"/></clipPath>'
    if kind(apk, icon) in ("png", "webp"):
        href = image_href(apk, icon)
        if not href:
            return None
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">'
                f'<image width="108" height="108" href="{href}"/></svg>')
    nodes = xml_nodes(apk.xmltree(icon))
    if not nodes:
        return None
    if nodes[0][1] != "adaptive-icon":   # icona vettoriale semplice o bitmap in XML
        tmp = ""
        if nodes[0][1] == "vector":
            vw, vh, b = vector_svg(apk, nodes)
            tmp = f'<svg width="108" height="108" viewBox="0 0 {vw} {vh}">{b}</svg>'
        elif nodes[0][1] == "bitmap":
            tmp = layer(apk, nodes[0][2].get("src"))
        return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">{tmp}</svg>' if tmp else None
    bg = fg = ""
    for i, (depth, tag, a) in enumerate(nodes):
        if tag in ("background", "foreground"):
            frag = ""
            if a.get("drawable"):
                frag = layer(apk, a["drawable"])
            else:   # disegno in linea (es. <inset> dentro <foreground>)
                for d2, t2, a2 in nodes[i + 1:]:
                    if d2 <= depth:
                        break
                    if t2 == "inset" and a2.get("drawable"):
                        frag = layer(apk, a2["drawable"], inset_fraction(a2.get("inset")))
                        break
                    if t2 == "bitmap" and a2.get("src"):   # <bitmap android:src=...> in linea (Google Foto)
                        frag = layer(apk, a2["src"])
                        break
                    if t2 == "color" or a2.get("color"):
                        c, al = color_of(apk, a2.get("color"))
                        if c:
                            frag = f'<rect width="108" height="108" fill="{c}"/>'
                            break
            if tag == "background":
                bg = frag
            else:
                fg = frag
    if not bg and not fg:
        return None
    if not bg:
        bg = '<rect width="108" height="108" fill="#ffffff"/>'
    # i launcher mostrano solo il centro (72 su 108) dei due livelli, con gli angoli arrotondati
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="18 18 72 72"><defs>{clip}</defs>'
            f'<g clip-path="url(#c)">{bg}{fg}</g></svg>')


def letter_svg(label):
    ch = (label or "?")[:1].upper()
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">'
            '<rect width="108" height="108" rx="26" fill="#5b6b7f"/>'
            f'<text x="54" y="72" font-family="Inter, sans-serif" font-size="52" fill="#fff" '
            f'text-anchor="middle">{ch}</text></svg>')


def render(svg, out):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg)
        src = f.name
    try:
        run("rsvg-convert", "-w", str(SIZE), "-h", str(SIZE), "-o", out, src)
    finally:
        os.unlink(src)
    return os.path.exists(out) and os.path.getsize(out) > 0


# ---------------------------------------------------------------- voci di menu
def desktop_entry(pkg, comp, label, icon):
    am = os.path.join(PREFIX, "bin", "am")
    return "\n".join([
        "[Desktop Entry]",
        "Type=Application",
        f"Name={label}",
        "Comment=App del telefono",
        f"Exec={am} start --user 0 -n {comp}",
        f"Icon={icon}",
        "Terminal=false",
        "Categories=X-Android;",
        "X-TOD-Android=true",
        f"X-TOD-Package={pkg}",
        "",
    ])


def spente():
    """Interruttore "App del telefono nello Start" (ANDROID_APPS=0 in tod.conf): letto a ogni app, così
    spegnerlo mentre il generatore lavora in sottofondo lo ferma davvero."""
    try:
        for line in open(os.path.join(HOME, ".config/tod/tod.conf")):
            if line.startswith("ANDROID_APPS="):
                return line.split("=", 1)[1].strip().strip('"') == "0"
    except OSError:
        pass
    return False


def togli_tutte():
    for f in os.listdir(APPS):
        if f.startswith("tod-android-") and f.endswith(".desktop"):
            os.unlink(os.path.join(APPS, f))


def main():
    if spente():
        togli_tutte()
        return 0
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    force = "--force" in sys.argv
    os.makedirs(APPS, exist_ok=True)
    os.makedirs(ICONS, exist_ok=True)
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    try:
        cache = json.load(open(CACHE))
    except (OSError, ValueError):
        cache = {}
    comps = launcher_activities()
    if not comps:
        print("tod-android-apps: nessuna app trovata (va eseguito in Termux, non nel proot)", file=sys.stderr)
        return 1
    vers = versions()
    own = {"com.termux", "com.termux.x11"}
    done = 0
    for pkg, comp in sorted(comps.items()):
        if pkg in own or (only and pkg != only):
            continue
        if spente():   # spente mentre si lavorava: via tutto, e basta
            togli_tutte()
            json.dump(cache, open(CACHE, "w"), indent=1)
            return 0
        key = f"{vers.get(pkg, '?')}|{comp}"
        entry = os.path.join(APPS, f"tod-android-{pkg}.desktop")
        png = os.path.join(ICONS, f"{pkg}.png")
        c = cache.get(pkg, {})
        if (not force and c.get("key") == key and c.get("icon") == "app"   # le lettere si riprovano
                and os.path.exists(entry) and os.path.exists(png)):
            continue
        paths = apk_paths(pkg)
        if not paths:
            continue
        apk = Apk(paths[0], paths[1:])
        label, icon = apk.badging()
        label = label or pkg.split(".")[-1]
        svg = icon_svg(apk, icon) if icon else None
        ok = bool(svg) and render(svg, png)
        if not ok:
            render(letter_svg(label), png)
        with open(entry, "w") as f:
            f.write(desktop_entry(pkg, comp, label, png))
        cache[pkg] = {"key": key, "label": label, "icon": "app" if ok else "lettera"}
        done += 1
        print(f"{pkg}: {label} ({cache[pkg]['icon']})", flush=True)
    # app disinstallate: via le loro voci
    for f in os.listdir(APPS):
        m = re.match(r"tod-android-(.+)\.desktop$", f)
        if m and m.group(1) not in comps and not only:
            os.unlink(os.path.join(APPS, f))
            cache.pop(m.group(1), None)
    json.dump(cache, open(CACHE, "w"), indent=1)
    print(f"tod-android-apps: {done} aggiornate, {len(comps)} app del telefono", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
