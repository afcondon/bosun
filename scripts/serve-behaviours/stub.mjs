// A stand-in backend for scripts/serve-behaviours/run.mjs.
//
//   node stub.mjs <port> [--host <address>] [--stubborn] [--tree] [--label <text>]
//   node stub.mjs --socket <path>
//
// --stubborn  ignore SIGTERM, so only SIGKILL stops it
// --tree      start a child process (`sleep`) in the same process group
//
// Paths:
//   /pid          {"pid", "child", "label"}
//   /echo         the request as JSON: method, url, headers, body
//   /status/NNN   answers with that status
//   /hang         never answers
//   /drop         closes the connection without answering
//   /stream       three chunks, 150 ms apart
//   /drip?ms=N    one byte every 500 ms for N ms
//   /upgrades     how many upgraded connections are open
//   anything else "ok"
// An Upgrade request is answered 101, then one JSON line naming the request,
// then every byte is echoed. The bytes `bye` make the stub close the socket.
import http from "node:http";
import fs from "node:fs";
import { spawn } from "node:child_process";

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };

if (flag("--stubborn")) process.on("SIGTERM", () => {});
const child = flag("--tree") ? spawn("sleep", ["3600"], { stdio: "ignore" }) : null;
const label = option("--label") || "";
let upgrades = 0;

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://stub");
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    if (url.pathname === "/pid") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ pid: process.pid, child: child ? child.pid : null, label }));
    } else if (url.pathname === "/echo") {
      res.writeHead(200, { "content-type": "application/json", "x-stub": "1" });
      res.end(JSON.stringify({ method: req.method, url: req.url, headers: req.headers, bytes: body.length, body: body.length < 4096 ? body.toString() : null, sum: checksum(body) }));
    } else if (url.pathname.startsWith("/status/")) {
      res.writeHead(Number(url.pathname.slice(8)), { "content-type": "text/plain" });
      res.end("status\n");
    } else if (url.pathname === "/hang") {
      // never answers
    } else if (url.pathname === "/drop") {
      req.socket.destroy();
    } else if (url.pathname === "/stream") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.write("one\n");
      setTimeout(() => res.write("two\n"), 150);
      setTimeout(() => res.end("three\n"), 300);
    } else if (url.pathname === "/drip") {
      const until = Date.now() + Number(url.searchParams.get("ms") || 3000);
      res.writeHead(200, { "content-type": "text/plain" });
      const tick = () => {
        if (Date.now() >= until) { res.end("!"); return; }
        res.write(".");
        setTimeout(tick, 500);
      };
      tick();
    } else if (url.pathname === "/upgrades") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ upgrades }));
    } else {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("ok\n");
    }
  });
});

server.on("upgrade", (req, socket) => {
  upgrades += 1;
  socket.on("close", () => { upgrades -= 1; });
  socket.on("error", () => {});
  // node leaves an upgraded socket half open when the peer finishes; a real
  // WebSocket server closes, so this does.
  socket.on("end", () => socket.end());
  socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: echo\r\nConnection: Upgrade\r\n\r\n");
  socket.write(JSON.stringify({ method: req.method, url: req.url, test: req.headers["x-test"] || null }) + "\n");
  socket.on("data", (d) => {
    if (d.toString().includes("bye")) { socket.destroy(); return; }
    socket.write(d);
  });
});

function checksum(buffer) {
  let sum = 0;
  for (const byte of buffer) sum = (sum * 31 + byte) >>> 0;
  return sum;
}

const socketPath = option("--socket");
if (socketPath) {
  try { fs.unlinkSync(socketPath); } catch (_) {}
  server.listen(socketPath);
  const tidy = () => { try { fs.unlinkSync(socketPath); } catch (_) {} process.exit(0); };
  process.on("SIGTERM", tidy);
  process.on("SIGINT", tidy);
} else {
  server.listen(Number(args[0]), option("--host") || "127.0.0.1");
}
