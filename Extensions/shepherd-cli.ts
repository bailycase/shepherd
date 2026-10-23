// Internal support for ordinary `pi -p` subprocesses, installed beside the child bridge.
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import { AsyncLocalStorage } from "node:async_hooks";
import { pathToFileURL } from "node:url";
import { createBashTool, DefaultPackageManager, getAgentDir, getPackageDir, SettingsManager } from "@earendil-works/pi-coding-agent";

export const cliLimits = Object.freeze({ milliseconds: 1_800_000, children: 32, turns: 256, tokens: 1_000_000, cost: 10, bytes: 1024 * 1024 });
const context = new AsyncLocalStorage();
export const withoutCliDispatch = execute => context.run(true, execute);
export function cliBudget(signal) {
  const controller = new AbortController();
  const abort = () => controller.abort(signal?.reason ?? Error("Pi subprocess cancelled"));
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) abort();
  const timer = setTimeout(() => controller.abort(Error("Pi subprocess reached its time limit")), cliLimits.milliseconds);
  timer.unref?.();
  const used = { children: 0, turns: 0, tokens: 0, cost: 0 };
  return {
    signal: controller.signal, used,
    cancel(reason) { controller.abort(reason); },
    add(amounts) {
      controller.signal.throwIfAborted();
      for (const key of Object.keys(used)) {
        const value = amounts[key] ?? 0;
        if (!Number.isFinite(value) || value < 0) throw Error("Invalid Pi subprocess usage");
        used[key] += value;
        if (key === "children" ? used[key] > cliLimits[key] : used[key] >= cliLimits[key]) controller.abort(Error(`Pi subprocess reached its ${key} limit (${cliLimits[key]})`));
      }
      controller.signal.throwIfAborted();
    },
    close() { clearTimeout(timer); signal?.removeEventListener("abort", abort); },
  };
}

export function cliRelayAllowed(name) {
  return !/^(?:shepherd_(?:child_|workflow$|parent_message$|mission$)|subagent$|agent_|automation_|browser_|codemode$|tool_search$|comment_reply$|markup_propose$|checkpoint_restore$)/.test(name);
}

export async function expandCliPrompt(text, ctx) {
  if (!ctx.isProjectTrusted()) throw Error("Approve the project before dispatching Pi subprocesses");
  if (!text.startsWith("/")) return text;
  const agentDir = getAgentDir();
  const settings = SettingsManager.create(ctx.cwd, agentDir, { projectTrusted: true });
  const resources = await new DefaultPackageManager({ cwd: ctx.cwd, agentDir, settingsManager: settings }).resolve(async () => "skip");
  const { loadPromptTemplates, expandPromptTemplate } = await import(pathToFileURL(path.join(getPackageDir(), "dist/core/prompt-templates.js")).href);
  const { templates } = loadPromptTemplates({ cwd: ctx.cwd, agentDir, includeDefaults: false,
    promptPaths: resources.prompts.filter(p => p.enabled).map(p => p.path) });
  const name = text.slice(1).split(/\s/, 1)[0];
  if (!templates.some(template => template.name === name)) throw Error(`Command /${name} is not enabled in this project`);
  return expandPromptTemplate(text, templates);
}

