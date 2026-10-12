// SPDX-License-Identifier: Apache-2.0

// The deployed Worker's whole job. Every page is a prerendered static asset,
// and assets are served before the Worker runs, so the Worker only ever sees
// paths that have no page: it answers them with the prerendered 404.html,
// status 404 and the site's security headers.
import { contentSecurityPolicy, inlineScripts, SECURITY_HEADERS } from "../lib/security-headers";

export interface Env {
  ASSETS?: { fetch(input: Request | URL | string): Promise<Response> };
}

async function sha256Base64(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return btoa(String.fromCharCode(...new Uint8Array(digest)));
}

let notFoundPage: Promise<{ html: string; csp: string }> | undefined;

async function loadNotFound(env: Env, url: string) {
  if (!env.ASSETS) throw new Error("ASSETS binding missing");
  const res = await env.ASSETS.fetch(new URL("/404.html", url));
  if (!res.ok) throw new Error(`404.html: ${res.status}`);
  const html = await res.text();
  const hashes = await Promise.all(inlineScripts(html).map(sha256Base64));
  return { html, csp: contentSecurityPolicy(hashes) };
}

export async function notFound(request: Request, env: Env): Promise<Response> {
  notFoundPage ??= loadNotFound(env, request.url).catch((err) => {
    notFoundPage = undefined;
    throw err;
  });
  const { html, csp } = await notFoundPage;
  return new Response(request.method === "HEAD" ? null : html, {
    status: 404,
    headers: { ...SECURITY_HEADERS, "Content-Security-Policy": csp, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}
