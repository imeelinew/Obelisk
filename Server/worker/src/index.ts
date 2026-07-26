// Obelisk sync API on Cloudflare Workers + D1. Single private deployment;
// identity is one bearer access key held by the owner's devices.

import { handleChanges } from "./changes";
import { handleHistoryReconcile } from "./history";
import { handlePush, jsonError } from "./push";

export interface Env {
  DB: D1Database;
  SYNC_ACCESS_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;

    if (route === "GET /healthz") {
      return Response.json({ status: "ok" });
    }

    if (!(await isAuthorized(request, env))) {
      return jsonError(401, "invalid access key");
    }

    try {
      switch (route) {
        case "POST /v1/push":
          return await handlePush(request, env.DB);
        case "GET /v1/changes":
          return await handleChanges(request, env.DB);
        case "PUT /v1/browser-history":
          return await handleHistoryReconcile(request, env.DB);
        default:
          return jsonError(404, "not found");
      }
    } catch (error) {
      console.error("request failed", route, error);
      return jsonError(500, "internal error");
    }
  },
} satisfies ExportedHandler<Env>;

async function isAuthorized(request: Request, env: Env): Promise<boolean> {
  const key = env.SYNC_ACCESS_KEY;
  if (typeof key !== "string" || key.length < 16) {
    // Refuse to run without a configured secret rather than allowing access.
    return false;
  }
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) {
    return false;
  }
  const presented = header.slice("Bearer ".length);
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(presented)),
    crypto.subtle.digest("SHA-256", encoder.encode(key)),
  ]);
  return timingSafeEqual(new Uint8Array(a), new Uint8Array(b));
}

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) {
    difference |= a[index] ^ b[index];
  }
  return difference === 0;
}
