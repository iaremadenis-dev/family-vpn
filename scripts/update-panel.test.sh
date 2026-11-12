#!/bin/bash
# Simulates an image-based panel update on a production-like layout copy.
# Does not contact a VPS. Uses fake docker/curl and a temp filesystem root.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash -n "$ROOT/panel/update-panel.sh"
bash -n "$ROOT/scripts/build-panel-update.sh"

DIGEST_OLD=sha256:b5a719f0148019784f4eb544289fb2acb4174cf1c8b76e70f18f73ac37b09479
DIGEST_NEW=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# --- Fake production layout (DE-01 style: ComposeDir still under /tmp) ---
fake_root="$work/root"
mkdir -p \
  "$fake_root/tmp/family-vpn-install/panel" \
  "$fake_root/tmp/family-vpn-install/releases" \
  "$fake_root/var/lib/family-vpn/panel" \
  "$fake_root/var/lib/family-vpn/backups" \
  "$fake_root/etc/family-vpn" \
  "$fake_root/opt/family-vpn"

# Seed compose files as installed from image package.
cp "$ROOT/panel/docker-compose.yml" "$fake_root/tmp/family-vpn-install/panel/"
cp "$ROOT/panel/docker-compose.image.yml" "$fake_root/tmp/family-vpn-install/panel/"
printf 'services:\n  panel:\n    image: %s\n' "$DIGEST_OLD" \
  >"$fake_root/tmp/family-vpn-install/panel/docker-compose.image.yml"

# Production-like SQLite with admin + schema 3 (pre-0.5 panel).
PANEL_DATA="$fake_root/var/lib/family-vpn/panel"
export PANEL_DATA
python3 - <<'PY'
import os, sqlite3, pathlib
p = pathlib.Path(os.environ["PANEL_DATA"])
p.mkdir(parents=True, exist_ok=True)
db = sqlite3.connect(str(p / "family-vpn.sqlite"))
db.executescript("""
CREATE TABLE admin (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE servers (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  endpoint TEXT NOT NULL
);
CREATE TABLE agents (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  server_id TEXT
);
INSERT INTO admin VALUES (1, 'Admin', 'hash', '2026-01-01T00:00:00Z');
INSERT INTO sessions VALUES ('tok', '2099-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
INSERT INTO servers VALUES ('srv1', 'NL-01', '1.2.3.4:51820');
INSERT INTO agents VALUES ('ag1', 'NL-01', 'srv1');
PRAGMA user_version = 3;
""")
db.commit()
db.close()
(p / "master.key").write_bytes(b"x" * 32)
print("seeded")
PY

cat >"$fake_root/etc/family-vpn/panel.env" <<EOF
FAMILY_VPN_PUBLIC_URL=https://203.0.113.10
FAMILY_VPN_PANEL_DIR=$fake_root/var/lib/family-vpn/panel
EOF
printf 'COMPOSE_PROJECT_DIR=%s/tmp/family-vpn-install/panel\n' "$fake_root" \
  >"$fake_root/etc/family-vpn/renew.env"
printf 'COMPOSE_FILE=%s/tmp/family-vpn-install/panel/docker-compose.yml\n' "$fake_root" \
  >>"$fake_root/etc/family-vpn/renew.env"
install -m 600 /dev/null "$fake_root/etc/family-vpn/Caddyfile"
printf 'example caddy\n' >"$fake_root/etc/family-vpn/Caddyfile"

# --- Update bundle staged as if extracted from signed archive ---
bundle="$work/bundle"
mkdir -p "$bundle/panel" "$bundle/releases"
cp "$ROOT/panel/update-panel.sh" "$bundle/panel/"
cp "$ROOT/panel/install-panel.sh" "$bundle/panel/"
cp "$ROOT/panel/docker-compose.yml" "$bundle/panel/"
cp "$ROOT/panel/docker-compose.image.yml" "$bundle/panel/"
for name in Caddyfile.bootstrap Caddyfile.https renew-cert.sh backup-panel.sh \
  backup-wg.sh restore-panel.sh restore-wg.sh push-restore.sh \
  archive-tool.mjs archive_host.py s3_store.py backup.env.example \
  certbot-requirements.txt; do
  [ -f "$ROOT/panel/$name" ] && cp "$ROOT/panel/$name" "$bundle/panel/" || true
