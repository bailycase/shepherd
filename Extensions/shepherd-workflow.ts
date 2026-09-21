// @ts-nocheck -- Pi loads this module through jiti.
import { Worker } from "node:worker_threads";

// The VM receives only strings, never worker objects, callbacks, promises or errors.
// This restricts the scripting API; neither node:vm nor a Worker is an OS sandbox.
function workflowWorker() {
  const { parentPort, workerData } = require("node:worker_threads");
  const vm = require("node:vm");
  const context = vm.createContext(Object.create(null), { codeGeneration: { strings: false, wasm: false } });
  const bootstrap = `
    "use strict";
    const pending = new Map();
    const outbox = [];
    let sequence = 0, outcome;
    const encode = JSON.stringify.bind(JSON);
    function request(method, args) {
      if (sequence >= 512) return Promise.reject(new Error("Workflow call limit exceeded"));
      if (pending.size >= 64) return Promise.reject(new Error("Workflow request queue is full"));
      const id = ++sequence;
      const text = encode({ id, method, args });
      if (text.length > 65536) return Promise.reject(new Error("Workflow request exceeds 64 KiB"));
      outbox.push(text);
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    }
    const runs = Object.freeze({
      run: (key, params) => request("run", { key, params }),
      all: (items) => request("all", { items }),
      steer: (key, message, options = {}) => request("steer", { key, message, options }),
      status: (key) => request("status", { key }),
      cancel: (key) => request("cancel", { key })
    });
    const state = ${workerData.stateEnabled ? 'Object.freeze({ get: (key) => request("state.get", { key }), set: (key, value) => request("state.set", { key, value }) })' : 'undefined'};
    function receive() {
      const message = JSON.parse(incoming);
      const entry = pending.get(message.id);
      if (!entry) return;
      pending.delete(message.id);
      message.error === undefined ? entry.resolve(message.value) : entry.reject(new Error(message.error));
    }
    function drain() {
      const messages = outbox.splice(0);
      return encode({ messages, outcome });
    }
  `;
  const run = (code) => new vm.Script(code).runInContext(context, { timeout: 100 });
  try {
    run(bootstrap);
    run(`(async () => {\n${workerData.script}\n})().then(value => {
      if (pending.size) throw new Error("Workflow returned with pending calls; await or return every runs/state call");
      const text = encode(value === undefined ? null : value);
      if (text.length > 65536) throw new Error("Workflow result exceeds 64 KiB");
      outcome = { value: JSON.parse(text) };
    }).catch(error => { outcome = { error: String(error?.message || error).slice(0, 16384) }; }); void 0;`);
    const flush = () => {
      try {
        const text = run("drain()");
        if (typeof text !== "string" || text.length > 1024 * 1024) throw Error("Invalid workflow output");
        const { messages, outcome } = JSON.parse(text);
        for (const message of messages) parentPort.postMessage({ type: "call", text: message });
        if (outcome) { clearInterval(timer); parentPort.postMessage({ type: "done", text: JSON.stringify(outcome) }); }
      } catch (error) { clearInterval(timer); parentPort.postMessage({ type: "done", text: JSON.stringify({ error: "Workflow VM execution failed or exceeded its synchronous limit" }) }); }
    };
    parentPort.on("message", (text) => {
      try { context.incoming = text; run("receive(); void 0"); delete context.incoming; }
      catch (error) { parentPort.postMessage({ type: "done", text: JSON.stringify({ error: "Workflow VM execution failed or exceeded its synchronous limit" }) }); }
    });
    const timer = setInterval(flush, 10);
  } catch (error) { parentPort.postMessage({ type: "done", text: JSON.stringify({ error: "Workflow VM execution failed or exceeded its synchronous limit" }) }); }
}

export async function executeWorkflow(script, call, { signal, timeoutMs = 30 * 60 * 1000, stateEnabled = false } = {}) {
  signal?.throwIfAborted();
  const worker = new Worker(`(${workflowWorker.toString()})()`, { eval: true, workerData: { script, stateEnabled }, env: {},
    resourceLimits: { maxOldGenerationSizeMb: 64, maxYoungGenerationSizeMb: 16, stackSizeMb: 4 } });
  let timer, abort, ended = false, count = 0;
  try {
    return await new Promise((resolve, reject) => {
      const fail = (error) => { ended = true; reject(error); };
      abort = () => fail(Error("Workflow cancelled"));
      signal?.addEventListener("abort", abort, { once: true });
      if (signal?.aborted) { abort(); return; }
      timer = setTimeout(() => fail(Error("Workflow deadline exceeded")), timeoutMs);
      worker.on("error", fail);
      worker.on("exit", (code) => { if (!ended) fail(Error(`Workflow worker exited (${code})`)); });
      worker.on("message", async (message) => {
        if (ended) return;
        try {
          if (typeof message.text !== "string" || Buffer.byteLength(message.text) > 128 * 1024) throw Error("Invalid workflow frame");
          const data = JSON.parse(message.text);
          if (message.type === "done") { ended = true; data.error === undefined ? resolve(data.value) : reject(Error(data.error)); return; }
          if (message.type !== "call" || ++count > 512) throw Error("Workflow call limit exceeded");
          let reply;
          try { reply = { id: data.id, value: await call(data.method, data.args) }; }
          catch (error) { reply = { id: data.id, error: String(error.message).slice(0, 16384) }; }
          const text = JSON.stringify(reply);
          if (Buffer.byteLength(text) > 512 * 1024) throw Error("Workflow response exceeds 512 KiB");
          if (!ended) worker.postMessage(text);
        } catch (error) { fail(error); }
      });
    });
  } finally {
    ended = true; clearTimeout(timer); signal?.removeEventListener("abort", abort);
    await worker.terminate();
  }
}
