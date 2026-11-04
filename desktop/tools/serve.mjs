// Serves the built front end with `loftline-core` behind POST /core, so the app can be driven in a plain browser: headless
// screenshots, and development without the Tauri shell. Usage: node tools/serve.mjs <path to loftline-core> [port]
import { spawn } from "node:child_process";
import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const core = process.argv[2];
const port = Number(process.argv[3] ?? 5174);
const dist = join(fileURLToPath(new URL("..", import.meta.url)), "dist");
const child = spawn(core, [], { stdio: ["pipe", "pipe", "inherit"] });
const waiting = [];
createInterface({ input: child.stdout }).on("line", (line) => waiting.shift()?.(line));
child.on("exit", (code) => { console.error(`loftline-core exited (${code})`); process.exit(1); });
let queue = Promise.resolve();
const call = (line) => {
  const result = queue.then(() => new Promise((resolve) => { waiting.push(resolve); child.stdin.write(line + "\n"); }));
  queue = result.catch(() => {});
  return result;
};
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".map": "application/json" };
createServer((req, res) => {
  if (req.method === "POST" && req.url === "/core") {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", async () => {
      const line = await call(body.replace(/\n/g, " "));
      res.writeHead(200, { "content-type": "application/json" });
      res.end(line);
    });
    return;
  }
  const path = normalize(req.url.split("?")[0]).replace(/^(\.\.[/\\])+/, "");
  let file = join(dist, path === "/" ? "index.html" : path);
  if (!existsSync(file) || !statSync(file).isFile()) file = join(dist, "index.html");
  res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
  createReadStream(file).pipe(res);
}).listen(port, () => console.log(`http://localhost:${port}`));
