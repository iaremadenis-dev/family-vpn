#!/bin/bash
# Checks the minimal image installer. Does not push an image or contact a VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash -n "$ROOT/scripts/build-panel-image.sh"
bash -n "$ROOT/scripts/build-image-install.sh"
bash -n "$ROOT/panel/install-panel.sh"
DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REF="family-vpn-panel@${DIGEST}"
work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

build=$(FAMILY_VPN_BUNDLE_DIR="$work/dist" bash "$ROOT/scripts/build-image-install.sh" \
  --digest "$DIGEST" --image-ref "$REF")
printf '%s\n' "$build" | grep -q "^INSTALL_SHA256="
archive=$(find "$work/dist" -name 'family-vpn-install-*.tar.gz' ! -name '*.sha256')
(cd "$work/dist" && sha256sum -c "$(basename "$archive").sha256")
mkdir -p "$work/unpack"
tar -xzf "$archive" -C "$work/unpack"
pack="$work/unpack/family-vpn-install"
(cd "$pack" && sha256sum -c MANIFEST)
bash -n "$pack/install-family-vpn.sh"
grep -q "$DIGEST" "$pack/install-family-vpn.sh"
if grep -n 'docker ' "$pack/install-family-vpn.sh"; then
  echo "bootstrap calls docker before Docker is installed" >&2
  exit 1
fi
grep -q 'load_verified_image' "$pack/panel/install-panel.sh"
grep -q 'pull_public_compose_images' "$pack/panel/install-panel.sh"
grep -q 'ensure_runtime_images_ready' "$pack/panel/install-panel.sh"
grep -q 'compose config --images' "$pack/panel/install-panel.sh"
grep -q 'caddy:2.10-alpine' "$pack/panel/docker-compose.yml"
grep -q 'docker.io' "$pack/panel/install-panel.sh"
grep -q 'docker-compose-v2' "$pack/panel/install-panel.sh"
grep -q 'docker pull' "$pack/panel/install-panel.sh"
grep -q -- '--no-build' "$pack/panel/install-panel.sh"

cleanbin=$(mktemp -d)
for tool in bash grep awk sed cat sha256sum dirname id uname date chmod; do
  src=$(command -v "$tool" || true)
  if [ -n "$src" ]; then
    printf '#!/bin/bash\nexec %q "$@"\n' "$src" >"$cleanbin/$tool"
    chmod 755 "$cleanbin/$tool"
  fi
done
PATH="$cleanbin" bash "$pack/install-family-vpn.sh" --check | grep -q 'CHECK_OK'
grep -q 'DIGEST_MISMATCH' "$pack/panel/install-panel.sh"
grep -q '/var/lib/family-vpn/panel:/data' "$pack/panel/docker-compose.yml"
grep -q 'caddy:2.10-alpine' "$pack/panel/docker-compose.yml"
grep -q 'FAMILY_VPN_PANEL_IMAGE' "$pack/panel/docker-compose.image.yml"
grep -q 'backup-panel.sh' "$pack/panel/install-panel.sh"
cmp -s "$ROOT/installer/install.sh" "$pack/releases/install.sh"

for forbidden in app lib components Dockerfile package.json .git panel/bootstrap-panel.sh; do
  if [ -e "$pack/$forbidden" ]; then
    printf '%s\n' "install package contains $forbidden" >&2
    exit 1
  fi
done
if find "$pack" -type f \( -name '*.test.ts' -o -name '*.test.sh' -o -name '*.sqlite' -o -name 'master.key' \) | grep -q .; then
  echo "install package contains tests or private data" >&2
  exit 1
fi
if grep -R -n 'gh auth login' "$pack"; then
  echo "install package asks for GitHub login" >&2
  exit 1
fi

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/bin/bash
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  format=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--format" ]; then
      format=$arg
    fi
    prev=$arg
  done
  case "$format" in
    *'.Id'*) printf '%s\n' "${FAKE_IMAGE_ID:-}" ;;
    *RepoDigests*) printf '%s\n' "${FAKE_REPO_DIGEST:-}" ;;
    '') exit 0 ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [ "$1" = "pull" ]; then
  exit 0
fi
printf '%s\n' "unexpected docker: $*" >&2
exit 1
EOF
chmod 755 "$work/bin/docker"

PATH="$work/bin:$PATH" FAKE_IMAGE_ID="$DIGEST" \
  bash "$pack/install-family-vpn.sh" --verify-image | grep -q 'IMAGE_OK'

if PATH="$work/bin:$PATH" FAKE_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  bash "$pack/install-family-vpn.sh" --verify-image; then
  echo "wrong image digest was accepted" >&2
  exit 1
fi

bad=$(mktemp -d)
cp -a "$pack/." "$bad/"
printf '\n' >>"$bad/panel/install-panel.sh"
if bash "$bad/install-family-vpn.sh" --verify-image; then
  echo "tampered installer was accepted" >&2
  exit 1
fi

bash "$ROOT/panel/install-panel.sh" --check
echo "image install package checks ok"
