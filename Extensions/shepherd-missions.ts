// @ts-nocheck -- Pi loads this module through jiti.
import * as fs from "node:fs";
import * as path from "node:path";
import { createHash, randomUUID } from "node:crypto";

// Separate from pi-subagents data. Records carry no executable configuration.
export function missionStore(root, cwd) {
  const project = fs.realpathSync(cwd);
  const dir = path.join(root, "missions", createHash("sha256").update(project).digest("hex"));
  const file = (id) => {
    if (typeof id !== "string" || !/^mission-[0-9a-f-]{36}$/.test(id)) throw Error("Invalid mission id");
    return path.join(dir, `${id}.json`);
  };
  const read = (id) => {
    const target = file(id);
    if (fs.statSync(target).size > 256 * 1024) throw Error("Mission exceeds 256 KiB");
    const record = JSON.parse(fs.readFileSync(target, "utf8"));
    if (record.id !== id || record.project !== project) throw Error("Mission project mismatch");
    return record;
  };
  function write(record) {
    const text = JSON.stringify(record);
    if (Buffer.byteLength(text) > 256 * 1024) throw Error("Mission exceeds 256 KiB");
    const target = file(record.id), tmp = `${target}.${randomUUID()}.tmp`;
    try { fs.writeFileSync(tmp, text, { mode: 0o600, flag: "wx" }); fs.renameSync(tmp, target); }
    finally { try { fs.unlinkSync(tmp); } catch {} }
    return record;
  }
  return {
    read,
    list() { return fs.existsSync(dir) ? fs.readdirSync(dir).filter((name) => /^mission-[0-9a-f-]{36}\.json$/.test(name)).sort().slice(-200).map((name) => read(name.slice(0, -5))) : []; },
    create(title, objective = title) {
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      return write({ id: `mission-${randomUUID()}`, project, title, objective, status: "planned", runs: [], attachments: [], state: {}, createdAt: Date.now(), updatedAt: Date.now() });
    },
    update(id, change) {
      // Synchronous read/modify/write is atomic within a parent; mkdir excludes other parents.
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      const lock = `${file(id)}.lock`;
      try { fs.mkdirSync(lock, { mode: 0o700 }); }
      catch (error) { if (error.code === "EEXIST") throw Error("Mission is locked; retry after the other writer finishes. Crash locks require manual verification."); throw error; }
      try { const record = read(id); change(record); record.updatedAt = Date.now(); return write(record); }
      finally { fs.rmdirSync(lock); }
    },
  };
}
