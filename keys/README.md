# Release signing keys (production)

`release-signing.pub` is the **production** trusted public key for Family VPN
install and panel-update artifacts. Its SHA-256 fingerprint is pinned in
generated `bootstrap.sh` / `panel-update-boot-*.sh` independently of the
downloaded body.

This is **not** a CI unit-test ephemeral key (`scripts/release-signing.test.sh`
generates a throwaway key in a temp dir). The production private key must never
appear in git, Docker images, or release archives.

**Private key rules**

- Never commit `release-signing.pem` / `*.pem` under `keys/`.
- Never put the private key in Docker images, public release archives, or chat.
- Store the PEM only in the operator secret store and GitHub Actions secret
  `FAMILY_VPN_RELEASE_SIGNING_KEY` (full PEM text).
- Run `bash scripts/check-signing-key-hygiene.sh` before publishing.

## Fingerprint of the current committed public key

```bash
sha256sum keys/release-signing.pub
# 1ec270a068a05c1e1af1a29953e92a29c6c518e0b43b90f1a1f417e47d59e259
```

Record this fingerprint offline before trusting the first production install.
If this fingerprint ever changes, treat it as a key rotation and re-pin every
bootstrap one-liner.

## Local signing

```bash
# keys/release-signing.pem must exist locally (gitignored)
export FAMILY_VPN_PUBLIC_URL=https://YOUR_PANEL_IP
bash scripts/build-release.sh
bash scripts/verify-signed-release-local.sh
```

`scripts/build-release.sh` **refuses** to produce a release without a signing key
and always embeds mandatory signature verification in `bootstrap.sh`.

## CI

`agent-release` fails unless `FAMILY_VPN_RELEASE_SIGNING_KEY` is set, then builds
and verifies `install.sh.sig` before uploading artifacts.

## Verify on a VPS (before running install.sh)

```bash
echo '<fingerprint>  release-signing.pub' | sha256sum -c -
# signature bytes are base64url in install.sh.sig — prefer panel bootstrap.sh
# which verifies fingerprint + Ed25519 before exec.
```

Prefer the panel one-liner / `bootstrap.sh`: it downloads `install.sh`,
`install.sh.sig`, and `release-signing.pub`, checks the pinned fingerprint, verifies
the signature, and only then executes the installer.
