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
import Anthropic from "@anthropic-ai/sdk";
                                                                                            
import {
           
                        
                                   
  calculateCost,
  collapseSystemMessages,
  createAssistantMessageEventStream,
  getCurrentSystemPrompt,
  getCurrentTools,
                  
             
                           
                  
                         
} from "@earendil-works/pi-ai";
import { isClaudeOAuthAccessToken, USER_AGENT } from "./auth.js";
import {
  convertPiMessagesToAnthropic,
  convertPiToolsToAnthropic,
  fromClaudeCodeToolName,
                    
} from "./convert.js";
import { buildAnthropicSystemPrompt, resolveCacheRetention } from "./prompt.js";

const REQUIRED_BETAS = [
  "claude-code-20250219",
  "oauth-2025-04-20",
  // fine-grained-tool-streaming removed: it ships the model's raw, unvalidated
  // tool-input JSON. For large edits full of quotes/newlines the streamed
  // string escaping breaks, so a field (e.g. edit.oldText) swallows the rest of
  // the structure — surfacing as either a hard JSON.parse crash or a wrong-shape
  // schema-validation failure. Default streaming has the server validate/buffer
  // tool JSON, guaranteeing well-formed, correctly-structured input.
  "interleaved-thinking-2025-05-14",
]         ;

const LEGACY_THINKING_MODEL =
  /^claude-(?:opus|sonnet|haiku)-4-[0-5](?:-|$)|^claude-[0-3][-.]/;
const MIN_THINKING_BUDGET = 1024;
const EFFORT_BY_REASONING                         = {
  minimal: "low",
  low: "low",
  medium: "medium",
  high: "high",
  xhigh: "xhigh",
  max: "max",
};

export function usesAdaptiveThinking(model            )          {
  const forced = (
    model.compat                                                   
  )?.forceAdaptiveThinking;
  if (typeof forced === "boolean") return forced;
  return !LEGACY_THINKING_MODEL.test(model.id.toLowerCase().replace(/\./g, "-"));
}

function mapStopReason(reason                           )             {
  switch (reason) {
    case "end_turn":
    case "pause_turn":
    case "stop_sequence":
      return "stop";
    case "max_tokens":
      return "length";
    case "tool_use":
      return "toolUse";
    default:
      return "error";
  }
}

                          
                               
                                
                                          
                                              
                                                              
  

export function applyMessageDelta(
  output                  ,
  model            ,
  stopReason                           ,
  usage                               ,
  stopDetails                                         ,
)       {
  if (stopReason != null) {
    output.stopReason = mapStopReason(stopReason);
    if (output.stopReason === "error") {
      // Keep the provider's reason (e.g. "refusal") and explanation instead of a generic message.
      output.errorMessage = `Provider stop reason: ${stopReason}${
        stopDetails?.explanation ? ` — ${stopDetails.explanation}` : ""
      }`;
    }
  }

  if (usage) {
    if (usage.input_tokens != null) output.usage.input = usage.input_tokens;
    if (usage.output_tokens != null) output.usage.output = usage.output_tokens;
    if (usage.cache_read_input_tokens != null) {
      output.usage.cacheRead = usage.cache_read_input_tokens;
    }
    if (usage.cache_creation_input_tokens != null) {
      output.usage.cacheWrite = usage.cache_creation_input_tokens;
    }
    const thinkingTokens = usage.output_tokens_details?.thinking_tokens;
    if (thinkingTokens != null) output.usage.reasoning = thinkingTokens;
  }

  output.usage.totalTokens =
    output.usage.input +
    output.usage.output +
    output.usage.cacheRead +
    output.usage.cacheWrite;
  calculateCost(model, output.usage);
}

function headersToRecord(headers         )                         {
  const record                         = {};
  headers.forEach((value, key) => {
    record[key] = value;
  });
  return record;
}

function makeDefaultHeaders(
  isOAuth         ,
  options                      ,
)                         {
  const headers                         = {
    accept: "application/json",
    "anthropic-dangerous-direct-browser-access": "true",
  };

  if (isOAuth) {
    headers["anthropic-beta"] = REQUIRED_BETAS.join(",");
    headers["user-agent"] = USER_AGENT;
    headers["x-app"] = "cli";
  } else {
    headers["anthropic-beta"] = ["interleaved-thinking-2025-05-14"].join(",");
  }

  if (options?.headers) {
    for (const [key, value] of Object.entries(options.headers)) {
      const normalizedKey = key.toLowerCase();
      if (
        isOAuth &&
        (normalizedKey === "x-api-key" || normalizedKey === "authorization")
      ) {
        continue;
      }
      const existingKey = Object.keys(headers).find(
        (header) => header.toLowerCase() === normalizedKey,
      );
      if (existingKey) delete headers[existingKey];
      if (value !== null) headers[key] = value;
    }
  }

  return headers;
}

