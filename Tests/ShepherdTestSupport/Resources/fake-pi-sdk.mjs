// A stand-in for pi's SDK (`dist/bundle/index.js`) for the sign-in bridge's tests: the same
// `ModelRuntime` surface the bridge uses (create, getProvider, getModels, login, logout,
// completeSimple), with scripted providers and fake credentials, writing the auth.json it's given.
// No network: a browser sign-in's "callback" is an HTTP server on an ephemeral port whose address
// is in the auth URL's instructions, and a device sign-in completes when `approved` appears in
// FAKE_PI_CONTROL.
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";

const control = process.env.FAKE_PI_CONTROL;

function readAuth(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function writeAuth(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify(data, null, 2), { mode: 0o600 });
  fs.renameSync(temp, file);
}

const providers = {
  anthropic: { id: "anthropic", name: "Anthropic", auth: { oauth: { name: "Anthropic (Claude Pro/Max)" } } },
  "openai-codex": { id: "openai-codex", name: "OpenAI Codex", auth: { oauth: { name: "OpenAI (ChatGPT Plus/Pro)" } } },
  "github-copilot": { id: "github-copilot", name: "GitHub Copilot", auth: { oauth: { name: "GitHub Copilot" } } },
  deepseek: { id: "deepseek", name: "DeepSeek", auth: { apiKey: { name: "DeepSeek API key" } } },
};
const models = {
  deepseek: [
    { id: "deepseek-chat", provider: "deepseek", reasoning: false },
    { id: "deepseek-reasoner", provider: "deepseek", reasoning: true },
  ],
};

function oauthCredential() {
  return { type: "oauth", access: "fake-access-token-0001", refresh: "fake-refresh-token-0001", expires: Date.now() + 3600_000 };
}

async function browserLogin(interaction) {
  let settle;
  const callback = new Promise((resolve) => (settle = resolve));
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    res.end("ok");
    settle({ code: url.searchParams.get("code") });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const manual = new AbortController();
  const onAbort = () => settle(null);
  interaction.signal.addEventListener("abort", onAbort, { once: true });
  try {
    interaction.notify({
      type: "auth_url",
      url: "https://example.invalid/authorize?state=fake-state",
      instructions: `callback http://127.0.0.1:${port}/callback`,
    });
    let pasted;
    interaction
      .prompt({ type: "manual_code", message: "Paste the code", placeholder: "code#state", signal: manual.signal })
      .then((value) => {
        pasted = value;
        settle(null);
      })
      .catch(() => {});
    const result = await callback;
    if (interaction.signal.aborted) throw new Error("Login cancelled");
    const code = result?.code ?? pasted?.split("#")[0];
    if (!code) throw new Error("Missing authorization code");
    if (code !== "FAKE-CODE") throw new Error("That code was already used. Open the page again for a new one.");
    interaction.notify({ type: "progress", message: "Exchanging authorization code for tokens..." });
    return oauthCredential();
  } finally {
    manual.abort();
    server.close();
  }
}

async function deviceLogin(interaction) {
  const domain = await interaction.prompt({ type: "text", message: "GitHub Enterprise URL/domain (blank for github.com)" });
  if (domain !== "") throw new Error(`expected github.com, got ${domain}`);
  interaction.notify({ type: "device_code", userCode: "8F3K-Q2WD", verificationUri: "https://example.invalid/login/device", expiresInSeconds: 900 });
  while (!fs.existsSync(path.join(control, "approved"))) {
    if (interaction.signal.aborted) throw new Error("Login cancelled");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return oauthCredential();
}

async function keyLogin(interaction) {
  const key = await interaction.prompt({ type: "secret", message: "Enter DeepSeek API key" });
  return { type: "api_key", key };
}

export class ModelRuntime {
  constructor(options) {
    this.authPath = options.authPath;
  }

  static async create(options = {}) {
    return new ModelRuntime(options);
  }

  getProvider(id) {
    return providers[id];
  }

  getModels(id) {
    return models[id] ?? [];
  }

  async login(providerId, type, interaction) {
    let credential;
    if (providerId === "anthropic" || providerId === "openai-codex") {
      if (providerId === "openai-codex") {
        const method = await interaction.prompt({
          type: "select",
          message: "Select OpenAI Codex login method:",
          options: [
            { id: "browser", label: "Browser login (default)" },
            { id: "device_code", label: "Device code login (headless)" },
          ],
        });
        if (method !== "browser") throw new Error(`expected the browser, got ${method}`);
      }
      credential = await browserLogin(interaction);
    } else if (providerId === "github-copilot") {
      credential = await deviceLogin(interaction);
    } else if (providerId === "deepseek" && type === "api_key") {
      credential = await keyLogin(interaction);
    } else {
      throw new Error(`no ${type} login for ${providerId}`);
    }
    const auth = readAuth(this.authPath);
    auth[providerId] = credential;
    writeAuth(this.authPath, auth);
    return credential;
  }

  async logout(providerId) {
    const auth = readAuth(this.authPath);
    delete auth[providerId];
    writeAuth(this.authPath, auth);
  }

  async completeSimple(model, _context, options) {
    if (options.apiKey === "sk-fake-good-key-0001") return { role: "assistant", stopReason: "stop", content: [] };
    return { role: "assistant", stopReason: "error", errorMessage: `401 {"error":{"message":"invalid api key ${options.apiKey}"}}` };
  }
}
