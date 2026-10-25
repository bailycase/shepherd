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
             
                        
                    
               
            
                                                 

                             
                                  
     
                    
               
                       
                                                                            
                     
        
      
             
      
                 
               
          
        
              
                  
       
           
                    
                               
import { cacheControlFor, sanitizeSurrogates } from "./prompt.js";

                          
                                     
                                                                     
                                                        

const claudeCodeTools = [
  "Read",
  "Write",
  "Edit",
  "Bash",
  "Grep",
  "Glob",
  "AskUserQuestion",
  "TodoWrite",
  "WebFetch",
  "WebSearch",
]         ;
const claudeCodeToolLookup = new Map(claudeCodeTools.map((name) => [name.toLowerCase(), name]));

// Anthropic's OAuth classifier rejects tool definitions with names outside
// Claude Code's own tool set with a 400 "Third-party apps now draw from your
// extra usage" error. Claude Code exposes MCP tools as `mcp__<server>__<tool>`,
// so unknown tools are namespaced under `mcp__pi__`.
const CLAUDE_CODE_MCP_TOOL_PREFIX = "mcp__pi__";

function sanitizeCustomToolName(name        )         {
  return name.replace(/[^a-zA-Z0-9_-]/g, "_");
}

export function toClaudeCodeToolName(name        )         {
  return (
    claudeCodeToolLookup.get(name.toLowerCase()) ??
    `${CLAUDE_CODE_MCP_TOOL_PREFIX}${sanitizeCustomToolName(name)}`
  );
}

export function fromClaudeCodeToolName(name        , tools         )         {
  if (name.startsWith(CLAUDE_CODE_MCP_TOOL_PREFIX)) {
    const stripped = name.slice(CLAUDE_CODE_MCP_TOOL_PREFIX.length);
    return tools?.find((tool) => sanitizeCustomToolName(tool.name) === stripped)?.name ?? stripped;
  }
  const lower = name.toLowerCase();
  return tools?.find((tool) => tool.name.toLowerCase() === lower)?.name ?? name;
}

