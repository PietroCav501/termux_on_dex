#!/usr/bin/env python3
"""Copia del caricatore e della libc di Debian che girano senza proot su Android (lib/diretto.sh).

  correggi.py <origine> <copia> [<origine> <copia>...]

Android (seccomp) chiude le app che chiamano set_robust_list: il glibc la chiama al suo interno,
prima di qualunque libreria precaricata. Nella copia ogni "svc #0" di quella chiamata diventa
"movn x0, #37", cioè la risposta -ENOSYS di un kernel che non la conosce (il glibc la sa gestire).
I file che il glibc apre al suo interno (fakechroot non li vede) diventano /dev/fd/NN, aperti da
tod-diretto.so all'avvio sui file del container (stessi numeri in tod-diretto.c, FILE_GLIBC).
"""
import os
import struct
import sys

VIETATE = {99: "set_robust_list"}
SVC = 0xD4000001
ENOSYS = 0x92800000 | (37 << 5)   # movn x0, #37 → x0 = -38
FILE = {
    "/etc/resolv.conf": 97, "/etc/hosts": 96, "/etc/passwd": 95, "/etc/group": 94,
    "/etc/nsswitch.conf": 93, "/usr/lib/locale/locale-archive": 92, "/etc/services": 91,
    "/etc/host.conf": 90, "/etc/gai.conf": 89,
}


def correggi(src, dst):
    b = bytearray(open(src, "rb").read())
    chiamate = 0
    for off in range(0, len(b) - 4, 4):
        if struct.unpack_from("<I", b, off)[0] != SVC:
            continue
        for k in range(1, 13):   # il numero della chiamata va in w8/x8 poco prima
            o = off - 4 * k
            if o < 0:
                break
            ins = struct.unpack_from("<I", b, o)[0]
            if (ins & 0x7FE0001F) == 0x52800008:   # movz w8/x8, #imm
                if (ins >> 5) & 0xFFFF in VIETATE:
                    struct.pack_into("<I", b, off, ENOSYS)
                    chiamate += 1
                break
    percorsi = 0
    for vecchio, fd in FILE.items():
        v = b"\0" + vecchio.encode() + b"\0"
        n = f"/dev/fd/{fd}".encode()
        nuovo = b"\0" + n + b"\0" * (len(v) - len(n) - 1)
        percorsi += b.count(v)
        b[:] = b.replace(v, nuovo)
    with open(dst + f".{os.getpid()}", "wb") as f:
        f.write(b)
    print(f"{dst}: {chiamate} chiamate, {percorsi} percorsi")
    return dst + f".{os.getpid()}"


def main(a):
    if len(a) < 2 or len(a) % 2:
        sys.exit(__doc__)
    fatti = [(correggi(a[i], a[i + 1]), a[i + 1]) for i in range(0, len(a), 2)]
    for tmp, dst in fatti:
        os.chmod(tmp, 0o755)
        os.replace(tmp, dst)   # un nome nuovo: i programmi già avviati tengono la copia vecchia


if __name__ == "__main__":
    main(sys.argv[1:])
