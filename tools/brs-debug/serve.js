#!/usr/bin/env node
/*
 * Tiny dependency-free static server for the brs-engine HydraHD debug harness.
 *
 * brs-engine uses SharedArrayBuffer + Atomics, which require the page to be
 * "cross-origin isolated". That needs two response headers on the document
 * (and on the worker script):
 *     Cross-Origin-Opener-Policy:   same-origin
 *     Cross-Origin-Embedder-Policy: credentialless
 * `credentialless` is used instead of `require-corp` so the emulated channel's
 * cross-origin subresource requests are not hard-blocked (they are sent without
 * credentials). Cross-origin *reads* are still subject to CORS, so live network
 * data may still be limited - that is expected and fine for visual/nav debugging.
 *
 * Usage:  node serve.js [port]      (default port 6502)
 */
"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");
const url = require("url");

const ROOT = __dirname;
const PORT = parseInt(process.argv[2], 10) || 6502;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".zip": "application/zip",
  ".bpk": "application/zip",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

function isolationHeaders(res) {
  // Required for SharedArrayBuffer / cross-origin isolation.
  res.setHeader("Cross-Origin-Opener-Policy", "same-origin");
  res.setHeader("Cross-Origin-Embedder-Policy", "credentialless");
  res.setHeader("Cross-Origin-Resource-Policy", "cross-origin");
  // Never cache - so a rebuilt channel zip is always picked up fresh.
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
}

const DESKTOP_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

// CORS proxy: the engine (deviceData.corsProxy) prepends this server's
// /proxy/ to every outbound channel request, e.g.
//   /proxy/https://hydrahd.ru/...   ->  fetched server-side, returned with ACAO:*
// This lets the emulated channel load real listing/detail data that the
// browser would otherwise block by CORS. Best-effort: some mirror CDNs /
// Turnstile-gated hosts still won't resolve, which is expected.
async function handleProxy(req, res, rawUrl) {
  let target = rawUrl;
  if (!/^https?:\/\//i.test(target)) {
    try { target = decodeURIComponent(target); } catch (e) {}
  }
  if (!/^https?:\/\//i.test(target)) {
    res.writeHead(400, { "Access-Control-Allow-Origin": "*" });
    res.end("proxy: bad target url");
    return;
  }
  // Forward a useful subset of headers; default a desktop UA + Referer so
  // origin sites that reject the Roku UA still serve content.
  const fwd = {};
  const passthrough = ["accept", "accept-language", "content-type", "referer", "cookie", "x-user-agent", "x-requested-with", "origin", "range"];
  for (const h of passthrough) {
    if (req.headers[h]) fwd[h] = req.headers[h];
  }
  fwd["user-agent"] = DESKTOP_UA;
  if (!fwd["referer"]) {
    try { const u = new URL(target); fwd["referer"] = u.origin + "/"; } catch (e) {}
  }
  let body;
  if (req.method !== "GET" && req.method !== "HEAD") {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    body = Buffer.concat(chunks);
  }
  try {
    const r = await fetch(target, { method: req.method, headers: fwd, body, redirect: "follow" });
    const buf = Buffer.from(await r.arrayBuffer());
    const ct = r.headers.get("content-type") || "application/octet-stream";
    res.writeHead(r.status, {
      "Content-Type": ct,
      "Content-Length": buf.length,
      "Access-Control-Allow-Origin": "*",
      "Cross-Origin-Resource-Policy": "cross-origin",
      "Cache-Control": "no-store",
    });
    res.end(buf);
  } catch (e) {
    res.writeHead(502, { "Access-Control-Allow-Origin": "*", "Content-Type": "text/plain" });
    res.end("proxy error: " + (e && e.message ? e.message : String(e)));
  }
}

const server = http.createServer((req, res) => {
  // Proxy endpoint must use the RAW url (the target URL must not be decoded/normalized).
  const proxyMarker = "/proxy/";
  if (req.url.startsWith(proxyMarker)) {
    handleProxy(req, res, req.url.slice(proxyMarker.length));
    return;
  }

  let pathname = decodeURIComponent(url.parse(req.url).pathname);
  if (pathname === "/" || pathname === "") pathname = "/index.html";

  // Resolve and guard against path traversal.
  const filePath = path.normalize(path.join(ROOT, pathname));
  if (!filePath.startsWith(ROOT)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  fs.stat(filePath, (err, stat) => {
    if (err || !stat.isFile()) {
      isolationHeaders(res);
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("404 Not Found: " + pathname);
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    isolationHeaders(res);
    res.writeHead(200, {
      "Content-Type": MIME[ext] || "application/octet-stream",
      "Content-Length": stat.size,
    });
    fs.createReadStream(filePath).pipe(res);
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log("[brs-debug] serving " + ROOT);
  console.log("[brs-debug] cross-origin-isolated harness at http://127.0.0.1:" + PORT + "/");
  console.log("[brs-debug] channel expected at /channel/HydraHD.zip");
});
