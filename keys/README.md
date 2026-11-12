# Release signing keys

`release-signing.pub` is the trusted public key for Family VPN install artifacts.
Its SHA-256 fingerprint is pinned in generated `bootstrap.sh` / install one-liners
independently of the downloaded tarball contents.

## Production

1. Generate a key pair offline (do not commit the private key):

```bash
openssl genpkey -algorithm Ed25519 -out release-signing.pem
openssl pkey -in release-signing.pem -pubout -out release-signing.pub
```

2. Replace `keys/release-signing.pub` in the private source repo.
3. Store `release-signing.pem` only in the operator secret store / CI secret
   `FAMILY_VPN_RELEASE_SIGNING_KEY` (PEM contents). Never put it in Docker images
   or public release archives.
4. Rebuild releases with `scripts/build-release.sh` so `install.sh.sig` is produced.

## Verify on a VPS

```bash
echo '<fingerprint>  release-signing.pub' | sha256sum -c -
openssl pkeyutl -verify -pubin -inkey release-signing.pub -rawin -in install.sh -sigfile install.sh.sig
```

The development public key shipped in this directory is for local/CI signing only.
Replace it before trusting production installs.