export function streamAnthropicOAuth(
  model            ,
  context                   ,
  options                      ,
)                              {
  const stream = createAssistantMessageEventStream();

  // Anthropic has no mid-conversation system messages: fold system-message
  // patches into the leading system message, then read the current prompt and
  // tool declarations from the transcript (pi >= 0.86 no longer provides
  // context.systemPrompt / context.tools).
  const transcript = collapseSystemMessages(context);
  const tools = getCurrentTools(transcript.messages);
  const systemPrompt = getCurrentSystemPrompt(transcript.messages);

  void (async () => {
    const output                   = {
      role: "assistant",
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop",
      timestamp: Date.now(),
    };

    try {
      const apiKey = options?.apiKey;
      if (!apiKey) {
        throw new Error(
          "No Anthropic auth available. Run /login and choose Claude Pro/Max.",
        );
      }

      const isOAuth = isClaudeOAuthAccessToken(apiKey);
      const defaultHeaders = makeDefaultHeaders(isOAuth, options);

      if (isOAuth) defaultHeaders.authorization = `Bearer ${apiKey}`;

      const client = new Anthropic({
        baseURL: model.baseUrl,
        apiKey: isOAuth ? null : apiKey,
        authToken: isOAuth ? apiKey : null,
        defaultHeaders,
        dangerouslyAllowBrowser: true,
      });

      const maxTokens =
        options?.maxTokens || Math.floor(model.maxTokens / 3);
      const cacheRetention = resolveCacheRetention(
        options?.cacheRetention,
        options?.env,
      );

      const params                               = {
        model: model.id,
        messages: convertPiMessagesToAnthropic(
          transcript.messages,
          isOAuth,
          model,
          cacheRetention,
        ),
        max_tokens: maxTokens,
        stream: true,
      };

      const system = buildAnthropicSystemPrompt(systemPrompt, isOAuth, cacheRetention);
      if (system) params.system = system         ;
      if (tools.length)
        params.tools = convertPiToolsToAnthropic(tools, isOAuth);

      if (options?.reasoning && model.reasoning && maxTokens > 1) {
        const defaultBudgets                         = {
          minimal: 1024,
          low: 4096,
          medium: 10240,
          high: 20480,
          xhigh: 32000,
        };
        const customBudget =
          options.thinkingBudgets?.[
            options.reasoning                                        
          ];
        const requestedBudget =
          customBudget ?? defaultBudgets[options.reasoning] ?? 10240;
        if (usesAdaptiveThinking(model)) {
          const mapped = model.thinkingLevelMap?.[options.reasoning];
          const effort =
            typeof mapped === "string"
              ? mapped
              : (EFFORT_BY_REASONING[options.reasoning] ?? "high");
          params.thinking = {
            type: "adaptive",
            display: "summarized",
          }         ;
          Object.assign(params, { output_config: { effort } });
        } else {
          const budget = Math.min(requestedBudget, maxTokens - 1);
          if (budget >= MIN_THINKING_BUDGET) {
            params.thinking = { type: "enabled", budget_tokens: budget };
          }
        }
      }

      // Raw stream instead of the MessageStream helper: MessageStream
      // accumulates tool_use input and JSON.parses it on content_block_stop,
      // which throws under fine-grained-tool-streaming (input may be invalid
      // mid-flight) and aborts the turn. The raw stream yields the same
      // RawMessageStreamEvents; tool args are already parsed leniently below.
      const { data: anthropicStream, response: httpResponse } =
        await client.messages
          .create(params, {
            signal: options?.signal,
          })
          .withResponse();

      if (options?.onResponse) {
        try {
          await options.onResponse(
            {
              status: httpResponse.status,
              headers: headersToRecord(httpResponse.headers),
            },
            model,
          );
        } catch {
          // Response hooks are best-effort and should not break streaming.
        }
      }

      stream.push({ type: "start", partial: output });

      const blocks = output.content                  ;

      let lastEvent = "";
      try {
        for await (const event of anthropicStream) {
          lastEvent = event.type;

          if (event.type === "message_start") {
            output.usage.input = event.message.usage.input_tokens || 0;
            output.usage.output = event.message.usage.output_tokens || 0;
            output.usage.cacheRead =
              (event.message.usage                                        )
                .cache_read_input_tokens || 0;
            output.usage.cacheWrite =
              (event.message.usage                                            )
                .cache_creation_input_tokens || 0;
            output.usage.totalTokens =
              output.usage.input +
              output.usage.output +
              output.usage.cacheRead +
              output.usage.cacheWrite;
            calculateCost(model, output.usage);
            continue;
          }

          if (event.type === "content_block_start") {
            if (event.content_block.type === "text") {
              output.content.push({
                type: "text",
                text: "",
                index: event.index,
              }                );
              stream.push({
                type: "text_start",
                contentIndex: output.content.length - 1,
                partial: output,
              });
            } else if (event.content_block.type === "thinking") {
              output.content.push({
                type: "thinking",
                thinking: "",
                thinkingSignature: "",
                index: event.index,
              }                );
              stream.push({
                type: "thinking_start",
                contentIndex: output.content.length - 1,
                partial: output,
              });
            } else if (event.content_block.type === "redacted_thinking") {
              output.content.push({
                type: "thinking",
                thinking: "[Reasoning redacted]",
                thinkingSignature: event.content_block.data,
                redacted: true,
                index: event.index,
              }                );
              stream.push({
                type: "thinking_start",
                contentIndex: output.content.length - 1,
                partial: output,
              });
            } else if (event.content_block.type === "tool_use") {
              output.content.push({
                type: "toolCall",
                id: event.content_block.id,
                name: isOAuth
                  ? fromClaudeCodeToolName(
                      event.content_block.name,
                      tools,
                    )
                  : event.content_block.name,
                arguments: {},
                partialJson: "",
                index: event.index,
              }                );
              stream.push({
                type: "toolcall_start",
                contentIndex: output.content.length - 1,
                partial: output,
              });
            }
            continue;
          }

          if (event.type === "content_block_delta") {
            const contentIndex = blocks.findIndex(
              (block) => block.index === event.index,
            );
            const block = blocks[contentIndex];
            if (!block) continue;

            if (event.delta.type === "text_delta" && block.type === "text") {
              block.text += event.delta.text;
              stream.push({
                type: "text_delta",
                contentIndex,
                delta: event.delta.text,
                partial: output,
              });
            } else if (
              event.delta.type === "thinking_delta" &&
              block.type === "thinking"
            ) {
              block.thinking += event.delta.thinking;
              stream.push({
                type: "thinking_delta",
                contentIndex,
                delta: event.delta.thinking,
                partial: output,
              });
            } else if (
              event.delta.type === "signature_delta" &&
              block.type === "thinking"
            ) {
              block.thinkingSignature =
                (block.thinkingSignature || "") + event.delta.signature;
            } else if (
              event.delta.type === "input_json_delta" &&
              block.type === "toolCall"
            ) {
              block.partialJson += event.delta.partial_json;
              try {
                block.arguments = JSON.parse(block.partialJson)              ;
              } catch {}
              stream.push({
                type: "toolcall_delta",
                contentIndex,
                delta: event.delta.partial_json,
                partial: output,
              });
            }
            continue;
          }

          if (event.type === "content_block_stop") {
            const contentIndex = blocks.findIndex(
              (block) => block.index === event.index,
            );
            const block = blocks[contentIndex];
            if (!block) continue;

            delete (block                      ).index;
            if (block.type === "text") {
              stream.push({
                type: "text_end",
                contentIndex,
                content: block.text,
                partial: output,
              });
            } else if (block.type === "thinking") {
              stream.push({
                type: "thinking_end",
                contentIndex,
                content: block.thinking,
                partial: output,
              });
            } else if (block.type === "toolCall") {
              try {
                block.arguments = JSON.parse(block.partialJson)              ;
              } catch {}
              delete (block                            ).partialJson;
              stream.push({
                type: "toolcall_end",
                contentIndex,
                toolCall: block,
                partial: output,
              });
            }
            continue;
          }

          if (event.type === "message_delta") {
            applyMessageDelta(
              output,
              model,
              event.delta.stop_reason,
              event.usage                                 ,
              (event.delta                                                             )
                .stop_details,
            );
          }
        }
      } catch (error) {
        // Bun can throw while closing the body after message_stop (#37).
        if (lastEvent !== "message_stop") throw error;
      }

      if (options?.signal?.aborted) throw new Error("Request aborted");
      if (output.stopReason === "error") {
        output.errorMessage ??= "Unrecognized stop reason from the API.";
        stream.push({ type: "error", reason: "error", error: output });
      } else {
        stream.push({
          type: "done",
          reason: output.stopReason                                 ,
          message: output,
        });
      }
      stream.end();
    } catch (error) {
      for (const block of output.content           
                       
                             
        ) {
        delete block.index;
        delete block.partialJson;
      }
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage =
        error instanceof Error ? error.message : String(error);
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    }
  })();

  return stream;
}