export function convertPiMessagesToAnthropic(
  messages           ,
  isOAuth         ,
  model                                             ,
  cacheRetention                 = "short",
)                 {
  const params                 = [];
  const toolIdMap = new Map                ();
  const usedToolIds = new Set        ();

  const getAnthropicToolId = (id        )         => {
    const existing = toolIdMap.get(id);
    if (existing) return existing;

    let base = sanitizeSurrogates(id).replace(/[^a-zA-Z0-9_-]/g, "_");
    if (!base) base = "tool";
    let candidate = base;
    let suffix = 1;
    while (usedToolIds.has(candidate)) {
      candidate = `${base}_${suffix++}`;
    }
    usedToolIds.add(candidate);
    toolIdMap.set(id, candidate);
    return candidate;
  };

  // Anthropic requires every `tool_use` block to be IMMEDIATELY followed by a
  // user message containing a matching `tool_result` for the same id. Aborted
  // / errored assistant turns or partial histories can leave orphan tool_uses
  // behind, which causes the API to reject the next request with:
  //   `tool_use` ids were found without `tool_result` blocks immediately after
  // We track outstanding tool_use ids from the last assistant message and
  // synthesize "No result provided" results for any that aren't satisfied by
  // the time we emit the next user message (or finish the history).
  let pendingToolUseIds           = [];

  const flushPendingToolResults = () => {
    if (pendingToolUseIds.length === 0) return;
    const syntheticBlocks                      = pendingToolUseIds.map((id) => ({
      type: "tool_result",
      tool_use_id: id,
      content: "No result provided",
      is_error: true,
    }));
    params.push({ role: "user", content: syntheticBlocks });
    pendingToolUseIds = [];
  };

  for (let i = 0; i < messages.length; i++) {
    const message = messages[i];

    if (message.role === "user") {
      flushPendingToolResults();
      if (typeof message.content === "string") {
        if (message.content.trim()) params.push({ role: "user", content: sanitizeSurrogates(message.content) });
      } else {
        // Extensions may emit custom messages with empty text (e.g. a
        // display-only message whose data lives in `details`). Anthropic
        // rejects empty text blocks, and a cache breakpoint on one fails with
        // "cache_control cannot be set for empty text blocks".
        const blocks                      = message.content
          .filter((item) => item.type !== "text" || item.text.trim())
          .map((item) =>
            item.type === "text"
              ? { type: "text", text: sanitizeSurrogates(item.text) }
              : {
                  type: "image",
                  source: { type: "base64", media_type: item.mimeType         , data: item.data },
                },
          );
        if (blocks.length > 0) params.push({ role: "user", content: blocks });
      }
      continue;
    }

    if (message.role === "assistant") {
      // Skip aborted / errored assistant turns entirely. Their content may
      // include partial tool_use blocks that will never get a matching
      // tool_result, which would poison every subsequent request.
      if (message.stopReason === "aborted" || message.stopReason === "error") {
        continue;
      }

      // Defensive: if the previous assistant turn had unresolved tool_uses and
      // the next message is another assistant (shouldn't normally happen),
      // patch them up before emitting the new assistant turn.
      flushPendingToolResults();

      const blocks                      = [];
      const emittedToolUseIds           = [];
      const isSameModel =
        message.provider === model.provider &&
        message.api === model.api &&
        message.model === model.id;
      for (const block of message.content) {
        if (block.type === "text" && block.text.trim()) {
          blocks.push({ type: "text", text: sanitizeSurrogates(block.text) });
        } else if (block.type === "thinking") {
          const thinkingSignature = block.thinkingSignature?.trim();
          if (block.redacted) {
            if (isSameModel && thinkingSignature) {
              blocks.push({
                type: "redacted_thinking",
                data: block.thinkingSignature ,
              });
            }
          } else if (isSameModel && thinkingSignature) {
            blocks.push({
              type: "thinking",
              thinking: sanitizeSurrogates(block.thinking),
              signature: block.thinkingSignature ,
            });
          } else if (block.thinking.trim()) {
            blocks.push({
              type: "text",
              text: sanitizeSurrogates(block.thinking),
            });
          }
        } else if (block.type === "toolCall") {
          const anthropicId = getAnthropicToolId(block.id);
          blocks.push({
            type: "tool_use",
            id: anthropicId,
            name: isOAuth ? toClaudeCodeToolName(block.name) : block.name,
            input: block.arguments ?? {},
          });
          emittedToolUseIds.push(anthropicId);
        }
      }
      if (blocks.length > 0) {
        params.push({ role: "assistant", content: blocks });
        pendingToolUseIds = emittedToolUseIds;
      }
      continue;
    }

    if (message.role === "toolResult") {
      const toolResults                      = [];
      const satisfiedIds = new Set        ();

      const firstId = getAnthropicToolId(message.toolCallId);
      toolResults.push({
        type: "tool_result",
        tool_use_id: firstId,
        content: convertToolResultContentToAnthropic(message.content),
        is_error: message.isError,
      });
      satisfiedIds.add(firstId);

      let j = i + 1;
      while (j < messages.length && messages[j]?.role === "toolResult") {
        const nextMessage = messages[j]                     ;
        const nextId = getAnthropicToolId(nextMessage.toolCallId);
        toolResults.push({
          type: "tool_result",
          tool_use_id: nextId,
          content: convertToolResultContentToAnthropic(nextMessage.content),
          is_error: nextMessage.isError,
        });
        satisfiedIds.add(nextId);
        j++;
      }
      i = j - 1;

      // Synthesize "No result provided" for any tool_use from the last
      // assistant message that wasn't covered by the toolResult run. They
      // must live in the SAME user message as the real tool_results so that
      // every tool_use is immediately followed by matching results.
      for (const id of pendingToolUseIds) {
        if (!satisfiedIds.has(id)) {
          toolResults.push({
            type: "tool_result",
            tool_use_id: id,
            content: "No result provided",
            is_error: true,
          });
        }
      }
      pendingToolUseIds = [];

      params.push({ role: "user", content: toolResults });
    }
  }

  // The loop flushes pending tool uses before the next message. Flush once more
  // so a history ending on an unresolved tool call is still valid.
  flushPendingToolResults();

  // Anthropic prompt caching requires an explicit breakpoint. Plain-text user
  // turns must be promoted to a block so there is somewhere to attach it.
  const cacheControl = cacheControlFor(cacheRetention);
  const last = params.at(-1);
  if (cacheControl && last?.role === "user") {
    if (typeof last.content === "string") {
      if (last.content) {
        last.content = [
          {
            type: "text",
            text: last.content,
            cache_control: cacheControl,
          },
        ];
      }
    } else if (last.content.length > 0) {
      const lastBlock = last.content[last.content.length - 1]     
                                              
       ;
      lastBlock.cache_control = cacheControl;
    }
  }

  return params;
}

export function convertPiToolsToAnthropic(tools        , isOAuth         )              {
  return tools.map((tool) => ({
    name: isOAuth ? toClaudeCodeToolName(tool.name) : tool.name,
    description: tool.description,
    input_schema: {
      type: "object"         ,
      properties: (tool.parameters                                            ).properties ?? {},
      required: (tool.parameters                           ).required ?? [],
    },
  }));
}

function convertToolResultContentToAnthropic(
  content                                ,
)                                    {
  const hasImages = content.some((block) => block.type === "image");
  if (!hasImages) {
    return sanitizeSurrogates(
      content
        .filter((block)                       => block.type === "text")
        .map((block) => block.text)
        .join("\n"),
    );
  }

  const blocks = content.map((block) => {
    if (block.type === "text") return { type: "text"         , text: sanitizeSurrogates(block.text) };
    return {
      type: "image"         ,
      source: {
        type: "base64"         ,
        media_type: block.mimeType                                                                     
                                             
               
                   
                 ,
        data: block.data,
      },
    };
  });

  if (!blocks.some((block) => block.type === "text")) {
    blocks.unshift({ type: "text", text: "(see attached image)" });
  }

  return blocks;
}
