// SPDX-License-Identifier: Apache-2.0

// Response headers for every page: shared by the build step that writes
// _headers (scripts/csp-headers.mjs) and by the Worker's 404 response
// (src/server.ts). Pure functions; no imports, so Node runs this file as is.

export const SECURITY_HEADERS: Record<string, string> = {
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Frame-Options": "DENY",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), interest-cohort=()",
};

/** Hashed assets never change under the same name. */
export const IMMUTABLE = "public, max-age=31536000, immutable";

const NUL = String.fromCharCode(0);
const REPLACEMENT = String.fromCharCode(0xfffd);

/**
 * Inline <script> bodies of a page (scripts with a src are covered by
 * 'self'), as the browser hashes them: the HTML parser turns CR LF and CR
 * into LF, and NUL inside script data into U+FFFD. TanStack's hydration data
 * contains a NUL.
 */
export function inlineScripts(html: string): string[] {
  const out: string[] = [];
  for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (/\ssrc\s*=/i.test(m[1])) continue;
    if (m[2].length > 0) out.push(m[2].replace(/\r\n?/g, "\n").split(NUL).join(REPLACEMENT));
  }
  return out;
}

/** The page's Content-Security-Policy: scripts only from the site or by hash; no inline script without one. */
export function contentSecurityPolicy(scriptHashes: Iterable<string>): string {
  const hashes = [...new Set(scriptHashes)].sort().map((h) => `'sha256-${h}'`);
  return [
    "default-src 'self'",
    `script-src 'self'${hashes.length ? ` ${hashes.join(" ")}` : ""}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'none'",
  ].join("; ");
}
