// @ts-nocheck -- Pi loads this module through jiti. Native commands never dispatch a parent prompt.
import { Input, Text, matchesKey, truncateToWidth } from "@earendil-works/pi-tui";
import { cleanText, clipColumns, duration, endTime, readTranscript, TranscriptViewport, wrapColumns, displayWidth, identityLine, composerLabel, repliesByResume, statusColor, stopScope } from "./shepherd-inspect.mjs";

export const commandNames = ["subagents", "run", "subagents-fleet", "subagents-stop", "subagents-models", "subagents-doctor", "missions", "workflows"];
export function nativeCommandNames(commands, tools) {
  const occupied = new Set(commands.map((c) => c.name.split(":")[0]));
  const legacy = tools.some((t) => t.name === "subagent" || /(?:^|[/:])pi-subagents(?:[@/]|$)/.test(t.sourceInfo?.source ?? ""));
  const collisions = legacy || commandNames.some((name) => occupied.has(name));
  return Object.fromEntries(commandNames.map((name) => {
    let chosen = collisions ? `shepherd-${name}` : name;
    while (occupied.has(chosen)) chosen = `shepherd-${chosen}`;
    return [name, chosen];
  }));
}
export function parseRunCommand(args) {
  let text = args.trim(), background = false, fork = false;
  for (;;) {
    const flag = text.match(/(?:^|\s)(--bg|--fork)$/);
    if (!flag) break;
    if (flag[1] === "--bg") background = true; else fork = true;
    text = text.slice(0, flag.index).trimEnd();
  }
  const match = text.match(/^(\S+)(?:\s+([\s\S]*))?$/);
  if (match?.[1].includes("[") || match?.[1].includes("]") || /^\s*\[[^\]]*=/.test(match?.[2] ?? "")) throw Error("Inline [config] is unsupported by native /run. Put supported settings in an agent file.");
  if (!match?.[2]?.trim()) throw Error("Usage: /run <agent> <task...> [--bg] [--fork]");
  if (match[1].startsWith("--")) throw Error("Specify an agent before the task; flags belong at the end.");
  if (match[1].length > 80 || match[2].length > 16384) throw Error("Agent or task exceeds the native input limit");
  const params = { agent: match[1], task: match[2].trim(), ...(fork ? { context: "fork" } : {}) };
  return { task: params.task, async: background, workflowScript: `return await runs.run("run", ${JSON.stringify(params)});` };
}
export function orderedFleet(runs) {
  const rank = (r) => r.needsReply ? 0 : ["running", "queued"].includes(r.state) ? 1 : r.state === "failed" ? 2 : 3;
  return [...runs].sort((a, b) => rank(a) - rank(b) || (b.startedAt ?? 0) - (a.startedAt ?? 0) || a.id.localeCompare(b.id));
}
export function fleetRow(run, width, selected, now = Date.now()) {
  const state = run.needsReply ? "needs reply" : run.state;
  const age = duration(run.startedAt, endTime(run), now) || "?";
  const taskWidth = Math.max(1, width - 42);
  const task = clipColumns(run.task, taskWidth);
  return clipColumns(`${selected ? ">" : " "} ● ${state.padEnd(11)} | ${task}${" ".repeat(Math.max(0, taskWidth - displayWidth(task)))} | ${(age === "duration unavailable" ? "?" : age).padStart(7)} | ${run.currentTool ?? run.latestTool ?? ""}`, width);
}
const oneArgument = (args) => {
  const words = args.trim().split(/\s+/).filter(Boolean);
  if (words.length > 1) throw Error("Expected one optional name or id");
  return words[0];
};
const profileNamed = (agents, name) => {
  const exact = agents.filter((a) => a.name === name);
  const matches = exact.length ? exact : agents.filter((a) => a.aliases?.includes(name));
  if (matches.length !== 1) throw Error(`Unknown or ambiguous agent: ${name}`);
  return matches[0];
};
const diagnosticLines = (catalog) => catalog.diagnostics.map((d) => `${d.name ?? d.source}: ${d.error ?? d.warning}${d.filePath ? ` · ${d.filePath}` : ""}`);
export function profileLines(profile, defaults) {
  return [profile.name, profile.description ?? "", `source · ${profile.source}${profile.filePath ? ` · ${profile.filePath}` : ""}`,
    `model · ${profile.model ?? defaults.model ?? "inherit parent"}`, `thinking · ${profile.thinking ?? defaults.thinking ?? "inherit parent"}`,
    `context · ${profile.context ?? defaults.context}`, `tools · ${Array.isArray(profile.tools) ? profile.tools.join(", ") || "none" : profile.tools ?? "Pi builtin defaults"}`,
    ...(profile.disabled ? ["disabled"] : []), ...(profile.error ? [`error · ${profile.error}`] : []), "", profile.prompt ?? ""].map(cleanText);
}

