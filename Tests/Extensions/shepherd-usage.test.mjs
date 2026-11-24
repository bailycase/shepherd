// Shepherd's bundled usage extension: Anthropic's and OpenAI Codex's limit windows from their usage
// endpoints, asked only with a live token. Ported from the Swift reader it replaced; no network
// (fetch is a stub that answers by token).
import "./hermetic-env.mjs";
import test from "node:test";
import assert from "node:assert/strict";
import usage, { anthropicWindows, codexWindows, hooks, liveToken, profileEmail, windowName } from "../../Extensions/shepherd-usage.mjs";

const live = Date.now() + 3600000;
const oauth = (access, extra = {}) => ({ type: "oauth", access, refresh: "r", expires: live, ...extra });

function stubFetch(t, answer) {
  const seen = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    seen.push({ url: String(url), headers: init?.headers ?? {} });
    const body = answer(String(url), init?.headers ?? {});
    return { ok: body !== undefined, json: async () => body };
  };
  t.after(() => { globalThis.fetch = original; });
  return seen;
}

test("only a live OAuth token is used", () => {
  assert.equal(liveToken(oauth("tok")), "tok");
  assert.equal(liveToken(oauth("tok", { expires: 1 })), undefined);
  assert.equal(liveToken({ type: "api_key", key: "sk" }), undefined);
  assert.equal(liveToken(undefined), undefined);
});

test("Anthropic's windows skip nulls and parse resets", () => {
  const windows = anthropicWindows({
    five_hour: { utilization: 23.0, resets_at: "2025-10-13T19:00:00.123456+00:00" },
    seven_day: { utilization: 61, resets_at: "2025-10-16T07:00:00+00:00" },
    seven_day_opus: null, seven_day_sonnet: { utilization: null, resets_at: null },
  });
  assert.deepEqual(windows.map(w => w.name), ["5-hour", "Week"]);
  assert.deepEqual(windows.map(w => w.usedPercent), [23, 61]);
  assert.equal(windows[0].resetsAt, Date.parse("2025-10-13T19:00:00.123Z"));
});

test("Codex windows are named by their length", () => {
  assert.deepEqual(codexWindows({ rate_limit: {
    primary_window: { used_percent: 12, limit_window_seconds: 18000, reset_at: 1760382000 },
    secondary_window: { used_percent: 40, limit_window_seconds: 604800, reset_at: 1760900000 },
  } }), [{ name: "5-hour", usedPercent: 12, resetsAt: 1760382000000 }, { name: "Week", usedPercent: 40, resetsAt: 1760900000000 }]);
  assert.deepEqual(codexWindows({}), []);
  assert.equal(windowName(3 * 86400), "3-day");
});

test("an Anthropic profile gives the account's email", () => {
  assert.equal(profileEmail({ account: { email: "a@b.co" } }), "a@b.co");
  assert.equal(profileEmail({ account: { email_address: "a@b.co" } }), "a@b.co");
  assert.equal(profileEmail(undefined), undefined);
});

test("Anthropic is asked with the token and its beta header, and answers its email", async t => {
  const seen = stubFetch(t, url => url.endsWith("/usage") ? { five_hour: { utilization: 11 } } : { account: { email: "a@x.co" } });
  const answer = await hooks.anthropic({ credential: oauth("tok-a") });
  assert.deepEqual(answer, { windows: [{ name: "5-hour", usedPercent: 11 }], email: "a@x.co" });
  assert.equal(seen[0].url, "https://api.anthropic.com/api/oauth/usage");
  assert.equal(seen[0].headers.Authorization, "Bearer tok-a");
  assert.equal(seen[0].headers["anthropic-beta"], "oauth-2025-04-20");
  assert.equal(await hooks.anthropic({ credential: oauth("tok-a", { expires: 1 }) }), undefined);
  assert.equal(seen.length, 2, "an expired token asks nothing");
});

test("Codex needs its account id, and a failed request is no reading", async t => {
  const seen = stubFetch(t, (url, headers) => headers["ChatGPT-Account-Id"] === "acct"
    ? { rate_limit: { primary_window: { used_percent: 5, limit_window_seconds: 18000 } } } : undefined);
  assert.equal(await hooks["openai-codex"]({ credential: oauth("tok") }), undefined);
  assert.equal(seen.length, 0);
  assert.deepEqual(await hooks["openai-codex"]({ credential: oauth("tok", { accountId: "acct" }) }), { windows: [{ name: "5-hour", usedPercent: 5 }] });
  assert.equal(seen[0].url, "https://chatgpt.com/backend-api/wham/usage");
  assert.equal(await hooks["openai-codex"]({ credential: oauth("tok", { accountId: "other" }) }), undefined);
});

test("it reports nothing outside the sign-in bridge", () => {
  const emitted = [];
  const pi = { events: { emit: (channel, data) => emitted.push([channel, data.provider]) } };
  const before = process.env.SHEPHERD_USAGE_EXTENSION;
  delete process.env.SHEPHERD_USAGE_EXTENSION;
  usage(pi);
  assert.deepEqual(emitted, []);
  process.env.SHEPHERD_USAGE_EXTENSION = "1";
  try { usage(pi); } finally { if (before === undefined) delete process.env.SHEPHERD_USAGE_EXTENSION; else process.env.SHEPHERD_USAGE_EXTENSION = before; }
  assert.deepEqual(emitted, [["shepherd:usage", "anthropic"], ["shepherd:usage", "openai-codex"]]);
});
