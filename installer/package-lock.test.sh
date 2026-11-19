#!/bin/bash
# Hold a frontend lock in a temporary copy of the dpkg database on the CI runner.
set -euo pipefail
[ "${FAMILY_VPN_TEST_DPKG_LOCK:-}" = 1 ] || exit 0
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/archives/partial"
cp /var/lib/dpkg/status "$fixture/status"
sed '/^# Installer entry point\.$/,$d' "$root/installer/install.sh" >"$fixture/functions.sh"
python3 - "$fixture" <<'PY'
import fcntl
import os
from pathlib import Path
import subprocess
import sys

fixture = Path(sys.argv[1])
options = ["-o", f"Dir::State::status={fixture}/status",
           "-o", f"Dir::Cache::archives={fixture}/archives",
           "-o", "Dir::Cache::pkgcache=", "-o", "Dir::Cache::srcpkgcache=",
           "--no-upgrade", "dpkg"]
environment = dict(os.environ, LC_ALL="C", DEBIAN_FRONTEND="noninteractive")
with (fixture / "lock-frontend").open("a") as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX)
    old = subprocess.run(["apt-get", "-o", "DPkg::Lock::Timeout=0", "install", "-y", *options],
                         env=environment, capture_output=True, text=True, timeout=20)
    assert old.returncode != 0 and str(fixture / "lock-frontend") in old.stderr, old.stderr
    with subprocess.Popen(["bash", "-c", 'source "$1"; shift; install_packages "$@"',
                           "lock-test", str(fixture / "functions.sh"), *options], env=environment) as install:
        try:
            install.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        else:
            raise RuntimeError("installer returned while another process held the dpkg lock")
        fcntl.lockf(lock, fcntl.LOCK_UN)
        if install.wait(timeout=40) != 0:
            raise RuntimeError("installer failed after release of the dpkg lock")
print("installer waited for the dpkg frontend lock and completed after release")
PY
