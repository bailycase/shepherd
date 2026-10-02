// The tool list the fake MCP servers (fake-mcp-stdio.mjs, fake-mcp-http.mjs) share, and what each tool answers.
//
// `base()` is a handful of tools that echo, fail, wait and read the environment. `forge(n)` is a stand-in for a
// real server's catalog (a code host's, say): n tools with a sentence of description and a schema of four or five
// described properties each, which is what makes a catalog cost prompt tokens when it is declared to the model.
// It is deterministic, so a test can name the tools it expects.

export function base() {
  return [
    { name: "echo", title: "Echo", description: "Echo the text back. Handy for tests.", inputSchema: { $schema: "http://json-schema.org/draft-07/schema#", type: "object", properties: { text: { type: "string" } }, required: ["text"] } },
    { name: "add", description: "Add two numbers.", inputSchema: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } } } },
    { name: "fail", description: "Always fails with an error result.", inputSchema: { type: "object" } },
    { name: "slow", description: "Waits before answering.", inputSchema: { type: "object", properties: { ms: { type: "number" } } } },
    { name: "env", description: "Reads one environment variable.", inputSchema: { type: "object", properties: { name: { type: "string" } } } },
    { name: "grow", description: "Adds a tool and says the list changed.", inputSchema: { type: "object" } },
  ];
}

const VERBS = ["create", "get", "list", "update", "delete", "search", "merge", "close", "comment_on", "assign"];
const NOUNS = ["issue", "pull_request", "branch", "commit", "release", "workflow_run", "repository", "label", "milestone", "review"];

/** n deterministic tools shaped like a real server's catalog: `create_issue`, `get_issue`, … */
export function forge(n) {
  const out = [];
  for (let i = 0; out.length < n; i++) {
    const verb = VERBS[i % VERBS.length];
    const noun = NOUNS[Math.floor(i / VERBS.length) % NOUNS.length];
    const label = noun.replace(/_/g, " ");
    out.push({
      name: `${verb}_${noun}`,
      title: `${verb.replace(/_/g, " ")} ${label}`,
      description: `${verb.replace(/_/g, " ")} a ${label} in a repository. Use it when the person asks to ${verb.replace(/_/g, " ")} a ${label}; pass the owner and the repository name, and any of the optional filters.`,
      inputSchema: {
        $schema: "http://json-schema.org/draft-07/schema#",
        type: "object",
        properties: {
          owner: { type: "string", description: "The account that owns the repository, such as a user or an organisation" },
          repo: { type: "string", description: "The repository name without the owner" },
          number: { type: "integer", description: `The ${label} number, when the call is about one that exists` },
          query: { type: "string", description: "Free text to match against titles and bodies" },
          perPage: { type: "integer", minimum: 1, maximum: 100, description: "How many results to return on a page, from 1 to 100" },
        },
        required: ["owner", "repo"],
      },
    });
  }
  return out;
}

export function text(value) {
  return { content: [{ type: "text", text: value }] };
}

/** What a tool answers. `grow` is left to the caller, which owns its tool list. */
export function call(name, args = {}, env = process.env) {
  switch (name) {
    case "echo": return text(`echo: ${args.text}`);
    case "add": return { content: [], structuredContent: { sum: args.a + args.b } };
    case "fail": return { isError: true, content: [{ type: "text", text: "the database is down" }] };
    case "env": return text(`${args.name}=${env[args.name] ?? ""}`);
    case "grown": return text("hello from grown");
    default: return text(`${name} ok: ${JSON.stringify(args)}`);
  }
}
