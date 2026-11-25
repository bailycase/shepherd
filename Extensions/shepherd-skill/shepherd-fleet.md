# The host and Fleet

## The host

`Shepherd --host` owns the workspace, every agent's process, the terminals and the network listener. The app is its client
over `<support>/host.sock`, which accepts only the signed Shepherd app: an agent connecting to it is refused before it
can send anything. In installed Shepherd and Shepherd Nightly the host is a background service, so agents keep running after the app
quits; in a development build, or with the service off, it is the app's child and stops at Quit. Restarting it interrupts every agent on the
Mac, you included.

## Fleet

Fleet links the user's Macs and their iPhone and iPad, all in Settings ▸ Fleet.

**Macs.** One Mac shows a Join code, the other enters it under Add a Mac (six digits, five minutes, five tries). Paired
Macs keep a link to each other and share the fleet's device list. Removing a Mac reaches every Mac in the fleet.

**Devices.** An iPhone or iPad pairs with a code or QR from Add a device. Each Mac's own app also enrolls itself as a
device of kind Mac, to reach the other Macs. A fleet holds at most 64 active devices, Mac apps included; past that,
pairing fails until one is revoked. Revoking is final and reaches every Mac, including ones that reconnect later; a
revoked device pairs again as a new one.

**What an agent can't do.** No tool lists, pairs, removes or revokes Macs or devices, moves a thread to another Mac, or
updates a Mac. Those are clicks in Settings ▸ Fleet or the thread's menu: tell the user where. `agent_move` moves a
thread between spaces on this Mac only.

## Sending work to another Mac (`fleet_*`)

With Settings ▸ Fleet ▸ Threads can send work on (off by default), a thread may send separate work to another Mac without
being asked. The other Mac starts a new thread on a fresh branch at your commit, and its result comes back as data.

- `fleet_hosts`: the Macs, whether each is reachable and how busy.
- `fleet_dispatch`: send a task. Give it everything it needs; it doesn't see your conversation.
- `fleet_read`, `fleet_wait` (120 seconds by default, 600 at most): progress and result.
- `fleet_send`: a follow-up or steer to the dispatched thread. `fleet_cancel`: stop it without deleting it.
- `fleet_close`: when the user asks, close a settled dispatch, stop its processes, and remove verified build output. Keeps the checkout, branches, and saved conversation; returns a cleanup report.
- Limits: 3 in flight per thread by default (1 to 10), 8 running on a receiving Mac. A thread three below one the user started
  can't dispatch further. The host refuses when the setting is off; a named Mac is never swapped for another.

## Files under `<support>/fleet/`

`identity.json` (this Mac's fleet id), `peers.json` (paired Macs), `devices.json` (devices and revocations),
`dispatches.json` and `dispatches-inbound.json`, and `index/` (the content index). The host reads them when it starts and
writes them from memory, so an edit while it runs is overwritten. They are not an interface: use Settings ▸ Fleet.

## The remote listener

The iPhone, iPad and paired Macs reach a Mac over its TCP listener (port 7433, 7434 for Nightly), open when Fleet needs it
or Serve this Mac is on. Each client has its own token. There is no TLS: keep it on a trusted network or VPN.
