// Subscription usage for Settings ▸ Models ▸ Sign-in: Anthropic's and OpenAI Codex's limit windows,
// read from their own usage endpoints with the signed-in token. A provider extension like any
// other (the "shepherd:usage" convention in shepherd-sign-in.mjs), shipped with Shepherd and
// switched in Settings ▸ Tools ▸ Built in. Only the sign-in bridge loads it, with
// SHEPHERD_USAGE_EXTENSION=1; anywhere else it does nothing.
//
// Read-only: a token that has expired is skipped, never refreshed here (pi owns refreshing, and the
// bridge refreshes the active one as a request would). Every failure is "no reading".

const TIMEOUT_MS = 8000;

/** A live OAuth token, or undefined. `expires` is in milliseconds. */
export function liveToken(credential, now = Date.now()) {
  if (credential?.type !== "oauth" || typeof credential.access !== "string" || !credential.access) return undefined;
  if (typeof credential.expires === "number" && credential.expires <= now) return undefined;
  return credential.access;
}

async function getJSON(url, headers) {
  try {
    const response = await fetch(url, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
    return response.ok ? await response.json() : undefined;
  } catch {
    return undefined;
  }
}

/** "5-hour", "Week", "3-day" for a window of that many seconds. */
export function windowName(seconds) {
  const hours = Math.round(seconds / 3600);
  if (hours === 24 * 7) return "Week";
  if (hours >= 24 && hours % 24 === 0) return `${hours / 24}-day`;
  return `${hours}-hour`;
}

/** Anthropic's windows: `utilization` 0–100 and an ISO `resets_at`; a window that is null is left out. */
export function anthropicWindows(body) {
  const names = [["five_hour", "5-hour"], ["seven_day", "Week"], ["seven_day_opus", "Week, Opus"], ["seven_day_sonnet", "Week, Sonnet"]];
  return names.flatMap(([key, name]) => {
    const window = body?.[key];
    if (!window || typeof window.utilization !== "number") return [];
    const resets = typeof window.resets_at === "string" ? Date.parse(window.resets_at) : NaN;
    return [{ name, usedPercent: window.utilization, ...(Number.isFinite(resets) ? { resetsAt: resets } : {}) }];
  });
}

/** OpenAI Codex's windows: `used_percent`, named by `limit_window_seconds`, `reset_at` in seconds. */
export function codexWindows(body) {
  const limit = body?.rate_limit;
  return ["primary_window", "secondary_window"].flatMap(key => {
    const window = limit?.[key];
    if (!window || typeof window.used_percent !== "number") return [];
    return [{
      name: windowName(Number(window.limit_window_seconds) || 0),
      usedPercent: window.used_percent,
      ...(typeof window.reset_at === "number" ? { resetsAt: window.reset_at * 1000 } : {}),
    }];
  });
}

/** An Anthropic profile's email: its token doesn't carry one. */
export function profileEmail(body) {
  const account = body?.account;
  return typeof account?.email === "string" ? account.email : typeof account?.email_address === "string" ? account.email_address : undefined;
}

export const hooks = {
  async anthropic({ credential }) {
    const token = liveToken(credential);
    if (!token) return undefined;
    const headers = { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" };
    const usage = await getJSON("https://api.anthropic.com/api/oauth/usage", headers);
    if (!usage) return undefined;
    const profile = await getJSON("https://api.anthropic.com/api/oauth/profile", headers);
    return { windows: anthropicWindows(usage), email: profileEmail(profile) };
  },
  async "openai-codex"({ credential }) {
    const token = liveToken(credential);
    if (!token || typeof credential.accountId !== "string") return undefined;
    const usage = await getJSON("https://chatgpt.com/backend-api/wham/usage",
      { Authorization: `Bearer ${token}`, "ChatGPT-Account-Id": credential.accountId });
    return usage && { windows: codexWindows(usage) };
  },
};

export default function shepherdUsage(pi) {
  if (process.env.SHEPHERD_USAGE_EXTENSION !== "1") return;
  try {
    for (const [provider, usage] of Object.entries(hooks)) pi.events.emit("shepherd:usage", { provider, usage });
  } catch {
    // Never into pi.
  }
}
