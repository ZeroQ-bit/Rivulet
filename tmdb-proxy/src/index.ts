const TMDB_BASE = "https://api.themoviedb.org/3";
const TTL_SECONDS = 60 * 60 * 24 * 7; // 7 days
const LIST_TTL_SECONDS = 60 * 60; // 1 hour for popular/trending lists
const LIST_SECTIONS = new Set([
  "popular",
  "now_playing",
  "upcoming",
  "top_rated",
  "airing_today",
  "on_the_air",
]);

export interface Env {
  TMDB_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (request.method === "OPTIONS") {
      return addCors(new Response(null, { status: 204 }));
    }

    if (request.method !== "GET") {
      return addCors(new Response("Method Not Allowed", { status: 405 }));
    }

    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean); // e.g. ["tmdb","keywords","123"]
    if (parts[0] !== "tmdb" || parts.length < 2) {
      return addCors(new Response("Not Found", { status: 404 }));
    }

    const kind = parts[1];
    const language = url.searchParams.get("language");

    // Routes that don't need an id segment
    if (kind === "list" || kind === "discover") {
      if (parts.length < 3) {
        return addCors(new Response("Not Found", { status: 404 }));
      }

      if (kind === "list") {
        const section = parts[2];
        const type = url.searchParams.get("type") === "tv" ? "tv" : "movie";
        if (!LIST_SECTIONS.has(section)) {
          return addCors(new Response("Unknown list section", { status: 404 }));
        }
        const page = url.searchParams.get("page") ?? "1";
        const upstreamUrl = new URL(`${TMDB_BASE}/${type}/${section}`);
        upstreamUrl.searchParams.set("api_key", env.TMDB_API_KEY);
        upstreamUrl.searchParams.set("page", page);
        if (language) upstreamUrl.searchParams.set("language", language);
        return proxyAndCache(upstreamUrl, request.url, LIST_TTL_SECONDS, ctx);
      }

      if (kind === "discover") {
        const type = parts[2] === "tv" ? "tv" : "movie";
        const upstreamUrl = new URL(`${TMDB_BASE}/discover/${type}`);
        upstreamUrl.searchParams.set("api_key", env.TMDB_API_KEY);
        // Pass through the filter params the iOS client sends.
        const forwardParams = ["with_genres", "with_keywords", "sort_by", "page", "include_adult"];
        for (const name of forwardParams) {
          const v = url.searchParams.get(name);
          if (v) upstreamUrl.searchParams.set(name, v);
        }
        if (language) upstreamUrl.searchParams.set("language", language);
        return proxyAndCache(upstreamUrl, request.url, LIST_TTL_SECONDS, ctx);
      }
    }

    // Per-item endpoints: /tmdb/{kind}/{id}
    if (parts.length < 3) {
      return addCors(new Response("Not Found", { status: 404 }));
    }

    const tmdbId = parts[2];
    const type = url.searchParams.get("type") === "tv" ? "tv" : "movie";

    let upstreamPath: string;
    let appendToResponse: string | null = null;
    switch (kind) {
      case "keywords":
        upstreamPath = `${type}/${tmdbId}/keywords`;
        break;
      case "credits":
        upstreamPath = `${type}/${tmdbId}/credits`;
        break;
      case "details":
        upstreamPath = `${type}/${tmdbId}`;
        // Flatten credits (cast/crew) into the details response so clients
        // can consume a single detail shape with `cast` at the top level.
        appendToResponse = "credits";
        break;
      case "images":
        upstreamPath = `${type}/${tmdbId}/images`;
        break;
      case "find": {
        const externalSource = url.searchParams.get("source") || "tvdb_id";
        upstreamPath = `find/${tmdbId}`;
        url.searchParams.set("_external_source", externalSource);
        break;
      }
      default:
        return addCors(new Response("Not Found", { status: 404 }));
    }

    // Build upstream URL
    const upstreamUrl = new URL(`${TMDB_BASE}/${upstreamPath}`);
    upstreamUrl.searchParams.set("api_key", env.TMDB_API_KEY);
    if (language) upstreamUrl.searchParams.set("language", language);
    if (appendToResponse) upstreamUrl.searchParams.set("append_to_response", appendToResponse);
    const externalSource = url.searchParams.get("_external_source");
    if (externalSource) upstreamUrl.searchParams.set("external_source", externalSource);

    // Details route flattens credits; other routes pass through.
    const transform = kind === "details" ? flattenDetailsCredits : null;
    return proxyAndCache(upstreamUrl, request.url, TTL_SECONDS, ctx, transform);
  },
};

async function proxyAndCache(
  upstreamUrl: URL,
  originalRequestUrl: string,
  ttlSeconds: number,
  ctx: ExecutionContext,
  transform?: ((body: unknown) => unknown) | null,
): Promise<Response> {
  const cacheKey = new Request(originalRequestUrl, { method: "GET" });
  const cache = caches.default;
  const cached = await cache.match(cacheKey);
  if (cached) {
    return addCors(cached);
  }

  let upstreamResp: Response;
  try {
    upstreamResp = await fetch(upstreamUrl.toString(), {
      headers: { Accept: "application/json" },
    });
  } catch (err) {
    return addCors(new Response("Upstream error", { status: 502 }));
  }

  let bodyText: string;
  if (transform && upstreamResp.ok) {
    try {
      const parsed = await upstreamResp.json();
      bodyText = JSON.stringify(transform(parsed));
    } catch {
      // Fall back to raw passthrough on parse failure
      bodyText = await upstreamResp.text();
    }
  } else {
    bodyText = await upstreamResp.text();
  }

  const headers = cleanHeaders(upstreamResp.headers);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set(
    "Cache-Control",
    `public, max-age=${ttlSeconds}, s-maxage=${ttlSeconds}`,
  );

  const resp = new Response(bodyText, {
    status: upstreamResp.status,
    headers,
  });

  ctx.waitUntil(cache.put(cacheKey, resp.clone()));
  return addCors(resp);
}

/**
 * TMDB's details endpoint with `append_to_response=credits` nests cast under
 * `credits.cast`. Flatten it so iOS can decode `cast` at the top level.
 */
function flattenDetailsCredits(body: unknown): unknown {
  if (!body || typeof body !== "object") return body;
  const obj = body as Record<string, unknown>;
  const credits = obj.credits as Record<string, unknown> | undefined;
  if (credits && Array.isArray(credits.cast)) {
    obj.cast = (credits.cast as unknown[]).slice(0, 20);
  } else if (!Array.isArray(obj.cast)) {
    obj.cast = [];
  }
  // Drop the nested credits object to keep response smaller
  delete obj.credits;
  return obj;
}

function cleanHeaders(headers: Headers): Headers {
  const h = new Headers(headers);
  h.delete("set-cookie");
  return h;
}

function addCors(resp: Response): Response {
  const h = new Headers(resp.headers);
  h.set("Access-Control-Allow-Origin", "*");
  h.set("Access-Control-Allow-Methods", "GET, OPTIONS");
  h.set("Access-Control-Allow-Headers", "Content-Type");
  return new Response(resp.body, { status: resp.status, headers: h });
}
