#!/usr/bin/env python3
"""collegamenti.py rootfs - i collegamenti assoluti del container diventano relativi.

Senza proot fakechroot traduce solo il percorso che l'app chiede: un collegamento assoluto
(/usr/lib/ssl/cert.pem -> /etc/ssl/certs/ca-certificates.crt) il kernel lo segue sul vero Android,
dove non c'è niente. Così HTTPS di OpenSSL, awk, which (/etc/alternatives) e la configurazione dei
caratteri (/etc/fonts/conf.d) erano rotti (26 ottobre). Un collegamento relativo porta allo stesso
file anche in proot. Restano com'erano quelli verso le cartelle vere di Android (/data, /proc...).
"""
import os
import sys

FUORI = ("/proc", "/dev", "/sys", "/data", "/storage", "/sdcard", "/apex", "/system", "/vendor",
         "/odm", "/product", "/mnt", "/run")
CARTELLE = ("etc", "usr", "opt", "var", "lib", "bin", "sbin", "srv")


def esterno(t):
    return any(t == f or t.startswith(f + "/") for f in FUORI)


def main(root):
    root = os.path.realpath(root)
    fatti = 0
    for top in CARTELLE:
        base = os.path.join(root, top)
        # /lib, /bin, /sbin sono collegamenti a usr/ (usrmerge): si visitano una volta sola, da /usr
        if os.path.islink(base) or not os.path.isdir(base):
            continue
        for d, dirs, files in os.walk(base):   # non segue i collegamenti: d è sempre un percorso vero
            for nome in dirs + files:
                p = os.path.join(d, nome)
                if not os.path.islink(p):
                    continue
                t = os.readlink(p)
                if not t.startswith("/") or esterno(t):
                    continue
                rel = os.path.relpath(t, "/" + os.path.relpath(d, root))
                tmp = p + ".tod-rel"
                try:
                    if os.path.lexists(tmp):
                        os.remove(tmp)
                    os.symlink(rel, tmp)
                    os.replace(tmp, p)
                    fatti += 1
                except OSError as e:
                    print(f"collegamenti: {p[len(root):]}: {e}", file=sys.stderr)
    print(f"collegamenti resi relativi: {fatti}")


if __name__ == "__main__":
    main(sys.argv[1])
