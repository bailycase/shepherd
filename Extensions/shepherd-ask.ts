// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd's ask-the-user tool: one model-facing tool, `ask_user`, that opens pi's native
// question dialog (`ctx.ui.input`), which Shepherd draws as the thread's question dock and lists
// under Needs you on the Mac, iPhone and iPad. With options the dialog offers them as buttons
// and still takes the person's own words (the same shape project_question uses). The tool waits
// for the answer; a cancel is reported, never invented. Inert unless `SHEPHERD_EXT_ASK=1`.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// The dock draws the question as a headline and folds `details` under it. A short question cap is
// what keeps agents from pasting their reasoning into the headline; the two fit Shepherd's 2000-byte title.
const MAX_QUESTION_BYTES = 300;
const MAX_DETAILS_BYTES = 1600;
const MAX_OPTION_BYTES = 256;
const MAX_OPTIONS = 6;
const MAX_SHORT = 120;

export default function shepherdAsk(pi: ExtensionAPI) {
  if (process.env.SHEPHERD_EXT_ASK !== "1") return;

  pi.registerTool({
    name: "ask_user",
    label: "Ask the user",
    description:
      "Ask the person using this thread a question and wait for their answer. Use it when you are blocked on a " +
      "decision that is theirs; do not guess. Give options when the question has a few possible answers (they can " +
      "still answer in their own words); omit them for free text. One question per call.",
    promptSnippet: "Ask the person a question and wait for the answer",
    parameters: Type.Object({
      question: Type.String({ minLength: 1, maxLength: MAX_QUESTION_BYTES, description: "One short sentence: the decision you need." }),
      details: Type.Optional(Type.String({ maxLength: MAX_DETAILS_BYTES, description: "Background needed to decide, a few sentences, shown folded under the question." })),
      options: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: MAX_OPTION_BYTES }), {
        minItems: 1, maxItems: MAX_OPTIONS, description: "A few possible answers, when it has them.",
      })),
      short: Type.Optional(Type.String({ maxLength: MAX_SHORT, description: "What you need in 1-3 words, shown beside the thread while you wait." })),
    }, { additionalProperties: false }),
    async execute(_id, params, signal, _update, ctx) {
      const question = typeof params?.question === "string" ? params.question.trim() : "";
      const details = typeof params?.details === "string" ? params.details.trim() : "";
      const options = Array.isArray(params?.options) ? [...new Set(params.options.filter((o) => typeof o === "string" && o.trim()).map((o) => o.trim()))] : [];
      if (!question || Buffer.byteLength(question) > MAX_QUESTION_BYTES || Buffer.byteLength(details) > MAX_DETAILS_BYTES
          || options.length > MAX_OPTIONS || options.some((o) => Buffer.byteLength(o) > MAX_OPTION_BYTES)) {
        return { content: [{ type: "text", text: "ask_user needs a one-sentence question of at most 300 bytes (put background in details, at most 1600) and at most 6 options of 256 bytes each." }], details: {}, isError: true };
      }
      if (!ctx.hasUI) {
        return { content: [{ type: "text", text: "No one can answer here (no question UI); decide what you can and say what you assumed." }], details: {}, isError: true };
      }
      // Shepherd normalizes this shape into buttons plus an input (RPCThreadState.handleUIRequest);
      // the dock takes the first paragraph as the question and the rest as its details.
      const choices = options.filter((o) => o !== "Say anything");
      const text = details ? `${question.replace(/\s*\n\s*/g, " ")}\n\n${details}` : question;
      const title = choices.length ? `${text}\n\nOptions:\n${JSON.stringify(choices)}` : text;
      const answer = await ctx.ui.input(title, choices.length ? "Say anything" : undefined, { signal });
      const cancelled = signal?.aborted || answer === undefined;
      if (cancelled) {
        return { content: [{ type: "text", text: "The person did not answer (the question was dismissed). Do not treat this as an answer." }], details: { cancelled: true } };
      }
      return { content: [{ type: "text", text: `The person answered: ${answer}` }], details: { answer } };
    },
  });
}
