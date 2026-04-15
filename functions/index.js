function isBrowserUserAgent(userAgent) {
  return userAgent.toLowerCase().includes("mozilla/");
}

async function fetchAsset(context, assetPath) {
  if (typeof context.next === "function") {
    return context.next(assetPath);
  }

  if (context.env && context.env.ASSETS && typeof context.env.ASSETS.fetch === "function") {
    const assetUrl = new URL(assetPath, context.request.url);
    const assetRequest = new Request(assetUrl.toString(), context.request);
    return context.env.ASSETS.fetch(assetRequest);
  }

  throw new Error("Pages asset routing is unavailable in this environment.");
}

export async function onRequest(context) {
  const userAgent = context.request.headers.get("User-Agent") || "";
  const browserRequest = isBrowserUserAgent(userAgent);
  const assetPath = browserRequest ? "/" : "/install.sh";
  const contentType = browserRequest
    ? "text/html; charset=utf-8"
    : "text/plain; charset=utf-8";
  const assetResponse = await fetchAsset(context, assetPath);
  const headers = new Headers(assetResponse.headers);

  headers.set("Content-Type", contentType);
  headers.set("Cache-Control", "public, max-age=300");
  headers.set("Vary", "User-Agent");
  headers.set(
    "X-Fremkit-Routing",
    browserRequest ? "browser-html" : "script-install",
  );

  return new Response(assetResponse.body, {
    status: assetResponse.status,
    statusText: assetResponse.statusText,
    headers,
  });
}
