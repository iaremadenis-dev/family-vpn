/**
 * Resolve the client IP for rate limiting when behind a trusted reverse proxy.
 *
 * When FAMILY_VPN_TRUST_PROXY=1, prefer X-Real-IP (set by Caddy to the TCP peer)
 * over X-Forwarded-For. If only XFF is present, use the rightmost hop — the value
 * appended by the immediate trusted proxy — so a client-supplied leftmost spoof
 * does not bypass per-IP limits. When trust proxy is off, ignore forwarded headers.
 */
export function clientAddressFromHeaders(headerList: Headers): string | null {
  if (process.env.FAMILY_VPN_TRUST_PROXY !== "1") return null;

  const realIp = headerList.get("x-real-ip")?.trim();
  if (realIp && isSingleIpToken(realIp)) return realIp.slice(0, 200);

  const forwarded = headerList.get("x-forwarded-for");
  if (!forwarded) return null;
  const parts = forwarded
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length === 0) return null;
  const hop = parts[parts.length - 1]!;
  if (!isSingleIpToken(hop)) return null;
  return hop.slice(0, 200);
}

function isSingleIpToken(value: string): boolean {
  if (!value || value.length > 200) return false;
  if (/[\s/]/.test(value)) return false;
  // Accept IPv4 or IPv6 textual forms without parsing every edge case.
  return /^[0-9a-fA-F:.]+$/.test(value);
}
