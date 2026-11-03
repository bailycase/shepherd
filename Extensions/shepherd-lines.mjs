// Inert framing only: callers own UTF-8 decoding, JSON policy and connection lifetime.
// Scan/count new text once and join fragments only when LF completes a record. Limits include LF;
// CR and empty lines are passed through unchanged. Returning false stops this reader permanently.
export function textLines(onLine, { limit = Infinity, measure = text => text.length, onOverflow = () => {} } = {}) {
  let parts = [], size = 0, stopped = false;
  return text => {
    if (stopped) return;
    let start = 0;
    while (start < text.length) {
      const end = text.indexOf("\n", start);
      const part = text.slice(start, end < 0 ? text.length : end);
      size += measure(part) + (end < 0 ? 0 : 1);
      if (size > limit) {
        stopped = true; parts = []; size = 0;
        onOverflow();
        return;
      }
      parts.push(part);
      if (end < 0) return;
      const line = parts.join("");
      parts = []; size = 0;
      if (onLine(line) === false) { stopped = true; return; }
      start = end + 1;
    }
  };
}