done
chmod 755 "$bundle/panel/"*.sh
cat >"$bundle/BUNDLE-INFO.txt" <<EOF
source_commit=deadbeefdeadbeef
bundle=panel-update
image_ref=$DIGEST_NEW
image_digest=$DIGEST_NEW
schema_min=1
schema_max=4
rollback_hint=panel-d587d590518d
EOF
printf '%s\n' "$DIGEST_OLD" >"$bundle/ROLLBACK-IMAGE.txt"
# Tiny fake image tar (docker load mocked).
: >"$bundle/family-vpn-panel-image.tar"
printf '%s  family-vpn-panel-image.tar\n' "$(sha256sum "$bundle/family-vpn-panel-image.tar" | awk '{print $1}')" \
  >"$bundle/family-vpn-panel-image.tar.sha256"

# --- Fake docker / curl / id ---
bin="$work/bin"
mkdir -p "$bin"
cat >"$bin/docker" <<EOF
#!/bin/bash
set -euo pipefail
STATE="$work/docker-state"
mkdir -p "\$STATE"
cmd=\${1:-}
case "\$cmd" in
  inspect)
    name=\${2:-}
    format=""
    prev=""
    for arg in "\$@"; do
      if [ "\$prev" = "--format" ]; then format=\$arg; fi
      prev=\$arg
    done
    if [ "\$name" = "family-vpn-panel" ]; then
      case "\$format" in
        *working_dir*)
          if [ -f "\$STATE/compose_dir" ]; then cat "\$STATE/compose_dir"
          else printf '%s\n' "$fake_root/tmp/family-vpn-install/panel"
          fi
          ;;
        *'.Image'*|*'{{.Image}}'*)
          if [ -f "\$STATE/running_image" ]; then cat "\$STATE/running_image"
          else printf '%s\n' "$DIGEST_OLD"
          fi
          ;;
        *) exit 0 ;;
      esac
      exit 0
    fi
    exit 1
    ;;
  image)
    if [ "\${2:-}" = "inspect" ]; then
      ref=""
      format=""
      prev=""
      for arg in "\$@"; do
        case "\$arg" in
          --format) prev=format; continue ;;
        esac
        if [ "\$prev" = "format" ]; then format=\$arg; prev=""; continue; fi
        case "\$arg" in image|inspect|--format) ;; *) ref=\$arg ;; esac
      done
      if [ "\$ref" = "$DIGEST_OLD" ]; then
        case "\$format" in
          *'.Id'*|*'{{.Id}}'*) printf '%s\n' "$DIGEST_OLD" ;;
          *) exit 0 ;;
        esac
        exit 0
      fi
      if [ -f "\$STATE/loaded" ] && [ "\$ref" = "$DIGEST_NEW" ]; then
        case "\$format" in
          *'.Id'*|*'{{.Id}}'*) printf '%s\n' "$DIGEST_NEW" ;;
          *) exit 0 ;;
        esac
        exit 0
      fi
      exit 1
    fi
    exit 1
    ;;
  load)
    touch "\$STATE/loaded"
    exit 0
    ;;
  ps)
    printf '%s\n' "family-vpn-panel"
    printf '%s\n' "family-vpn-caddy"
    exit 0
    ;;
  compose)
    # Record last compose invocation and pretend success.
    printf '%s\n' "\$*" >>"\$STATE/compose.log"
    # After up, relocate working dir to permanent path if present.
    if printf '%s' "\$*" | grep -q 'up'; then
      if [ -d "$fake_root/opt/family-vpn/install/panel" ]; then
        printf '%s\n' "$fake_root/opt/family-vpn/install/panel" >"\$STATE/compose_dir"
      fi
      if [ -n "\${FAMILY_VPN_PANEL_IMAGE:-}" ]; then
        printf '%s\n' "\$FAMILY_VPN_PANEL_IMAGE" >"\$STATE/running_image"
      fi
    fi
    exit 0
    ;;
  *)
    printf 'unexpected docker: %s\n' "\$*" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "$bin/docker"

cat >"$bin/curl" <<'EOF'
#!/bin/bash
# Always report healthy login page.
while [ $# -gt 0 ]; do
  case "$1" in
    -w) shift 2 ;;
    -o) shift 2 ;;
    --max-time) shift 2 ;;
    -sS|-s) shift ;;
    *) shift ;;
  esac
done
# When -w '%{http_code}' is used, docker-style: body discarded, code on stdout.
printf '200'
EOF
chmod 755 "$bin/curl"

# Pretend root.
cat >"$bin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
EOF
chmod 755 "$bin/id"

# Prefer system python/sha256sum/etc.
for tool in bash grep awk sed cat sha256sum dirname uname date chmod cp mkdir install mktemp tr sleep python3 python openssl find tee head; do
  src=$(command -v "$tool" || true)
  if [ -n "$src" ] && [ ! -e "$bin/$tool" ]; then
    printf '#!/bin/bash\nexec %q "$@"\n' "$src" >"$bin/$tool"
    chmod 755 "$bin/$tool"
  fi
