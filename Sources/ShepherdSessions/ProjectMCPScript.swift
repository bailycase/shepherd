import Foundation

/// The canonical bridge lives in Extensions/shepherd-project-mcp-sign-in.mjs.
enum ProjectMCPScript {
    static func install(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("shepherd-project-mcp-sign-in.mjs")
        let data = Data(source.utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url
    }
    static let source = #"""
        // Host-owned project MCP OAuth. Only explicit MCP commands run; no model calls or project extensions.
        import * as path from "node:path";
        import * as readline from "node:readline";
        import { pathToFileURL } from "node:url";

        const send = (message) => console.log(JSON.stringify(message));
        const input = readline.createInterface({ input: process.stdin });
        let configure;
        const configured = new Promise((resolve) => { configure = resolve; });
        let redirect, pendingRedirect;
        input.on("line", (line) => {
          try {
            const message = JSON.parse(line);
            if (message.type === "answer" && message.id === "config") configure(JSON.parse(message.value));
            if (message.type === "answer" && message.id === "redirect") {
              if (redirect) redirect(message.value); else pendingRedirect = message.value;
            }
          } catch { /* Invalid input cannot start a command. */ }
        });
        input.on("close", () => process.exit(0));
        const deadline = setTimeout(() => {
          send({ type: "failed", code: "other", reason: "Signing in didn't finish within 300 seconds." });
          process.exit(0);
        }, 300_000);

        let session;
        try {
          const { server, config: original, shared, directory, command } = await configured;
          if (!/^[A-Za-z0-9_-]+$/.test(server) || !["login", "logout"].includes(command)) throw new Error("Invalid action");
          const config = { url: original.url, headers: original.headers, oauth: original.oauth, exposure: "hidden", timeout: 30 };
          // Match the shared-file registration's expansion and separation from Shepherd's own secrets.
          if (shared) {
            const reference = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g;
            const expand = (text, settleOnly) => text.replace(reference, (whole, name, fallback) =>
              name.startsWith("SHEPHERD_") ? fallback ?? "" : settleOnly && fallback === undefined ? whole : process.env[name] ?? fallback ?? whole);
            config.url = expand(config.url, false);
            if (config.headers) config.headers = Object.fromEntries(Object.entries(config.headers).map(([key, value]) => [key, expand(value, true)]));
            delete config.oauth; // Shared-file registration uses pi's default OAuth settings.
          }
          // Custom loadConfig bypasses pi's file validator, so validate the HTTP/OAuth trust boundary here.
          const endpoint = new URL(config.url);
          if (!["https:", "http:"].includes(endpoint.protocol)) throw new Error("Invalid HTTP server");
          if (config.headers && (typeof config.headers !== "object" || Array.isArray(config.headers) || Object.values(config.headers).some((value) => typeof value !== "string"))) throw new Error("Invalid headers");
          const oauth = config.oauth;
          const loopback = (url) => url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) && !url.username && !url.password;
          if (oauth !== undefined) {
            if (!oauth || typeof oauth !== "object" || Array.isArray(oauth)) throw new Error("Invalid OAuth");
            for (const field of ["clientId", "clientSecret", "scope", "clientName", "callbackUrl", "authServerMetadataUrl"]) {
              if (oauth[field] !== undefined && typeof oauth[field] !== "string") throw new Error("Invalid OAuth field");
            }
            if (oauth.callbackPort !== undefined && (!Number.isInteger(oauth.callbackPort) || oauth.callbackPort < 1024 || oauth.callbackPort > 65535)) throw new Error("Invalid callback port");
            if (oauth.callbackUrl) {
              const callback = new URL(oauth.callbackUrl);
              if (!loopback(callback) || callback.search || callback.hash || (oauth.callbackPort && Number(callback.port || 80) !== oauth.callbackPort)) throw new Error("Invalid callback URL");
            }
            if (oauth.authServerMetadataUrl) {
              const metadata = new URL(oauth.authServerMetadataUrl);
              if (metadata.protocol !== "https:" && !loopback(metadata)) throw new Error("Invalid metadata URL");
            }
          }
          // A settings action must not execute a project's !command secret resolver.
          for (const value of [...Object.values(config.headers ?? {}), config.oauth?.clientSecret]) {
            if (typeof value === "string" && value.startsWith("!")) throw new Error("Command credentials are not supported here");
          }
          if (Object.keys(config.headers ?? {}).some((key) => key.toLowerCase() === "authorization")) throw new Error("Not OAuth");
          send({ type: "event", event: { type: "info", message: JSON.stringify({ server, rawURL: original.url, resolvedURL: endpoint.href }) } });
          const home = process.argv[3];
          const { createAgentSession, createMcpExtension, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } =
            await import(pathToFileURL(process.argv[2]).href);
          const settingsManager = SettingsManager.inMemory();
          const resourceLoader = new DefaultResourceLoader({
            cwd: home, agentDir: home, settingsManager,
            noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
            extensionFactories: [createMcpExtension({
              loadConfig: () => ({ servers: [{ name: server, config, source: "<selected-project-server>", scope: "extension" }], errors: [], autoEnableCodemode: false }),
              openUrl: (url) => send({ type: "event", event: { type: "auth_url", url: String(url) } }),
            })],
          });
          await resourceLoader.reload();
          const modelRuntime = await ModelRuntime.create({ authPath: path.join(home, "auth.json"), modelsPath: path.join(home, "models.json"), refreshOnCreate: false });
          ({ session } = await createAgentSession({ cwd: directory, agentDir: home, settingsManager, resourceLoader, modelRuntime, sessionManager: SessionManager.inMemory(home), noTools: "all" }));
          let failed = false;
          await session.bindExtensions({
            mode: "rpc",
            uiContext: {
              notify(_message, level) { if (level === "error") failed = true; },
              input(_title, _placeholder, { signal }) {
                return new Promise((resolve) => {
                  const finish = (value) => { redirect = undefined; signal.removeEventListener("abort", abort); resolve(value); };
                  const abort = () => finish(undefined);
                  redirect = finish;
                  if (pendingRedirect !== undefined) { const value = pendingRedirect; pendingRedirect = undefined; finish(value); }
                  else if (signal.aborted) abort(); else signal.addEventListener("abort", abort, { once: true });
                });
              },
            },
            onError() { failed = true; },
          });
          if (!session.extensionRunner.getCommand("mcp")) throw new Error("MCP command is unavailable");
          await session.prompt(`/mcp ${command} ${server}`);
          send(failed ? { type: "failed", code: "other", reason: "The MCP server couldn't complete sign-in. Check its URL and OAuth settings, then try again." }
            : { type: "done", provider: server, credential: "oauth" });
        } catch {
          // Never return provider responses, project header values, tokens or redirect codes as errors.
          send({ type: "failed", code: "other", reason: "Project MCP authentication failed. Check the server configuration and try again." });
        } finally {
          if (session) {
            await session.extensionRunner.emit({ type: "session_shutdown", reason: "exit" });
            session.dispose();
          }
          clearTimeout(deadline);
          input.close();
        }

        """#
}
