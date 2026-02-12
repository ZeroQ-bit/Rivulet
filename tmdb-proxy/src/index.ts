const TMDB_BASE = "https://api.themoviedb.org/3";
const TTL_SECONDS = 60 * 60 * 24 * 7; // 7 days

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
    if (parts[0] !== "tmdb" || parts.length < 3) {
      return addCors(new Response("Not Found", { status: 404 }));
    }

    const kind = parts[1]; // keywords | credits | details
    const tmdbId = parts[2];
    const type = url.searchParams.get("type") === "tv" ? "tv" : "movie";
    const language = url.searchParams.get("language");

    let upstreamPath: string;
    switch (kind) {
      case "keywords":
        upstreamPath = `${type}/${tmdbId}/keywords`;
        break;
      case "credits":
        upstreamPath = `${type}/${tmdbId}/credits`;
        break;
      case "details":
        upstreamPath = `${type}/${tmdbId}`;
        break;
      case "images":
        upstreamPath = `${type}/${tmdbId}/images`;
        break;
      case "find": {
        // /tmdb/find/{external_id}?source=tvdb_id (or imdb_id)
        const externalSource = url.searchParams.get("source") || "tvdb_id";
        upstreamPath = `find/${tmdbId}`;
        // Add external_source to upstream URL below
        url.searchParams.set("_external_source", externalSource);
        break;
      }
      default:
        return addCors(new Response("Not Found", { status: 404 }));
    }

    // Cache lookup
    const cacheKey = new Request(url.toString(), { method: "GET" });
    const cache = caches.default;
    const cached = await cache.match(cacheKey);
    if (cached) {
      return addCors(cached);
    }

    // Build upstream URL
    const upstreamUrl = new URL(`${TMDB_BASE}/${upstreamPath}`);
    upstreamUrl.searchParams.set("api_key", env.TMDB_API_KEY);
    if (language) upstreamUrl.searchParams.set("language", language);
    const externalSource = url.searchParams.get("_external_source");
    if (externalSource) upstreamUrl.searchParams.set("external_source", externalSource);

    let upstreamResp: Response;
    try {
      upstreamResp = await fetch(upstreamUrl.toString(), {
        headers: { Accept: "application/json" },
      });
    } catch (err) {
      return addCors(new Response("Upstream error", { status: 502 }));
    }

    // Pass through status/body, strip set-cookie, and add cache headers
    const resp = new Response(upstreamResp.body, {
      status: upstreamResp.status,
      headers: cleanHeaders(upstreamResp.headers),
    });
    resp.headers.set("Cache-Control", `public, max-age=${TTL_SECONDS}, s-maxage=${TTL_SECONDS}`);

    // Cache the response asynchronously
    ctx.waitUntil(cache.put(cacheKey, resp.clone()));
    return addCors(resp);
  },
};

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