export function registerCliBash(pi, { bridge, dispatch, bashOperations }) {
  const jobs = new Set();
  // Override the existing tool, retaining its schema and normal tool_call permission checks.
  pi.registerTool({ ...createBashTool(process.cwd()),
    async execute(id, params, signal, onUpdate, ctx) {
      const settings = SettingsManager.create(ctx.cwd, getAgentDir(), { projectTrusted: ctx.isProjectTrusted() });
      const delegated = context.getStore() === true;
      let budget;
      const dir = fs.mkdtempSync("/tmp/shepherd-cli-");
      fs.chmodSync(dir, 0o700);
      const socketPath = path.join(dir, "s"), client = path.join(path.dirname(bridge), "shepherd-cli-client.mjs");
      const sockets = new Set(), pending = new Set();
      const cancel = () => { for (const socket of sockets) socket.destroy(); };
      const server = net.createServer(socket => {
        sockets.add(socket);
        let input = "", admitted = false;
        const disconnect = new AbortController();
        const send = value => {
          if (socket.destroyed || socket.writableLength > cliLimits.bytes) throw Error("Pi subprocess stopped reading");
          const line = JSON.stringify(value) + "\n";
          if (Buffer.byteLength(line) > cliLimits.bytes) throw Error("Pi subprocess frame exceeds 1 MiB");
          socket.write(line);
        };
        socket.setEncoding("utf8");
        socket.on("error", () => {});
        socket.on("close", () => { sockets.delete(socket); disconnect.abort(Error("Pi CLI disconnected")); });
        socket.on("data", chunk => {
          if (admitted) { socket.destroy(); return; }
          input += chunk;
          if (Buffer.byteLength(input) > 32768) { socket.destroy(); return; }
          const end = input.indexOf("\n");
          if (end < 0) return;
          admitted = true;
          const work = (async () => {
            try {
              if (!ctx.isProjectTrusted()) throw Error("Approve this project before running Pi subprocesses");
              const request = JSON.parse(input.slice(0, end));
              if (fs.realpathSync(request.cwd) !== fs.realpathSync(ctx.cwd)) throw Error("Pi subprocesses must run in the calling project directory");
              if (typeof request.prompt !== "string" || !request.prompt.trim() || request.prompt.length > 16384) throw Error("Invalid Pi subprocess prompt");
              if (!["text", "json"].includes(request.mode)) throw Error("Invalid Pi subprocess output mode");
              if (!budget) {
                budget = cliBudget(signal); jobs.add(budget);
                budget.signal.addEventListener("abort", cancel, { once: true });
              }
              budget.add({ children: 1 });
              const requestSignal = AbortSignal.any([budget.signal, disconnect.signal, ...(signal ? [signal] : [])]);
              let outputBytes = 0;
              const emit = event => {
                outputBytes += Buffer.byteLength(JSON.stringify(event));
                if (outputBytes > cliLimits.bytes) throw Error("Pi subprocess output exceeds 1 MiB");
                if (request.mode === "json") send({ event });
              };
              const output = await dispatch(request, ctx, requestSignal, budget, emit, id);
              send({ done: true, output });
            } catch (error) {
              try { send({ done: true, error: String(error?.message ?? error) }); } catch { socket.destroy(); }
            }
          })();
          pending.add(work); work.finally(() => pending.delete(work));
        });
      });
      signal?.addEventListener("abort", cancel, { once: true });
      try {
        await new Promise((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
        fs.chmodSync(socketPath, 0o600);
        const bash = createBashTool(ctx.cwd, { operations: bashOperations(), shellPath: settings.getShellPath(), commandPrefix: settings.getShellCommandPrefix(),
          spawnHook(spawn) {
            const env = { ...spawn.env };
            for (const key of Object.keys(env)) if (key.startsWith("SHEPHERD_MCP_SECRET") || ["SHEPHERD_MCP_SECRETS", "SHEPHERD_SOCKET", "SHEPHERD_AGENT_ID", "SHEPHERD_DESIGN_ID"].includes(key)) delete env[key];
            delete env.SHEPHERD_CLI_SOCKET; delete env.SHEPHERD_CLI_CLIENT; delete env.SHEPHERD_CLI_DENIED;
            return { ...spawn, env: delegated ? { ...env, SHEPHERD_CLI_DENIED: "1" } : { ...env, SHEPHERD_CLI_SOCKET: socketPath, SHEPHERD_CLI_CLIENT: client } };
          } });
        const result = await bash.execute(id, params, signal, onUpdate, ctx);
        budget?.signal.throwIfAborted();
        return budget ? { ...result, details: { ...result.details, cliUsage: budget.used } } : result;
      } finally {
        if (budget) budget.cancel(Error("Calling Bash command ended"));
        for (const socket of sockets) socket.destroy();
        await Promise.allSettled([...pending]);
        await new Promise(resolve => server.listening ? server.close(resolve) : resolve());
        signal?.removeEventListener("abort", cancel);
        budget?.signal.removeEventListener("abort", cancel);
        if (budget) { budget.close(); jobs.delete(budget); }
        fs.rmSync(dir, { recursive: true, force: true });
      }
    },
  });
  return () => { for (const budget of jobs) budget.cancel(Error("Parent session ended")); };
}
