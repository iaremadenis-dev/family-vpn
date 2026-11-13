#!/usr/bin/env python3
"""Generate exactly two public, SHA-pinned Family VPN entrypoints.

Existing signed installers remain the implementation. This script only unifies
the public entrypoints; it never contacts a VPS or changes production state.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
RELEASES = ROOT / "releases"
TEMPLATES = ROOT / "scripts" / "templates"

def fail(message: str) -> None:
    raise SystemExit("build-two-installers: " + message)

def read_values(file: Path) -> dict[str, str]:
    if not file.is_file():
        fail(f"missing {file}")
    values: dict[str, str] = {}
    for line in file.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def checked_boot(name: str, expected: str, prefix: str) -> str:
    if not re.fullmatch(prefix + r"[0-9a-f]{12}\.sh", name):
        fail(f"unexpected bootstrap filename: {name!r}")
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        fail(f"invalid SHA256 for {name}")
    path = DIST / name
    if not path.is_file() or sha(path) != expected:
        fail(f"bootstrap missing or SHA256 mismatch: {name}")
    return name

def main() -> None:
    public_url = os.environ.get("FAMILY_VPN_PUBLIC_URL", "https://62.133.60.25").rstrip("/")
    url = urlsplit(public_url)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.path or url.query or url.fragment:
        fail("FAMILY_VPN_PUBLIC_URL must be a bare HTTPS origin")
    if not re.fullmatch(r"[a-zA-Z0-9.:-]+", url.netloc):
        fail("invalid HTTPS origin")

    install = read_values(DIST / "IMAGE-INSTALL.txt")
    update = read_values(DIST / "PANEL-UPDATE.txt")
    install_name = checked_boot(
        install.get("PANEL_INSTALL_BOOT", ""),
        install.get("PANEL_INSTALL_BOOT_SHA256", ""),
        r"panel-install-boot-",
    )
    update_name = checked_boot(
        update.get("PANEL_UPDATE_BOOT", ""),
        update.get("PANEL_UPDATE_BOOT_SHA256", ""),
        r"panel-update-boot-",
    )

    agent_checksum = ""
    for line in (RELEASES / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "bootstrap.sh":
            agent_checksum = parts[0]
            break
    if not re.fullmatch(r"[0-9a-f]{64}", agent_checksum):
        fail("missing agent bootstrap checksum")
    if sha(RELEASES / "bootstrap.sh") != agent_checksum:
        fail("agent bootstrap SHA256 mismatch")

    replacements = {
        "__PUBLIC_URL__": public_url,
        "__INSTALL_BOOT__": install_name,
        "__INSTALL_SHA__": install["PANEL_INSTALL_BOOT_SHA256"],
        "__UPDATE_BOOT__": update_name,
        "__UPDATE_SHA__": update["PANEL_UPDATE_BOOT_SHA256"],
        "__WIREGUARD_SHA__": agent_checksum,
    }
    DIST.mkdir(exist_ok=True)
    for kind in ("panel", "wireguard"):
        template = (TEMPLATES / f"{kind}.sh.in").read_text(encoding="utf-8")
        for old, new in replacements.items():
            template = template.replace(old, new)
        if re.search(r"__[A-Z_]+__", template):
            fail(f"unresolved placeholder in {kind}.sh")
        out = DIST / f"{kind}.sh"
        out.write_text(template, encoding="utf-8")
        out.chmod(0o755)
        subprocess.run(["bash", "-n", str(out)], check=True)
        subprocess.run(["node", str(ROOT / "scripts" / "sign-release-file.mjs"), str(out)], check=True)
        digest = sha(out)
        (DIST / f"{kind}.sh.sha256").write_text(f"{digest}  {kind}.sh\n", encoding="utf-8")
        print(f"{kind}.sh SHA256={digest}")

    print("TWO_INSTALLERS_OK")

if __name__ == "__main__":
    main()
