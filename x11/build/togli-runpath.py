#!/usr/bin/env python3
"""togli-runpath.py file.so: toglie DT_RUNPATH/DT_RPATH dalla sezione dinamica (il clang di Termux li
aggiunge sempre; le librerie per Android non devono averli, sennò caricano le librerie di Termux)."""
import struct
import sys

f = sys.argv[1]
d = bytearray(open(f, "rb").read())
assert d[:4] == b"\x7fELF" and d[4] == 2 and d[5] == 1, "serve un ELF a 64 bit little endian"
phoff, = struct.unpack_from("<Q", d, 0x20)
phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
for i in range(phnum):
    p = phoff + i * phentsize
    tipo, = struct.unpack_from("<I", d, p)
    if tipo != 2:   # PT_DYNAMIC
        continue
    off, = struct.unpack_from("<Q", d, p + 8)
    size, = struct.unpack_from("<Q", d, p + 32)
    voci = [struct.unpack_from("<qQ", d, off + k) for k in range(0, size, 16)]
    tenute = [v for v in voci if v[0] not in (15, 29)]   # DT_RPATH, DT_RUNPATH
    tolte = len(voci) - len(tenute)
    tenute += [(0, 0)] * tolte
    for k, (t, v) in enumerate(tenute):
        struct.pack_into("<qQ", d, off + 16 * k, t, v)
    open(f, "wb").write(d)
    print(f"{f}: tolte {tolte} voci RUNPATH/RPATH")
    break
