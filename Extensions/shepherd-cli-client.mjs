// Private CLI transport used by Shepherd's existing launcher, never the host socket.
import * as net from "node:net";
import { pathToFileURL } from "node:url";

export function parseCliArgs(args) {
  const request = { mode: "text" };
  let print = false;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--print" || arg === "-p") { print = true; continue; }
    if (["--mode", "--model", "--thinking", "--provider", "--tools"].includes(arg)) {
      const value = args[++i];
      if (!value || value.startsWith("-")) throw Error(`${arg} needs a value`);
      request[arg.slice(2)] = value;
    } else if (!arg.startsWith("-") && request.prompt === undefined) request.prompt = arg;
    else throw Error(`Unsupported supervised Pi argument: ${arg}`);
  }
  if (!print || !request.prompt?.trim() || request.prompt.length > 16384) throw Error("Expected --print 'prompt or /command [arguments]'");
  if (!["text", "json"].includes(request.mode)) throw Error("Pi subprocess output mode must be text or json");
  if (request.thinking && !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(request.thinking)) throw Error("Invalid thinking level");
  return request;
}

async function main() {
  const request = { ...parseCliArgs(process.argv.slice(3)), cwd: process.cwd() };
  const socket = net.createConnection(process.argv[2]);
  const interrupt = () => { socket.destroy(); process.exitCode = 130; };
  process.once("SIGINT", interrupt); process.once("SIGTERM", interrupt);
  let buffer = "", complete = false;
  socket.on("connect", () => socket.write(JSON.stringify(request) + "\n"));
  socket.setEncoding("utf8");
  socket.on("data", chunk => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > 1024 * 1024) { socket.destroy(Error("Pi subprocess response exceeds 1 MiB")); return; }
    for (let end; (end = buffer.indexOf("\n")) >= 0; buffer = buffer.slice(end + 1)) {
      let frame;
      try { frame = JSON.parse(buffer.slice(0, end)); } catch { socket.destroy(Error("Invalid Pi subprocess response")); return; }
      if (frame.event && request.mode === "json") process.stdout.write(JSON.stringify(frame.event) + "\n");
      if (frame.done) {
        complete = true;
        if (frame.error) { process.stderr.write(frame.error + "\n"); process.exitCode = 1; }
        else if (request.mode === "text") process.stdout.write((frame.output ?? "") + "\n");
        socket.end();
      }
    }
  });
  socket.on("error", error => { process.stderr.write(`Pi subprocess: ${error.message}\n`); process.exitCode = 1; });
  socket.on("close", () => {
    if (!complete && process.exitCode === undefined) { process.stderr.write("Pi subprocess closed before completion\n"); process.exitCode = 1; }
    process.removeListener("SIGINT", interrupt); process.removeListener("SIGTERM", interrupt);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { process.stderr.write(error.message + "\n"); process.exitCode = 1; });
}
