// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd theme extension: keeps pi's TUI palette synchronized with the active
// Shepherd app theme. Inert without SHEPHERD_PI_THEME_PATH; every failure is
// swallowed so theming can never break pi or keep its process alive.
import * as fs from "node:fs";
import {
  Theme,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const BACKGROUND_KEYS = new Set([
  "selectedBg",
  "scrollbarThumb",
  "searchMatchBg",
  "userMessageBg",
  "customMessageBg",
  "toolPendingBg",
  "toolSuccessBg",
  "toolErrorBg",
]);

type ColorValue = string | number;
interface ThemeDocument {
  name: string;
  colors: Record<string, ColorValue>;
}

export default function shepherdTheme(pi: ExtensionAPI) {
  const themePath = process.env.SHEPHERD_PI_THEME_PATH ?? "";
  if (!themePath) return;

  let listener: ((current: fs.Stats, previous: fs.Stats) => void) | undefined;

  function applyTheme(ctx: ExtensionContext) {
    if (ctx.mode !== "tui") return;
    try {
      const document = JSON.parse(fs.readFileSync(themePath, "utf8")) as ThemeDocument;
      if (!document.name || !document.colors) return;

      const foregrounds: Record<string, ColorValue> = {};
      const backgrounds: Record<string, ColorValue> = {};
      for (const [key, value] of Object.entries(document.colors)) {
        (BACKGROUND_KEYS.has(key) ? backgrounds : foregrounds)[key] = value;
      }

      const theme = new Theme(
        foregrounds as any,
        backgrounds as any,
        // Shepherd's Ghostty surface is always truecolor, regardless of the
        // environment inherited by the app that launched this pi process.
        "truecolor",
        { name: document.name, sourcePath: themePath },
      );
      ctx.ui.setTheme(theme);
    } catch {
      // Keep the last valid theme while an atomic rewrite is in flight.
    }
  }

  function stopWatching() {
    if (!listener) return;
    try {
      fs.unwatchFile(themePath, listener);
    } catch { }
    listener = undefined;
  }

  pi.on("session_start", (_event, ctx) => {
    stopWatching();
    applyTheme(ctx);
    listener = (current, previous) => {
      if (current.mtimeMs === previous.mtimeMs && current.size === previous.size) return;
      applyTheme(ctx);
    };
    try {
      fs.watchFile(themePath, { interval: 250, persistent: false }, listener);
    } catch {
      listener = undefined;
    }
  });

  pi.on("session_shutdown", () => {
    stopWatching();
  });
}
