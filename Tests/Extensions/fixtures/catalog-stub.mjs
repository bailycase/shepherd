// A stand-in for pi.dev's model catalog, so a test can run pi's real `update --models` with no
// network. pi fetches https://pi.dev/api/models/providers/<id> through undici's EnvHttpProxyAgent,
// so this is an HTTP proxy whose CONNECT tunnels end in a local TLS server holding a throwaway
// certificate for pi.dev (trusted by the test through NODE_EXTRA_CA_CERTS).
//
//   node catalog-stub.mjs <dir> <catalog.json>
//
// Writes <dir>/ca.pem, prints {"proxy": "http://127.0.0.1:<port>", "ca": "<dir>/ca.pem"} and serves
// until stdin closes. <catalog.json> maps provider ids to model arrays; it is read per request, so a
// test can add a model between refreshes. Other providers answer 404, which pi records as "none".
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { join } from "node:path";

const [dir, catalogPath] = process.argv.slice(2);
const key = join(dir, "key.pem");
const ca = join(dir, "ca.pem");
execFileSync("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", ca,
  "-days", "1", "-subj", "/CN=pi.dev", "-addext", "subjectAltName=DNS:pi.dev"], { stdio: "ignore" });

const catalog = https.createServer({ key: readFileSync(key), cert: readFileSync(ca) }, (request, response) => {
  const match = /^\/api\/models\/providers\/([^/?]+)/.exec(request.url ?? "");
  const models = match ? JSON.parse(readFileSync(catalogPath, "utf8"))[decodeURIComponent(match[1])] : undefined;
  if (!models) {
    response.writeHead(404).end();
    return;
  }
  response.writeHead(200, { "content-type": "application/json", "last-modified": new Date().toUTCString() });
  response.end(JSON.stringify({ models }));
});
await new Promise((resolve) => catalog.listen(0, "127.0.0.1", resolve));

const proxy = http.createServer((_request, response) => response.writeHead(405).end());
proxy.on("connect", (request, client, head) => {
  // Only pi.dev is answered; anything else is refused, so the test can never reach the network.
  if (!request.url?.startsWith("pi.dev:")) {
    client.end("HTTP/1.1 403 Forbidden\r\n\r\n");
    return;
  }
  const upstream = net.connect(catalog.address().port, "127.0.0.1", () => {
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    upstream.write(head);
    upstream.pipe(client).pipe(upstream);
  });
  upstream.on("error", () => client.destroy());
  client.on("error", () => upstream.destroy());
});
await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));

process.stdout.write(`${JSON.stringify({ proxy: `http://127.0.0.1:${proxy.address().port}`, ca })}\n`);
process.stdin.resume();
process.stdin.on("end", () => process.exit(0));
