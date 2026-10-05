export default function (pi) {
  for (const name of ["ping", "blocked"]) {
    pi.registerTool({
      name, label: name, description: "Local codemode test tool", parameters: { type: "object", properties: {} },
      async execute() { return { content: [{ type: "text", text: name === "ping" ? "pong" : "EXECUTED BLOCKED TOOL" }], details: {} }; },
    });
  }
  pi.on("tool_call", (event) => event.toolName === "blocked" ? { block: true, reason: "approval denied" } : undefined);
}
