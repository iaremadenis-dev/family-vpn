import assert from "node:assert/strict";
import { describe, test } from "node:test";
import {
  allocateVpnIp,
  buildClientConfig,
  collectUsedIps,
  generateWireGuardKeyPair,
} from "@/lib/server/wireguard";

describe("wireguard helpers", () => {
  test("generates distinct curve25519 key pairs", () => {
    const first = generateWireGuardKeyPair();
    const second = generateWireGuardKeyPair();
    assert.notEqual(first.privateKey, second.privateKey);
    assert.notEqual(first.publicKey, second.publicKey);
    assert.equal(Buffer.from(first.privateKey, "base64").length, 32);
    assert.equal(Buffer.from(first.publicKey, "base64").length, 32);
  });

  test("allocates next free host and never reuses taken ips", () => {
    const first = allocateVpnIp("10.200.0.0/24", ["10.200.0.1", "10.200.0.2"]);
    assert.equal(first, "10.200.0.3");
    const second = allocateVpnIp("10.200.0.0/24", ["10.200.0.1", "10.200.0.2", first]);
    assert.equal(second, "10.200.0.4");
  });

  test("skips ips reported by unmanaged peers", () => {
    const used = collectUsedIps(["10.200.0.2/32", "10.200.0.8/32, 10.200.0.9/32"]);
    const ip = allocateVpnIp("10.200.0.0/24", ["10.200.0.1", ...used]);
    assert.equal(ip, "10.200.0.3");
  });

  test("builds client conf without embedding server private key", () => {
    const keys = generateWireGuardKeyPair();
    const conf = buildClientConfig({
      privateKey: keys.privateKey,
      address: "10.200.0.5",
      serverPublicKey: `${"B".repeat(43)}=`,
      endpoint: "203.0.113.10",
      listenPort: 51820,
    });
    assert.match(conf, /\[Interface\]/);
    assert.match(conf, /\[Peer\]/);
    assert.match(conf, /Endpoint = 203\.0\.113\.10:51820/);
    assert.doesNotMatch(conf, /SERVERPRIVATE/i);
  });
});
