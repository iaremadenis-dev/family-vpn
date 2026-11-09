#!/usr/bin/env python3
"""Host-side snapshot and verify when Node is not installed."""

import hashlib
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_MAX = 3
PANEL_KIND = "family-vpn-panel"
WG_KIND = "family-vpn-wireguard"


def die(token, detail=""):
    print(f"{token} {detail}".strip(), file=sys.stderr)
    raise SystemExit(1)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(source, destination):
    src = Path(source)
    dest = Path(destination)
    if not src.is_file():
        die("SQLITE_MISSING")
    if dest.exists():
        die("SNAPSHOT_EXISTS")
    dest.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(src)
    connection.execute("PRAGMA busy_timeout = 5000")
    quoted = str(dest).replace("\\", "/").replace("'", "''")
    connection.execute(f"VACUUM INTO '{quoted}'")
    connection.close()


def file_meta(path):
    return {"sha256": sha256(path), "bytes": path.stat().st_size}


def panel_manifest(directory):
    root = Path(directory)
    sqlite = root / "family-vpn.sqlite"
    if not sqlite.is_file():
        die("SQLITE_MISSING")
    connection = sqlite3.connect(f"file:{sqlite}?mode=ro", uri=True)
    schema = connection.execute("PRAGMA user_version").fetchone()[0]
    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    admin = connection.execute("SELECT id FROM admin WHERE id = 1").fetchone() if "admin" in tables else None
    servers = connection.execute("SELECT id, endpoint, listen_port FROM servers ORDER BY id").fetchall() if "servers" in tables else []
    agents = connection.execute("SELECT server_id, public_key FROM agents ORDER BY server_id").fetchall() if "agents" in tables else []
    config_count = connection.execute("SELECT COUNT(*) FROM configs").fetchone()[0] if "configs" in tables else 0
    connection.close()
    files = {"family-vpn.sqlite": file_meta(sqlite)}
    for name in ("master.key", "panel.env"):
        file = root / name
        if file.is_file():
            files[name] = file_meta(file)
    body = {
        "kind": PANEL_KIND,
        "manifest_version": 1,
        "schema_version": schema,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "admin_present": bool(admin),
        "config_count": config_count,
        "servers": [{"id": row[0], "endpoint": row[1], "listen_port": row[2]} for row in servers],
        "agents": [{"server_id": row[0], "public_key": row[1]} for row in agents],
        "files": files,
    }
    (root / "manifest.json").write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")


def decrypt_config(master, payload):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    import base64

    raw = base64.b64decode(payload)
    if len(raw) < 28:
        raise ValueError("short")
    AESGCM(master).decrypt(raw[:12], raw[28:] + raw[12:28], None)


def assert_files(root, manifest):
    for name, meta in manifest.get("files", {}).items():
        if "/" in name or "\\" in name or name.startswith("."):
            die("BAD_FILE_NAME")
        file = root / name
        if not file.is_file():
            die("FILE_MISSING", name)
        if sha256(file) != meta["sha256"]:
            die("CHECKSUM", name)
        if file.stat().st_size != meta["bytes"]:
            die("SIZE", name)


def panel_verify(directory):
    root = Path(directory)
    manifest_file = root / "manifest.json"
    if not manifest_file.is_file():
        die("MANIFEST_MISSING")
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    if manifest.get("kind") != PANEL_KIND:
        die("KIND_MISMATCH")
    if manifest.get("manifest_version") != 1:
        die("MANIFEST_VERSION")
    if not isinstance(manifest.get("schema_version"), int) or manifest["schema_version"] > SCHEMA_MAX:
        die("SCHEMA_TOO_NEW")
    assert_files(root, manifest)
    sqlite = root / "family-vpn.sqlite"
    connection = sqlite3.connect(f"file:{sqlite}?mode=ro", uri=True)
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        die("INTEGRITY")
    schema = connection.execute("PRAGMA user_version").fetchone()[0]
    if schema != manifest["schema_version"]:
        die("SCHEMA_MISMATCH")
    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    admin = connection.execute("SELECT id FROM admin WHERE id = 1").fetchone() if "admin" in tables else None
    if bool(admin) != bool(manifest.get("admin_present")):
        die("ADMIN_MISMATCH")
    db_ids = [row[0] for row in connection.execute("SELECT id FROM servers ORDER BY id")] if "servers" in tables else []
    manifest_ids = sorted(row["id"] for row in manifest.get("servers", []))
    if sorted(db_ids) != manifest_ids:
        die("SERVER_MISMATCH")
    encrypted = []
    if "configs" in tables:
        encrypted = [
            row[0]
            for row in connection.execute(
                "SELECT client_private_key_enc FROM configs WHERE client_private_key_enc != ''"
            )
        ]
    connection.close()
    key_file = root / "master.key"
    if encrypted:
        if not key_file.is_file():
            die("KEY_MISSING")
        master = key_file.read_bytes()
        if len(master) != 32:
            die("KEY_LENGTH")
        try:
            for payload in encrypted:
                decrypt_config(master, payload)
        except Exception:
            die("KEY_MISMATCH")
        print("KEY_OK")
    else:
        if key_file.is_file() and len(key_file.read_bytes()) != 32:
            die("KEY_LENGTH")
        print("KEY_ABSENT")
    print(f"VERIFY_OK admin={1 if admin else 0} servers={len(db_ids)} schema={schema}")


def wg_manifest(directory):
    root = Path(directory)
    files = {}
    for name in ("wg0.conf", "agent.json", "family-vpn-agent.service"):
        file = root / name
        if file.is_file():
            files[name] = file_meta(file)
    if "wg0.conf" not in files:
        die("WG_CONF_MISSING")
    if (root / "family-vpn.sqlite").exists() or (root / "master.key").exists():
        die("MIXED_ARCHIVE")
    body = {
        "kind": WG_KIND,
        "manifest_version": 1,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "files": files,
    }
    (root / "manifest.json").write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")


def wg_verify(directory):
    root = Path(directory)
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("kind") != WG_KIND:
        die("KIND_MISMATCH")
    if (root / "family-vpn.sqlite").exists() or (root / "master.key").exists():
        die("MIXED_ARCHIVE")
    assert_files(root, manifest)
    if "wg0.conf" not in manifest.get("files", {}):
        die("WG_CONF_MISSING")
    print("WG_VERIFY_OK")


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "snapshot":
        snapshot(argv[2], argv[3])
    elif command == "manifest":
        panel_manifest(argv[2])
    elif command == "verify":
        panel_verify(argv[2])
    elif command == "wg-manifest":
        wg_manifest(argv[2])
    elif command == "wg-verify":
        wg_verify(argv[2])
    else:
        die("ARCHIVE_USAGE")


if __name__ == "__main__":
    main(sys.argv)
