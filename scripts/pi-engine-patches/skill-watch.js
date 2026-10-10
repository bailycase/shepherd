// Shepherd: event-driven observation of skill sources, never a recursive repo/home watch.
import { watch, statSync, lstatSync, readlinkSync, realpathSync, readdirSync } from "node:fs";
import { resolve, dirname, basename, join, relative, sep } from "node:path";
import ignore from "ignore";
import { addSkillWatchIgnoreRules } from "./package-manager.js";

const ignoreFiles = new Set([".gitignore", ".ignore", ".fdignore"]);

export function watchSkillPaths(paths, changed, failed) {
    const watchers = new Map();
    let stopped = false;
    let pending;
    const stat = path => { try { return statSync(path); } catch { return undefined; } };
    // An independently supplied descendant remains a source even when discovery
    // under its ancestor stops at SKILL.md. Reconcile deduplicates shared watches.
    const roots = [...new Set(paths.map(path => resolve(path)))];
    const invalidate = () => {
        if (stopped || pending) return;
        // Coalesce one filesystem event batch, not a polling or refresh delay.
        pending = setImmediate(() => {
            pending = undefined;
            if (stopped) return;
            reconcile();
            changed();
        });
    };
    function reconcile() {
        const wanted = new Map();
        const seen = new Set();
        const visitedSources = new Set();
        function shallow(path, name) {
            const key = `parent:${path}`;
            if (!wanted.has(key)) wanted.set(key, { path, recursive: false, names: new Set() });
            wanted.get(key).names.add(name);
        }
        function source(path) {
            path = resolve(path);
            if (visitedSources.has(path)) return;
            visitedSources.add(path);
            // A symlink in an ancestor (for example .pi -> another folder) can be
            // retargeted without changing the watched directory's old inode.
            const ancestors = [];
            for (let parent = dirname(path); dirname(parent) !== parent; parent = dirname(parent)) ancestors.unshift(parent);
            for (const ancestor of ancestors) {
                try {
                    if (!lstatSync(ancestor).isSymbolicLink()) continue;
                    shallow(dirname(ancestor), basename(ancestor));
                    source(resolve(dirname(ancestor), readlinkSync(ancestor), relative(ancestor, path)));
                    return;
                } catch {}
            }
            // An absent source needs only its nearest existing ancestor and the next segment.
            let parent = dirname(path);
            while (!stat(parent)?.isDirectory() && dirname(parent) !== parent) parent = dirname(parent);
            if (stat(parent)?.isDirectory()) shallow(parent, relative(parent, path).split(sep)[0]);
            try {
                if (lstatSync(path).isSymbolicLink()) {
                    source(resolve(dirname(path), readlinkSync(path)));
                    return;
                }
            } catch {}
            const info = stat(path);
            if (!info) return;
            if (!info.isDirectory()) return; // its parent catches writes and atomic replacement
            let canonical;
            try { canonical = realpathSync(path); } catch { return; }
            if (seen.has(canonical)) return;
            seen.add(canonical);
            const ignores = ignore();
            wanted.set(`tree:${canonical}`, { path: canonical, recursive: true, ignores });
            if (canonical !== path) {
                // Watch target deletion/recreation independently of the link's own parent.
                let targetParent = dirname(canonical);
                shallow(targetParent, basename(canonical));
            }
            // Native recursive watching does not follow directory symlinks. Add their targets,
            // with canonical cycle detection, but traverse only a skill source's directories.
            function links(directory) {
                addSkillWatchIgnoreRules(ignores, directory, canonical);
                // Pi stops discovery at an included SKILL.md. Reference links in its
                // contents are not additional skill sources and must not be followed.
                const skill = join(directory, "SKILL.md");
                if (stat(skill)?.isFile() && !ignores.ignores(relative(canonical, skill))) return;
                let entries;
                try { entries = readdirSync(directory, { withFileTypes: true }); } catch { return; }
                for (const entry of entries) {
                    if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
                    const child = join(directory, entry.name);
                    const isDirectory = entry.isDirectory() || (entry.isSymbolicLink() && stat(child)?.isDirectory() !== false);
                    if (ignores.ignores(relative(canonical, child) + (isDirectory ? "/" : ""))) continue;
                    if (entry.isSymbolicLink()) {
                        source(child);
                    } else if (entry.isDirectory()) links(child);
                }
            }
            links(canonical);
        }
        for (const root of roots) source(root);
        for (const [key, entry] of watchers) {
            if (!wanted.has(key)) { entry.watcher.close(); watchers.delete(key); }
        }
        function discovers(spec, filename) {
            if (!filename) return true;
            const parts = String(filename).split(sep);
            if (ignoreFiles.has(parts.at(-1))) return true;
            const candidate = join(spec.path, String(filename));
            if (spec.ignores.ignores(String(filename) + (stat(candidate)?.isDirectory() ? "/" : ""))) return false;
            let directory = spec.path;
            for (let index = 0; index < parts.length; index++) {
                if (parts[index].startsWith(".") || parts[index] === "node_modules") return false;
                const skill = join(directory, "SKILL.md");
                if (stat(skill)?.isFile() && !spec.ignores.ignores(relative(spec.path, skill))) return index === parts.length - 1 && parts[index] === "SKILL.md";
                directory = join(directory, parts[index]);
            }
            return true;
        }
        for (const [key, spec] of wanted) {
            const info = stat(spec.path);
            spec.identity = `${info?.dev}:${info?.ino}`;
            const existing = watchers.get(key);
            if (existing?.spec.identity === spec.identity) { existing.spec = spec; continue; }
            if (existing) { existing.watcher.close(); watchers.delete(key); }
            try {
                const entry = { spec, watcher: undefined };
                entry.watcher = watch(spec.path, { recursive: spec.recursive, persistent: false }, (event, filename) => {
                    if (entry.spec.recursive ? discovers(entry.spec, filename) : !filename || entry.spec.names.has(String(filename))) {
                        if (event === "rename") { entry.watcher.close(); watchers.delete(key); }
                        invalidate();
                    }
                });
                entry.watcher.on("error", error => {
                    entry.watcher.close(); watchers.delete(key);
                    failed(error); // no polling fallback; another source event can re-establish it
                });
                watchers.set(key, entry);
            } catch (error) { failed(error); }
        }
    }
    reconcile();
    return () => {
        stopped = true;
        if (pending) clearImmediate(pending);
        for (const { watcher } of watchers.values()) watcher.close();
        watchers.clear();
    };
}
