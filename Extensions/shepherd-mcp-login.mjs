// pi's own `mcp login <server>` for a sign-in a remote client started (Settings on another device):
// the same command, config and credential store, with pi's `openUrl` option given so the page is
// only printed (pi's log line carries it) and never opens in this Mac's browser. The Mac's own
// Sign in still runs `pi mcp login` through the launcher, which opens it. Dependency-free.
// argv: <pi's modular dist/extensions/mcp/cli.js> <pi home> <server> <timeout seconds>
import { pathToFileURL } from "node:url";

const [cli, home, server, timeout] = process.argv.slice(2);
if (!cli || !home || !server || !/^[A-Za-z0-9_-]+$/.test(server)) {
  console.error("Usage: shepherd-mcp-login.mjs <cli.js> <home> <server> [timeout]");
  process.exit(2);
}
const seconds = Number(timeout) > 0 ? Math.min(Number(timeout), 600) : 300;
try {
  const { runMcpCommand } = await import(pathToFileURL(cli).href);
  process.exitCode = await runMcpCommand(["login", server, "--timeout", String(seconds)], {
    cwd: home,
    agentDir: home,
    openUrl: () => {},
  });
} catch {
  // Never echo a provider response, token or redirect code.
  console.error(`Sign-in to MCP server "${server}" couldn't start.`);
  process.exitCode = 1;
}
