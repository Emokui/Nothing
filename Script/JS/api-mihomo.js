export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    const whitelist = [
      "/repos/MetaCubeX/mihomo/releases/latest",
    ];

    if (!whitelist.includes(url.pathname)) {
      return new Response("403 Forbidden: 路径未授权", { status: 403 });
    }

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, OPTIONS",
          "Access-Control-Allow-Headers": "*",
        },
      });
    }

    const targetUrl = "https://api.github.com" + url.pathname + url.search;

    const headers = new Headers(request.headers);
    headers.set("User-Agent", "Cloudflare-Worker-Proxy");
    headers.set("Accept", "application/vnd.github.v3+json");

    const newRequest = new Request(targetUrl, {
      method: "GET",
      headers,
    });

    return fetch(newRequest, {
      cf: {
        cacheTtl: 300,
        cacheEverything: true,
      },
    });
  },
};
