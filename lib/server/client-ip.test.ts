import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { clientAddressFromHeaders } from "@/lib/server/client-ip";

describe("clientAddressFromHeaders", () => {
  test("ignores forwarded headers without trust proxy", () => {
    delete process.env.FAMILY_VPN_TRUST_PROXY;
    const headers = new Headers({
      "x-forwarded-for": "203.0.113.10",
      "x-real-ip": "203.0.113.10",
    });
    assert.equal(clientAddressFromHeaders(headers), null);
  });

  test("prefers X-Real-IP and uses rightmost XFF hop when trusted", () => {
    process.env.FAMILY_VPN_TRUST_PROXY = "1";
    assert.equal(
      clientAddressFromHeaders(new Headers({ "x-real-ip": "198.51.100.2" })),
      "198.51.100.2",
    );
    assert.equal(
      clientAddressFromHeaders(
        new Headers({ "x-forwarded-for": "203.0.113.9, 198.51.100.2" }),
      ),
      "198.51.100.2",
    );
    delete process.env.FAMILY_VPN_TRUST_PROXY;
  });
});
