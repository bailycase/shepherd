// Shepherd: ends a model request that goes quiet. pi's HTTP idle timeout counts bytes, so a provider that
// keeps a stalled response open with keep-alives (Anthropic's `ping` events) never trips it and the turn
// waits forever. This counts pi's own stream events instead, and after `options.timeoutMs` without one it
// aborts the request and ends the stream with an error ("timed out"), which pi's automatic retry
// already handles. A timeout of 0 (`httpIdleTimeoutMs: "disabled"`) leaves the stream alone.
const IDLE = Symbol("idle");
const MAX_TIMER_MS = 2147483647;

function errorMessage(model, partial, text) {
    const base = partial ?? {
        role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        timestamp: Date.now(),
    };
    const content = (base.content ?? []).map(({ index, partialJson, ...block }) => block);
    return { ...base, content, stopReason: "error", errorMessage: text };
}

export function withStreamIdleTimeout(model, options, start) {
    const timeoutMs = options?.timeoutMs;
    if (!(timeoutMs > 0) || timeoutMs >= MAX_TIMER_MS) return start(options);
    const request = new AbortController();
    const outer = options.signal;
    const relay = () => request.abort(outer.reason);
    if (outer?.aborted) relay();
    else outer?.addEventListener("abort", relay, { once: true });
    const source = start({ ...options, signal: request.signal });
    let timedOut;
    async function* events() {
        const iterator = source[Symbol.asyncIterator]();
        let partial;
        try {
            for (;;) {
                let timer;
                const idle = new Promise((resolve) => { timer = setTimeout(resolve, timeoutMs, IDLE); });
                let step;
                try { step = await Promise.race([iterator.next(), idle]); } finally { clearTimeout(timer); }
                if (step === IDLE) {
                    request.abort();
                    timedOut = errorMessage(model, partial, `Request timed out: the model sent nothing for ${Math.round(timeoutMs / 1000)}s`);
                    yield { type: "error", reason: "error", error: timedOut };
                    return;
                }
                if (step.done) return;
                partial = step.value.partial ?? partial;
                yield step.value;
            }
        } finally {
            outer?.removeEventListener("abort", relay);
        }
    }
    return { [Symbol.asyncIterator]: events, result: async () => timedOut ?? source.result() };
}