done

export PATH="$bin:$PATH"
export FAMILY_VPN_PANEL_DIR="$fake_root/var/lib/family-vpn/panel"
export FAMILY_VPN_INSTALL_ROOT="$fake_root/opt/family-vpn/install"
# Patch updater paths via env + wrapping: update-panel uses absolute /etc and /var.
# Run a patched copy that remaps absolute paths to fake_root.
upd="$work/update-panel.sh"
sed \
  -e "s#/var/lib/family-vpn#$fake_root/var/lib/family-vpn#g" \
  -e "s#/etc/family-vpn#$fake_root/etc/family-vpn#g" \
  -e "s#/opt/family-vpn#$fake_root/opt/family-vpn#g" \
  -e "s#/tmp/family-vpn-install#$fake_root/tmp/family-vpn-install#g" \
  "$bundle/panel/update-panel.sh" >"$upd"
# Point BUNDLE_DIR at our bundle: script uses dirname/.. from SCRIPT_PATH.
mkdir -p "$bundle/panel"
cp "$upd" "$bundle/panel/update-panel.sh"
chmod 755 "$bundle/panel/update-panel.sh"

# Also patch ENV_FILE content PUBLIC_URL already set.

echo "== dry-run =="
bash "$bundle/panel/update-panel.sh" --dry-run | tee "$work/dry.log"
grep -q 'DRY_RUN ok' "$work/dry.log"

echo "== refuse empty db =="
empty="$work/empty"
mkdir -p "$empty"
: >"$empty/family-vpn.sqlite"
cp "$fake_root/var/lib/family-vpn/panel/master.key" "$empty/master.key"
if FAMILY_VPN_PANEL_DIR="$empty" bash "$bundle/panel/update-panel.sh" --dry-run; then
  echo "empty DB was accepted" >&2
  exit 1
fi

echo "== full update (tmp -> opt) =="
DB_PATH="$fake_root/var/lib/family-vpn/panel/family-vpn.sqlite"
ADMIN_BEFORE=$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select display_name from admin').fetchone()[0])" "$DB_PATH")
bash "$bundle/panel/update-panel.sh" | tee "$work/upd.log"
grep -q 'UPDATE_OK' "$work/upd.log"
grep -q 'relocating Compose project' "$work/upd.log"

# Permanent install root populated.
test -f "$fake_root/opt/family-vpn/install/panel/docker-compose.yml"
test -f "$fake_root/opt/family-vpn/install/panel/update-panel.sh"
test -f "$fake_root/opt/family-vpn/install/BUNDLE-INFO.txt"
grep -q "$DIGEST_NEW" "$fake_root/opt/family-vpn/install/BUNDLE-INFO.txt"

# Data preserved.
ADMIN_AFTER=$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select display_name from admin').fetchone()[0])" "$DB_PATH")
[ "$ADMIN_BEFORE" = "$ADMIN_AFTER" ]
test -s "$fake_root/var/lib/family-vpn/panel/master.key"
SRV=$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select name from servers').fetchone()[0])" "$DB_PATH")
[ "$SRV" = "NL-01" ]

# Backup exists and is restorable.
test -f "$fake_root/etc/family-vpn/panel-last-backup.path"
BAK=$(cat "$fake_root/etc/family-vpn/panel-last-backup.path")
test -s "$BAK/family-vpn.sqlite"
test -s "$BAK/master.key"
python3 -c "import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); assert db.execute('select id from admin').fetchone()" "$BAK/family-vpn.sqlite"

# Prev image recorded for rollback (d587 digest).
test -f "$fake_root/etc/family-vpn/panel-image.prev"
grep -q "$DIGEST_OLD" "$fake_root/etc/family-vpn/panel-image.prev"
grep -q "$DIGEST_NEW" "$fake_root/etc/family-vpn/panel-image.current"

# renew.env relocated.
grep -q "$fake_root/opt/family-vpn/install/panel" "$fake_root/etc/family-vpn/renew.env"

# Compose used --no-build --pull never.
grep -q -- '--no-build' "$work/docker-state/compose.log"
grep -q -- '--pull never' "$work/docker-state/compose.log"

echo "== rollback image =="
bash "$bundle/panel/update-panel.sh" --rollback | tee "$work/rb.log"
grep -q 'ROLLBACK_OK' "$work/rb.log"
grep -q "$DIGEST_OLD" "$work/docker-state/running_image"

echo "== check =="
bash "$bundle/panel/update-panel.sh" --check | tee "$work/ck.log"
grep -q 'CHECK_OK' "$work/ck.log"

echo "update-panel simulator ok"
