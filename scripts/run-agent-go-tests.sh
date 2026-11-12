#!/bin/bash
# Runs agent Go tests and a Linux amd64 build check in an isolated toolchain if needed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/agent"

if ! command -v go >/dev/null 2>&1; then
  echo "go is required (see agent/go.mod: go 1.22)" >&2
  exit 1
fi

go version
# Never inherit a cross-compile target into `go test` (breaks running the test binary).
unset GOOS GOARCH
export CGO_ENABLED=0
go test -count=1 ./...
OUT=$(mktemp "${TMPDIR:-/tmp}/family-vpn-agent-linux-amd64-XXXXXX")
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$OUT" .
rm -f "$OUT"
echo "agent go tests and linux/amd64 build ok"