// Per-child viewport and drafts survive selection changes and attention sorting.
export class FleetView {
  selectedID;
  views = new Map();
  drafts = new Map();
  input = new Input();
  composing = false;
  mode = "steer";
  expanded = false;
  showPath = false;
  confirming = undefined;
  notice = "";
  busy = false;
  closed = false;
  _focused = false;
  constructor(runtime, tui, theme, keys, done, id) {
    Object.assign(this, { runtime, tui, theme, keys, done, selectedID: id });
    this.input.onSubmit = () => { void this.submit(); };
  }
  get focused() { return this._focused; }
  set focused(value) { this._focused = value; this.input.focused = value && this.composing; }
  dispose() { this.closed = true; }
  invalidate() { this.input.invalidate(); }
  rows() {
    const rows = orderedFleet(this.runtime.list());
    if (!rows.some((r) => r.id === this.selectedID)) this.selectedID = rows[0]?.id;
    return rows;
  }
  view() {
    if (!this.views.has(this.selectedID)) this.views.set(this.selectedID, new TranscriptViewport());
    return this.views.get(this.selectedID);
  }
  async submit() {
    if (this.busy || !this.selectedID || !this.input.getValue().trim()) return;
    const id = this.selectedID, text = this.input.getValue().trim(), mode = this.mode;
    if (text.length > 16384) { this.notice = "message exceeds 16 KiB character limit"; this.tui.requestRender(); return; }
    this.busy = true;
    try {
      const receipt = await this.runtime.send(id, text, mode);
      this.notice = `${receipt.delivery} · ${receipt.mode}`;
      this.input.setValue(""); this.drafts.delete(id); this.composing = false; this.focused = this._focused;
    } catch (error) { this.notice = `message failed · ${error.message}`; }
    finally { this.busy = false; if (!this.closed) this.tui.requestRender(); }
  }
  async stop(id) {
    this.busy = true; this.confirming = undefined; this.notice = `stopping ${id}`;
    this.tui.requestRender();
    try { const receipt = await this.runtime.stop(id); this.notice = `${receipt.id} · ${receipt.state}`; }
    catch (error) { this.notice = `stop failed · ${error.message}`; }
    finally { this.busy = false; if (!this.closed) this.tui.requestRender(); }
  }
  handleInput(data) {
    const cancel = this.keys.matches(data, "tui.select.cancel");
    if (matchesKey(data, "ctrl+c")) { this.done(); return; }
    if (this.confirming) {
      if (data === "y" && !this.busy) void this.stop(this.confirming);
      else if (cancel || data === "n") this.confirming = undefined;
    } else if (this.composing) {
      if (cancel && !this.busy) {
        this.drafts.set(this.selectedID, { text: this.input.getValue(), mode: this.mode });
        this.composing = false; this.focused = this._focused;
      } else if (this.keys.matches(data, "tui.input.tab") && !repliesByResume(this.rows().find((r) => r.id === this.selectedID))) this.mode = this.mode === "steer" ? "followUp" : "steer";
      else if (!this.busy && this.keys.matches(data, "tui.input.submit")) void this.submit();
      else if (!this.busy) this.input.handleInput(data);
    } else if (cancel || data === "q") this.done();
    else if (this.keys.matches(data, "tui.select.up") || this.keys.matches(data, "tui.select.down") || data === "j" || data === "k") {
      const rows = this.rows(), at = rows.findIndex((r) => r.id === this.selectedID);
      const delta = data === "k" || this.keys.matches(data, "tui.select.up") ? -1 : 1;
      this.selectedID = rows[Math.max(0, Math.min(rows.length - 1, at + delta))]?.id;
      this.notice = "";
    } else if (matchesKey(data, "pageUp")) this.view().scroll(-this.view().height);
    else if (matchesKey(data, "pageDown")) this.view().scroll(this.view().height);
    else if (matchesKey(data, "end")) this.view().follow();
    else if (data === "p") { this.showPath = !this.showPath; this.view().follow(); }
    else if (data === "e") { this.expanded = !this.expanded; this.view().follow(); }
    else if (data === "s" && this.selectedID) {
      const draft = this.drafts.get(this.selectedID);
      this.mode = draft?.mode ?? "steer"; this.input.setValue(draft?.text ?? "");
      this.composing = true; this.focused = this._focused;
    } else if (data === "x" && this.selectedID && !this.busy) this.confirming = this.selectedID;
    this.tui.requestRender();
  }
  render(width) {
    const rows = this.rows(), selected = rows.find((r) => r.id === this.selectedID);
    const height = Math.max(8, Math.floor((this.tui.terminal.rows || 30) * 0.85));
    const listSize = Math.min(rows.length, Math.max(1, Math.min(6, Math.floor(height / 4))));
    const at = rows.findIndex((r) => r.id === this.selectedID), first = Math.max(0, Math.min(rows.length - listSize, at - Math.floor(listSize / 2)));
    const footer = [];
    if (this.notice) footer.push(...wrapColumns(this.notice, width));
    if (this.confirming) {
      const target = rows.find((r) => r.id === this.confirming);
      footer.push(...wrapColumns(`stop child ${this.confirming}?`, width), ...wrapColumns(stopScope(target), width),
        `y confirm · ${this.hint("tui.select.cancel")} cancel`);
    } else if (this.composing) {
      footer.push(composerLabel(selected, this.mode, width));
      if (this.busy) footer.push("awaiting acknowledgement");
      footer.push(...this.input.render(width));
      footer.push(...wrapColumns(`${this.hint("tui.input.submit")} send${repliesByResume(selected) ? "" : ` · ${this.hint("tui.input.tab")} mode`} · ${this.hint("tui.select.cancel")} keep draft`, width));
    } else footer.push(...wrapColumns(`${this.hint("tui.select.up")}/${this.hint("tui.select.down")} select · pgup/pgdn scroll · end follow`, width),
      ...wrapColumns(`e tools · p file · s message · x stop · ${this.hint("tui.select.cancel")} close`, width));
    const visibleRows = rows.slice(first, first + listSize);
    const frame = [`NATIVE SUBAGENTS · ${rows.length} retained`,
      ...(rows.length ? visibleRows.map((r) => fleetRow(r, width, r.id === this.selectedID)) : ["no native children yet"]),
      "─".repeat(width)];
    if (selected) {
      frame.push(identityLine(selected, width));
      if (selected.needsReply) frame.push(...wrapColumns(`needs parent reply · ${selected.output ?? ""}`, width));
      if (selected.error) frame.push(...wrapColumns(`error · ${selected.error}`, width));
      const transcript = readTranscript(selected.sessionFile, width, this.expanded);
      if (transcript.omitted) frame.push(...wrapColumns(transcript.omitted, width));
      const view = this.view();
      const detail = this.showPath ? wrapColumns(`full transcript: ${selected.sessionFile ?? "unavailable"}`, width).map((text, i) => ({key:`path:${i}`,text})) : transcript.lines;
      const body = view.update(detail, Math.max(1, height - frame.length - footer.length - 1));
      frame.push(...body);
      while (frame.length < height - footer.length - 1) frame.push("");
      frame.push(`${view.label} · p ${this.showPath ? "transcript" : "saved file path"}`);
    }
    if (frame.length > height - footer.length) frame.splice(Math.max(1, height - footer.length));
    const bodyHeight = frame.length;
    frame.push(...footer);
    return frame.slice(0, height).map((line, i) => {
      // Input owns its cursor marker; sanitize everything else before styling.
      const text = truncateToWidth(i < bodyHeight ? cleanText(line).replace(/\n/g, " ") : line, width);
      const run = i > 0 && i <= visibleRows.length && i < bodyHeight ? visibleRows[i - 1] : undefined;
      if (!run) return this.theme.fg("text", text);
      const dot = text.indexOf("●");
      return dot < 0 ? this.theme.fg("text", text) : this.theme.fg("text", text.slice(0, dot)) + this.theme.fg(statusColor(run), "●") + this.theme.fg("text", text.slice(dot + 1));
    });
  }
  hint(id) { return this.keys.getKeys(id).join("/"); }
}

