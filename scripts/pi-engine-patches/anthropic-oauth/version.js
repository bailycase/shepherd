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
export const CLAUDE_CODE_VERSION_ENV = "PI_ANTHROPIC_OAUTH_CLAUDE_CODE_VERSION";
const DEFAULT_CLAUDE_CODE_VERSION = "2.1.280";

/**
 * Claude Code version advertised to the API (user agent and billing header).
 *
 * Anthropic gates new models on the client version; override with
 * PI_ANTHROPIC_OAUTH_CLAUDE_CODE_VERSION when a newer one is required.
 */
export function getClaudeCodeVersion(
  env                    = process.env,
)         {
  return env[CLAUDE_CODE_VERSION_ENV]?.trim() || DEFAULT_CLAUDE_CODE_VERSION;
}

/**
 * User agent matching the current Claude Code CLI client. The classifier
 * rejects the older `claude-code/<ver>` form for premium models.
 */
export function makeClaudeCodeUserAgent(
  env                    = process.env,
)         {
  return `claude-cli/${getClaudeCodeVersion(env)} (external, cli)`;
}
