#!/usr/bin/env python3
"""Lint su misura per script bash con `set -Eeuo pipefail`.

Segnala:
  E1  funzioni che terminano con `cond && azione` (ritornano 1 se cond è falsa
      → il chiamante esce con set -e), esclusi i predicati booleani dichiarati
  E2  `| head` (con pipefail può dare SIGPIPE → errore casuale)
  E3  `local var=$(...)` (maschera il codice d'uscita)
"""
import re, sys, pathlib

# funzioni che sono *predicati*: il loro valore di ritorno È il risultato
PREDICATES = {
    "gpu_glitchy", "files_phone_ok", "files_user_valid", "shizuku_ready", "android_apps_ready", "phone_status_ready", "cx_has", "cx_pkg_installed", "cx_is_electron", "look_dark", "look_dexos_ok",
    "step_done", "ui_has_dialog", "x11_running", "sha256_ok", "gpu_vk_ok",
    "phantom_verify", "virgl_running", "virgl_start", "cx_installed", "x11_app_installed",
    "pkg_installed", "pkg_has", "session_running", "have", "ui_yesno", "tui_available", "lingua_active", "phantom_verify_default",
    "bv_wanted", "bv_alive", "usb_bg_running", "tui_quiet", "app_rx",
}

func_re = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{")
QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")

def code_only(line):
    """Toglie stringhe tra apici e commenti finali: resta solo il codice shell."""
    line = QUOTED.sub("''", line)
    return line.split(" #")[0] if not line.lstrip().startswith("#") else ""
problems = 0
for path in sys.argv[1:]:
    lines = pathlib.Path(path).read_text().splitlines()
    current, body = None, []
    for no, line in enumerate(lines, 1):
        m = func_re.match(line)
        if m:
            current, body = m.group(1), []
            # funzione su una riga: f() { ...; }
            if line.rstrip().endswith("}") and line.count("{") == line.count("}"):
                inner = line[line.index("{") + 1: line.rindex("}")].strip().rstrip(";")
                last = code_only(inner.split(";")[-1].strip())
                if "&&" in last and "||" not in last and current not in PREDICATES:
                    print(f"{path}:{no}: E1 {current}: termina con '&&': {last}")
                    problems += 1
                current = None
            continue
        if current and line.startswith("}"):
            stmts = [l.strip() for l in body if l.strip() and not l.strip().startswith("#")]
            if stmts:
                last = code_only(stmts[-1])
                if ("&&" in last and "||" not in last and not last.startswith(("if ", "for ", "while "))
                        and current not in PREDICATES):
                    print(f"{path}:{no}: E1 {current}: termina con '&&': {last}")
                    problems += 1
            current = None
            continue
        if current is not None:
            body.append(line)
    for no, line in enumerate(lines, 1):
        code = code_only(line)
        if re.search(r"\|\s*head\b", code):
            print(f"{path}:{no}: E2 '| head' con pipefail: {line.strip()}")
            problems += 1
        if re.search(r"\blocal\s+[A-Za-z_][A-Za-z0-9_]*=\$\(", code):
            print(f"{path}:{no}: E3 'local x=$(...)' maschera gli errori: {line.strip()}")
            problems += 1

print(f"\n{problems} problemi" if problems else "nessun problema")
sys.exit(1 if problems else 0)