export function registerNativeCommands(pi, runtime) {
  const names = nativeCommandNames(pi.getCommands(), pi.getAllTools());
  const aliasNote = names.run !== "run" ? `command collision detected · native commands use /${names.run} and /${names["subagents-fleet"]}; existing commands are unchanged` : "native command names available without aliases";
  pi.registerEntryRenderer("shepherd-native-report", (entry) => new Text(cleanText(entry.data.text), 0, 0));
  const report = (ctx, text) => {
    text = cleanText(text);
    pi.appendEntry("shepherd-native-report", { text });
    if (ctx.mode !== "tui") {
      if (ctx.hasUI) ctx.ui.notify(text, "info");
      else pi.sendMessage({ customType: "shepherd-native-report", content: text, display: true }, { triggerTurn: false });
    }
  };
  const register = (name, handler) => pi.registerCommand(names[name], {
    description: `Native ${name} · ${name === "run" ? "launch child workflow" : "inspect owned runtime"}`,
    handler: async (args, ctx) => { try { await handler(args, ctx); } catch (error) { report(ctx, `error · ${error.message}`); } },
  });
  register("subagents", async (args, ctx) => {
    const catalog = runtime.catalog(ctx); let name = oneArgument(args);
    if (!name && !catalog.agents.length) { report(ctx, ["no native agents", ...diagnosticLines(catalog)].join("\n")); return; }
    if (!name && ctx.mode === "tui") name = await ctx.ui.select("native agents · read only", catalog.agents.map((a) => a.name));
    if (name) report(ctx, [...profileLines(profileNamed(catalog.agents, name), runtime.defaults), ...diagnosticLines(catalog)].join("\n"));
    else if (ctx.mode !== "tui") report(ctx, [...catalog.agents.map((a) => `${a.name} · ${a.source} · ${a.error ?? a.description ?? ""}`), ...diagnosticLines(catalog)].join("\n") || "no native agents");
  });
  register("run", async (args, ctx) => {
    const params = parseRunCommand(args);
    const value = await runtime.workflow(params, ctx, (value) => { try { report(ctx, `workflow ${value.id} · ${value.state}\n${value.error ?? JSON.stringify(value.output) ?? ""}`); } catch { /* Workflow status remains retrievable. */ } });
    report(ctx, `workflow ${value.id} · ${value.state}${params.async ? ` · /${names.workflows} ${value.id}` : `\n${value.error ?? JSON.stringify(value.output) ?? ""}`}`);
  });
  let overlayOpen = false;
  register("subagents-fleet", async (args, ctx) => {
    const id = oneArgument(args);
    if (id) runtime.get(id);
    if (ctx.mode !== "tui") { report(ctx, id ? JSON.stringify(runtime.get(id), null, 2) : orderedFleet(runtime.list()).map((r) => `${r.id}\n${fleetRow(r, 120, false)}`).join("\n") || "no native children yet"); return; }
    if (overlayOpen) { ctx.ui.notify("native fleet is already open", "info"); return; }
    overlayOpen = true; let timer, view;
    try {
      await ctx.ui.custom((tui, theme, keys, done) => {
        view = new FleetView(runtime, tui, theme, keys, done, id);
        timer = setInterval(() => tui.requestRender(), 1000); timer.unref();
        return view;
      }, { overlay: true, overlayOptions: { width: "95%", maxHeight: "85%", anchor: "center" } });
    } finally { clearInterval(timer); view?.dispose(); overlayOpen = false; }
  });
  register("subagents-stop", async (args, ctx) => {
    let id = oneArgument(args);
    const active = runtime.list().filter((r) => ["running", "queued"].includes(r.state));
    if (id) runtime.get(id);
    if (!ctx.hasUI) { report(ctx, `stop requires interactive confirmation; no child stopped\n${active.map((r) => `${r.id} · ${r.task}`).join("\n")}`); return; }
    if (!id) {
      if (!active.length) { report(ctx, "no active native children"); return; }
      const choices = active.map((r) => `${r.id} · ${cleanText(r.task)}`);
      const choice = await ctx.ui.select("stop one native child", choices);
      id = active[choices.indexOf(choice)]?.id;
    }
    if (id && await ctx.ui.confirm("stop native child", `${id}\n${cleanText(runtime.get(id).task)}\n${stopScope(runtime.get(id))}`)) {
      const receipt = await runtime.stop(id); report(ctx, `${receipt.id} · ${receipt.state}`);
    }
  });
  register("subagents-models", (args, ctx) => {
    const name = oneArgument(args), catalog = runtime.catalog(ctx);
    const profiles = name ? [profileNamed(catalog.agents, name)] : catalog.agents;
    report(ctx, ["native models · local catalog only · isolated child verifies availability at launch", ...profiles.map((p) => {
      try { const model = runtime.resolveModel(p, ctx); return `${p.name} · ${model.model.provider}/${model.model.id} · ${p.model ?? runtime.defaults.model ?? "inherit parent"}${p.error ? ` · error: ${p.error}` : ""}`; }
      catch (error) { return `${p.name} · error: ${error.message}`; }
    })].join("\n"));
  });
  register("subagents-doctor", (args, ctx) => {
    if (args.trim()) throw Error("Doctor takes no arguments");
    let diagnostics;
    try { diagnostics = diagnosticLines(runtime.catalog(ctx)); }
    catch (error) { diagnostics = [`discovery error · ${error.message}`]; }
    report(ctx, ["NATIVE SUBAGENTS", ...runtime.doctor(ctx), aliasNote, ...commandNames.map((n) => `/${names[n]}`), ...diagnostics].join("\n"));
  });
  register("missions", (args, ctx) => {
    const id = oneArgument(args), records = runtime.missions(id);
    report(ctx, id ? JSON.stringify(records, null, 2) : records.map((m) => `${m.id} · ${m.status} · ${m.title}`).join("\n") || "no native missions · records do not control processes");
  });
  register("workflows", (args, ctx) => {
    const id = oneArgument(args), records = runtime.workflows(id);
    report(ctx, id ? JSON.stringify(records, null, 2) : records.map((w) => `${w.id} · ${w.state} · ${w.children.length} children${w.error ? ` · ${w.error}` : ""}`).join("\n") || "no retained workflows · previous workflows are not replayed");
  });
  return names;
}
