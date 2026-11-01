# tod-app-keys.awk - Termux On DeX: "chi è" un'app, per non averla in due sistemi.
# La stessa app ha nomi diversi tra Termux e Debian (firefox / firefox-esr, vlc-qt / vlc,
# org.gimp.GIMP.desktop / gimp): la chiave è il nome ridotto all'osso.
#
#   awk -f tod-app-keys.awk -v mode=names            nomi di pacchetto (uno per riga) → chiave
#   grep -H '/share/applications/[^/]*\.desktop$' INFO/*.list |
#     awk -f tod-app-keys.awk -v mode=installed -v root=ROOTFS
#                                                     app installate (solo quelle visibili
#                                                     nel menu) → "chiave<TAB>pacchetto"
# Gira con mawk (Debian), gawk e busybox awk.

function norm(x,    a, n) {
  x = tolower(x)
  sub(/\.desktop$/, "", x)
  sub(/:[a-z0-9]+$/, "", x)                      # gimp:arm64
  if (x in alias) return alias[x]
  if (gsub(/\./, ".", x) >= 2) { n = split(x, a, "."); x = a[n] }   # org.gimp.GIMP → gimp
  while (sub(/-(esr|qt|qt5|qt6|gtk|gtk3|gtk4|bin|stable|oss|nightly|beta|latest)$/, "", x)) {}
  if (x in alias) x = alias[x]
  return x
}

function visible(f,    l, hidden) {   # NoDisplay=true: componente nascosto, non un'app
  hidden = 0
  while ((getline l < f) > 0) {
    if (l ~ /^NoDisplay=true/) { hidden = 1; break }
  }
  close(f)
  return !hidden
}

BEGIN {
  # stessi programmi, nomi che la riduzione non avvicina
  alias["code"] = "vscode"; alias["codium"] = "vscode"; alias["vscodium"] = "vscode"
  alias["visual-studio-code"] = "vscode"
  alias["chromium-browser"] = "chromium"
  alias["obs-studio"] = "obs"; alias["com.obsproject.studio"] = "obs"
  alias["libreoffice-startcenter"] = "libreoffice"
}

mode == "names" { if ($0 != "") print norm($0); next }

mode == "installed" {
  i = index($0, ":/")
  if (!i) next
  list = substr($0, 1, i - 1); path = substr($0, i + 1)
  n = split(list, a, "/"); pkg = a[n]; sub(/\.list$/, "", pkg); sub(/:[a-z0-9]+$/, "", pkg)
  if (!visible(root path)) next
  n = split(path, b, "/")
  k1 = norm(pkg); k2 = norm(b[n])
  if (!seen[k1 "\t" pkg]++) print k1 "\t" pkg
  if (!seen[k2 "\t" pkg]++) print k2 "\t" pkg
}
