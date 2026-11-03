import test from "node:test";
import assert from "node:assert/strict";
import { StringDecoder } from "node:string_decoder";
import { textLines } from "../../Extensions/shepherd-lines.mjs";

for (const chunkSize of [1024, 65536, 8 * 1024 * 1024]) {
  test(`8 MiB framing scans/counts/joins only linear work at ${chunkSize} characters per chunk`, () => {
    const text = "a".repeat(8 * 1024 * 1024 - 1) + "\n";
    let scanned = 0, measured = 0, joined = 0, delivered = 0;
    const indexOf = String.prototype.indexOf, join = Array.prototype.join;
    const read = textLines(line => { delivered++; assert.equal(line.length, text.length - 1); }, {
      limit: text.length, measure: part => { measured += part.length; return Buffer.byteLength(part); },
    });
    try {
      String.prototype.indexOf = function (needle, start = 0) {
        const end = indexOf.call(this, needle, start);
        scanned += (end < 0 ? this.length : end + 1) - start;
        return end;
      };
      Array.prototype.join = function (separator) {
        joined += this.reduce((sum, part) => sum + part.length, 0);
        return join.call(this, separator);
      };
      for (let i = 0; i < text.length; i += chunkSize) read(text.slice(i, i + chunkSize));
    } finally {
      String.prototype.indexOf = indexOf; Array.prototype.join = join;
    }
    assert.equal(delivered, 1);
    assert.ok(scanned <= text.length, "scans stay within one pass");
    assert.ok(measured <= text.length - 1, "measurement stays within one pass");
    assert.ok(joined <= text.length - 1, "fragments are joined at most once");
  });
}

test("multiple records share a chunk without sharing the limit; CR and empty lines are untouched", () => {
  const lines = [];
  const read = textLines(line => lines.push(line), { limit: 4, onOverflow: () => assert.fail("per-record cap") });
  read("abc\n\n\r"); read("\nx\r\nz\ntail");
  assert.deepEqual(lines, ["abc", "", "\r", "x\r", "z"]);
});

test("the LF and CR count toward the exact character/byte cap and overflow fails once", () => {
  for (const [limit, measure] of [[4, text => text.length], [7, Buffer.byteLength]]) {
    const lines = []; let failures = 0;
    const read = textLines(line => lines.push(line), { limit, measure, onOverflow: () => failures++ });
    read("é"); read("😀"); read("\n");
    assert.deepEqual(lines, ["é😀"]);
    read("é😀\r"); read("\nignored\n"); read("\n");
    assert.equal(failures, 1);
    assert.deepEqual(lines, ["é😀"]);
  }
});

test("an unterminated oversized record fails immediately and never delivers later records", () => {
  let failures = 0;
  const read = textLines(() => assert.fail("oversized"), { limit: 3, onOverflow: () => failures++ });
  read("abc"); assert.equal(failures, 0);
  read("d"); assert.equal(failures, 1);
  read("\nok\n"); assert.equal(failures, 1);
});

test("a first-line consumer can stop on even an empty line, without parsing trailing records", () => {
  const lines = [];
  const read = textLines(line => { lines.push(line); return false; });
  read(""); read("\nother\n"); read("late\n");
  assert.deepEqual(lines, [""]);
});

test("the caller's streaming UTF-8 decoder survives every byte boundary; no EOF flush is invented", () => {
  const payload = Buffer.from(' {"text":"é😀雪"}\r\n\npartial');
  for (let split = 0; split <= payload.length; split++) {
    const decoder = new StringDecoder("utf8"), lines = [];
    const read = textLines(line => lines.push(line));
    read(decoder.write(payload.subarray(0, split)));
    read(decoder.write(payload.subarray(split)));
    assert.deepEqual(lines, [' {"text":"é😀雪"}\r', ""]);
  }
});
