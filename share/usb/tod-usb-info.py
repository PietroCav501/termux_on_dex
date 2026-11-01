#!/usr/bin/env python3
"""Descrive il dispositivo USB aperto da termux-usb (fd in TERMUX_USB_FD).

  termux-usb -r -e tod-usb-info.py /dev/bus/usb/BBB/DDD

Leggere il file usbfs restituisce i descrittori (dispositivo + configurazioni): da lì vendor,
prodotto e classi delle interfacce. Classe 8 = memoria di massa (chiavette, dischi). Stampa JSON.
"""
import json
import os
import sys

fd = int(os.environ.get("TERMUX_USB_FD") or (sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].isdigit() else -1))
os.lseek(fd, 0, os.SEEK_SET)
raw = os.read(fd, 4096)
info = {"vendor": None, "product": None, "classes": []}
i = 0
while i + 2 <= len(raw):
    ln, typ = raw[i], raw[i + 1]
    if ln < 2:
        break
    d = raw[i:i + ln]
    if typ == 1 and ln >= 18:   # dispositivo
        info["vendor"] = "%04x" % (d[8] | d[9] << 8)
        info["product"] = "%04x" % (d[10] | d[11] << 8)
        info["device_class"] = d[4]
    elif typ == 4 and ln >= 9:   # interfaccia
        info["classes"].append(d[5])
    i += ln
info["storage"] = 8 in info["classes"]
print(json.dumps(info))
