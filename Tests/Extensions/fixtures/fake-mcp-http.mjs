// A scripted MCP server over Streamable HTTP (POST /mcp), on a loopback ephemeral port, for the extension tests.
// `const server = await startFakeMcpHttp({ tools, bearer, sse })`:
//   tools    the tool list (default: fake-mcp-catalog's base tools); `server.setTools(list)` changes it and sends no
//            notification, as a server that does not announce changes
//   bearer   when set, any request without `Authorization: Bearer <bearer>` is answered 401 with a challenge
//   sse      answer each request as one server-sent event instead of a JSON body
//   requests every request received: { method, headers, body } (body is the parsed JSON-RPC message)
// Tools answer as in fake-mcp-catalog.mjs; `whoami` returns the request's headers, so a test sees what pi sent.
import * as http from "node:http";
import * as catalog from "./fake-mcp-catalog.mjs";

export async function startFakeMcpHttp({ tools = catalog.base(), bearer, sse = false } = {}) {
  let list = [...tools, { name: "whoami", description: "Reports the headers of its own request.", inputSchema: { type: "object" } }];
  const requests = [];
  let current;
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let body;
    try { body = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { body = undefined; }
    requests.push({ method: req.method, headers: req.headers, body });
    if (req.method !== "POST" || !String(req.url).startsWith("/mcp")) {
      res.writeHead(405).end();
      return;
    }
    if (bearer !== undefined && req.headers.authorization !== `Bearer ${bearer}`) {
      res.writeHead(401, { "www-authenticate": `Bearer realm="fake-mcp"` }).end();
      return;
    }
    if (body?.id === undefined) {
      res.writeHead(202).end();
      return;
    }
    const reply = (result) => {
      const message = JSON.stringify({ jsonrpc: "2.0", id: body.id, result });
      if (sse) res.writeHead(200, { "content-type": "text/event-stream" }).end(`event: message\ndata: ${message}\n\n`);
      else res.writeHead(200, { "content-type": "application/json" }).end(message);
    };
    const fail = (code, message) => res.writeHead(200, { "content-type": "application/json" })
      .end(JSON.stringify({ jsonrpc: "2.0", id: body.id, error: { code, message } }));
    switch (body.method) {
      case "initialize":
        res.setHeader("mcp-session-id", "fake-session");
        return reply({ protocolVersion: body.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "fake-mcp-http", version: "1.0.0" } });
      case "ping": return reply({});
      case "tools/list": return reply({ tools: list });
      case "tools/call": {
        const { name, arguments: args = {} } = body.params;
        if (!list.some((tool) => tool.name === name)) return fail(-32602, `Unknown tool: ${name}`);
        if (name === "whoami") return reply(catalog.text(JSON.stringify(req.headers)));
        return reply(catalog.call(name, args));
      }
      default: return fail(-32601, `Method not found: ${body.method}`);
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  current = {
    url: `http://127.0.0.1:${server.address().port}/mcp`,
    port: server.address().port,
    requests,
    setTools(next) { list = [...next, list.at(-1)]; },
    async stop() {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
  return current;
}
