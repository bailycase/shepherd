// Vendored from leohenon/pi-anthropic-oauth v0.3.4
// Revision: 44efe694a3e81a62742cdb3e7ba9da858e191a81
// MIT License
// 
// Copyright (c) 2026 Leo Henon
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
                                                                                     
                                                                         
import { randomUUID } from "node:crypto";
import { getClaudeCodeVersion } from "./version.js";

const CLAUDE_CODE_IDENTITY =
  "You are a Claude agent, built on Anthropic's Claude Agent SDK.";

/**
 * Anthropic's OAuth classifier rejects premium-model requests that do not
 * open with a Claude Code billing-header system block. The `cch` and
 * `cc_prompt_id` keys must be present, but their values are not validated,
 * and the block must not carry `cache_control`.
 */
export function buildClaudeCodeBillingBlock()                      {
  return {
    type: "text",
    text: `x-anthropic-billing-header: cc_version=${getClaudeCodeVersion()}; cc_entrypoint=cli; cch=00000; cc_prompt_id=${randomUUID()}`,
  };
}
const PI_REMOVAL_ANCHORS = [
  "pi-coding-agent",
  "@earendil-works/pi-coding-agent",
  "badlogic/pi-mono",
]         ;

export const PI_REWRITE_MODE_ENV = "PI_ANTHROPIC_OAUTH_REWRITE_MODE";
export const PI_REWRITE_PATTERN_ENV = "PI_ANTHROPIC_OAUTH_REWRITE_PATTERN";

                                                                                     

const DEFAULT_PI_REWRITE_MODE                = "aggressive";
const PI_REWRITE_PATTERN_SOURCES                                                   = {
  aggressive: String.raw`\b[Pp]i\b`,
  "path-safe": String.raw`(?<![/\\])\b[Pp]i\b`,
  "technical-safe": String.raw`(?<![/\\.@:_-])\b[Pp]i\b(?![/\\.@:_-])`,
};

const PI_REWRITE_MODES = new Set               ([
  "aggressive",
  "path-safe",
  "technical-safe",
  "custom",
]);

                            
               
                
                         
  

export function sanitizeSurrogates(text        )         {
  // Replace only *unpaired* surrogates: a high surrogate not followed by a low
  // surrogate, or a low surrogate not preceded by a high surrogate. Valid
  // surrogate pairs (non-BMP characters such as emoji) must pass through
  // untouched. Equivalent to String.prototype.toWellFormed(), which requires
  // Node 20+ while this package supports Node >=18.
  return text.replace(
    /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g,
    "\uFFFD",
  );
}

export function resolveCacheRetention(
  cacheRetention                            ,
  env              ,
)                 {
  if (cacheRetention) return cacheRetention;
  const envValue = env?.PI_CACHE_RETENTION ?? process.env.PI_CACHE_RETENTION;
  return envValue === "long" ? "long" : "short";
}

export function cacheControlFor(
  cacheRetention                ,
)                                    {
  if (cacheRetention === "none") return undefined;
  if (cacheRetention === "long") return { type: "ephemeral", ttl: "1h" };
  return { type: "ephemeral" };
}

export function buildAnthropicSystemPrompt(
  systemPrompt                    ,
  isOAuth         ,
  cacheRetention                 = "short",
)                                    {
  const blocks                        = [];

  if (isOAuth) {
    blocks.push(buildClaudeCodeBillingBlock());
    blocks.push({ type: "text", text: CLAUDE_CODE_IDENTITY });
  }

  const sanitized = systemPrompt
    ? sanitizeSystemText(sanitizeSurrogates(systemPrompt))
    : "";
  if (sanitized) {
    const cacheControl = cacheControlFor(cacheRetention);
    blocks.push({
      type: "text",
      text: sanitized,
      ...(cacheControl && { cache_control: cacheControl }),
    });
  }

  return blocks.length > 0 ? blocks : undefined;
}

export function sanitizeSystemText(
  text        ,
  env                    = process.env,
)         {
  const paragraphs = text.split(/\n\n+/);
  const filtered = paragraphs.filter((paragraph) => {
    const lower = paragraph.toLowerCase();
    if (lower.includes("you are pi")) return false;
    return !PI_REMOVAL_ANCHORS.some((anchor) => paragraph.includes(anchor));
  });

  const filteredText = filtered.join("\n\n");
  const rewritePattern = resolvePiRewritePattern(env);
  rejectZeroLengthMatches(rewritePattern, filteredText);

  return filteredText.replace(rewritePattern, "Claude Code").trim();
}

function resolvePiRewritePattern(env                   )         {
  const mode = parsePiRewriteMode(env[PI_REWRITE_MODE_ENV]);
  if (mode === "custom") return compileCustomPiRewritePattern(env[PI_REWRITE_PATTERN_ENV]);
  return new RegExp(PI_REWRITE_PATTERN_SOURCES[mode], "g");
}

function parsePiRewriteMode(value                    )                {
  if (!value?.trim()) return DEFAULT_PI_REWRITE_MODE;
  const mode = value.trim().toLowerCase();
  if (PI_REWRITE_MODES.has(mode                 )) return mode                 ;
  throw new Error(
    `Invalid ${PI_REWRITE_MODE_ENV}: ${value}. Expected one of ${Array.from(PI_REWRITE_MODES).join(", ")}.`,
  );
}

function compileCustomPiRewritePattern(value                    )         {
  const pattern = value?.trim();
  if (!pattern) {
    throw new Error(`${PI_REWRITE_PATTERN_ENV} must be set when ${PI_REWRITE_MODE_ENV}=custom.`);
  }

  const parsed = parseRegexLiteral(pattern) ?? { source: pattern, flags: "" };
  const flags = parsed.flags.includes("g") ? parsed.flags : `${parsed.flags}g`;
  let compiled        ;
  try {
    compiled = new RegExp(parsed.source, flags);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Invalid ${PI_REWRITE_PATTERN_ENV}: ${message}`);
  }

  rejectZeroLengthMatches(compiled, "");
  return compiled;
}

function rejectZeroLengthMatches(pattern        , text        )       {
  pattern.lastIndex = 0;
  let match                        ;
  while ((match = pattern.exec(text)) !== null) {
    if (match[0].length === 0) {
      pattern.lastIndex = 0;
      throw new Error(
        `Invalid ${PI_REWRITE_PATTERN_ENV}: the pattern can match without consuming text. Use (?!) to disable rewriting.`,
      );
    }
  }
  pattern.lastIndex = 0;
}

function parseRegexLiteral(value        )                                                {
  if (!value.startsWith("/")) return undefined;

  for (let index = value.length - 1; index > 0; index--) {
    if (value[index] !== "/" || isEscaped(value, index)) continue;
    return { source: value.slice(1, index), flags: value.slice(index + 1) };
  }

  return undefined;
}

function isEscaped(value        , index        )          {
  let slashCount = 0;
  for (let cursor = index - 1; cursor >= 0 && value[cursor] === "\\"; cursor--) {
    slashCount++;
  }
  return slashCount % 2 === 1;
}
