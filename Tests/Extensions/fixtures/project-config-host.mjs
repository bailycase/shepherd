import * as net from "node:net";

// Stand-in owning host for extension tests whose project configuration is already prepared.
export async function projectConfigHost(path) {
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket); socket.on("close", () => sockets.delete(socket)); socket.on("error", () => {});
    let buffer = "";
    socket.on("data", (data) => {
      buffer += data.toString();
      while (buffer.includes("\n")) {
        const end = buffer.indexOf("\n"), line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        const frame = JSON.parse(line);
        if (frame.type === "prepareProjectConfiguration") socket.write(JSON.stringify({ type: "ok", id: frame.id }) + "\n");
      }
    });
  });
  await new Promise((resolve) => server.listen(path, resolve));
  return { async close() { for (const socket of sockets) socket.destroy(); await new Promise((resolve) => server.close(resolve)); } };
}
