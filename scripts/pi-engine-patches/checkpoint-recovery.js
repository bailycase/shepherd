// Shepherd's pinned Pi SDK recovery contract. No provider request or tool replay happens here.
import { createHash, randomUUID } from "node:crypto";
import { openSync, fsyncSync, closeSync } from "node:fs";
import { dirname } from "node:path";
import { sessionEntryToContextMessages } from "./session-manager.js";

const generations = new WeakMap();
const activeOperations = new WeakMap();
const unconfirmedOperations = new WeakMap();
function syncReceipt(session) {
    const file = session.sessionManager.getSessionFile();
    if (!file) return; // In-memory SDK sessions have no cross-process durability contract.
    for (const path of [file, dirname(file)]) {
        const fd = openSync(path, "r");
        try { fsyncSync(fd); } finally { closeSync(fd); }
    }
}
const receiptType = "shepherd.checkpoint-recovery.v1";
const checkpointType = "shepherd.failed-checkpoint.v1";
const unavailableCheckpoints = new WeakSet();
const digest = value => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const operationKey = value => typeof value === "string" && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value) ? value.toLowerCase() : undefined;
const receipts = session => session.sessionManager.getEntries().filter(e => e.type === "custom" && e.customType === receiptType &&
    e.data?.sessionID === session.sessionId && typeof e.data.operationID === "string" && (typeof e.data.failedEntryID === "string" ||
        e.data.state === "refused" && typeof e.data.error === "string"));

export function recoveryOperation(session, operationID) {
    operationID = operationKey(operationID);
    if (!operationID) return undefined;
    const entries = receipts(session).filter(e => e.data.operationID === operationID && e.data.sessionID === session.sessionId);
    const receipt = entries.at(-1)?.data;
    return receipt && (unconfirmedOperations.get(session)?.has(operationID) || receipt.state === "accepted" && !activeOperations.get(session)?.has(operationID))
        ? { ...receipt, state: "unknown" } : receipt;
}

export function recoveryCheckpoint(session, cwd) {
    if (generations.get(session) === null) throw Error("recovery_stale");
    if (!session.isIdle || session.isBashRunning || session.pendingMessageCount || session._recoveryPrompts ||
        session._isEmittingAgentSettled || session._pendingNextTurnMessages.length || session._pendingCustomMessages.length ||
        session._pendingBashMessages.length || session._branchSummaryAbortController) throw Error("recovery_busy");
    const manager = session.sessionManager;
    const projection = manager.buildSessionProjection();
    const last = projection.entries.filter(e => e.messages.length).at(-1);
    const failed = last?.sourceEntry;
    if (failed?.type !== "message" || failed.message.role !== "assistant" ||
        !["error", "aborted"].includes(failed.message.stopReason) || last.messages.at(-1) !== failed.message) {
        throw Error("recovery_not_failed");
    }
    if (receipts(session).some(e => e.data.failedEntryID === failed.id && e.data.state !== "refused")) throw Error("recovery_consumed");
    const operations = new Map(receipts(session).map(e => [e.data.operationID, e.data]));
    if ([...operations.values()].some(receipt => receipt.state === "accepted" ||
        unconfirmedOperations.get(session)?.has(receipt.operationID))) throw Error("recovery_unknown");
    const seal = manager.getBranch().findLast(e => e.type === "custom" && e.customType === checkpointType && e.data?.failedEntryID === failed.id)?.data;
    if (unavailableCheckpoints.has(session) || !seal || seal.sessionID !== session.sessionId) throw Error("recovery_checkpoint_unavailable");
    if (seal.forcedPrompt || seal.context !== recoveryContext(session, cwd)) throw Error("recovery_context_changed");
    // A partial tool call is not an executable checkpoint. A result marked as failed may have
    // performed a side effect before failing. Neither is permission to redeliver it.
    if (failed.message.content.some(p => p.type === "toolCall")) throw Error("recovery_uncertain_tool");
    // Compaction may summarize an uncertain call away from provider context. Safety still
    // comes from the actual branch's call/result evidence, never from that summary.
    const messages = recoveryTranscript(session);
    let start = 0;
    for (let i = 0; i < messages.length - 1; i++) {
        if (messages[i].role === "assistant" && messages[i].stopReason === "stop") start = i + 1;
    }
    const pending = new Map();
    for (const message of messages.slice(start)) {
        if (message.role === "assistant") {
            for (const call of message.content.filter(p => p.type === "toolCall")) {
                if (pending.has(call.id)) throw Error("recovery_uncertain_tool");
                pending.set(call.id, call.name);
            }
        } else if (message.role === "toolResult") {
            if (pending.get(message.toolCallId) !== message.toolName || message.isError ||
                message.nestedCalls && (!message.nestedCalls.complete || message.nestedCalls.calls.some(c => c.status !== "ok"))) {
                throw Error("recovery_uncertain_tool");
            }
            pending.delete(message.toolCallId);
        }
    }
    if (pending.size) throw Error("recovery_uncertain_tool");
    if (!generations.has(session)) generations.set(session, randomUUID());
    const identity = {
        sessionID: session.sessionId, generation: generations.get(session), leafID: manager.getLeafId(),
        failedEntryID: failed.id, cwd, model: session.model, thinking: session.thinkingLevel,
        systemPrompt: session.systemPrompt, tools: session.getActiveToolNames(),
    };
    return { token: digest(identity), failedEntryID: failed.id };
}

export function invalidateRecoveryGeneration(session, disposed = false) {
    if (disposed) generations.set(session, null);
    else if (generations.get(session) !== null) generations.delete(session);
}

export function recoveryState(session, cwd) {
    try { return { version: 1, checkpoint: recoveryCheckpoint(session, cwd) }; }
    catch (error) { return { version: 1, refusal: error.message }; }
}

export function acceptRecovery(session, token, operationID, cwd) {
    if (generations.get(session) === null) throw Error("recovery_stale");
    operationID = operationKey(operationID);
    if (typeof token !== "string" || !/^[a-f0-9]{64}$/.test(token) || !operationID) throw Error("recovery_invalid");
    const previous = recoveryOperation(session, operationID);
    if (previous) {
        if (previous.token !== token) throw Error("recovery_operation_conflict");
        return { replay: true, receipt: previous };
    }
    let checkpoint;
    try {
        checkpoint = recoveryCheckpoint(session, cwd);
        if (checkpoint.token !== token) throw Error("recovery_stale");
    } catch (error) {
        session.sessionManager.appendCustomEntry(receiptType, { operationID, token, sessionID: session.sessionId,
            state: "refused", error: error.message, ...(checkpoint ? { failedEntryID: checkpoint.failedEntryID } : {}) });
        syncReceipt(session);
        throw error;
    }
    const receipt = { operationID, token, failedEntryID: checkpoint.failedEntryID, sessionID: session.sessionId,
        generation: generations.get(session), leafID: session.sessionManager.getLeafId(), state: "accepted" };
    // Written before the omission or provider call. An accepted record without a terminal
    // receipt is unknown after a crash, never a request to resume automatically.
    session.sessionManager.appendCustomEntry(receiptType, receipt);
    syncReceipt(session);
    if (!activeOperations.has(session)) activeOperations.set(session, new Set());
    activeOperations.get(session).add(operationID);
    return { replay: false, receipt };
}

export function finishRecovery(session, receipt, state, error) {
    activeOperations.get(session)?.delete(receipt.operationID);
    // A late completion cannot append diagnostics to a new/resumed session.
    if (session.sessionId !== receipt.sessionID || generations.get(session) !== receipt.generation) return;
    try {
        session.sessionManager.appendCustomEntry(receiptType, { ...receipt, state, ...(error ? { error } : {}) });
        syncReceipt(session);
    } catch {
        if (!unconfirmedOperations.has(session)) unconfirmedOperations.set(session, new Set());
        unconfirmedOperations.get(session).add(receipt.operationID);
        session._emit({ type: "extension_error", extensionPath: "checkpoint-recovery", event: "receipt",
            error: "Recovery receipt persistence failed. Delivery is unknown; nothing will be resent." });
    }
}

const recoveryContext = (session, cwd) => digest({ cwd, model: session.model, thinking: session.thinkingLevel,
    systemPrompt: session.systemPrompt, tools: session.getActiveToolNames() });

export function recordRecoveryCheckpoint(session, sessionID, forcedPrompt, cwd) {
    if (sessionID !== session.sessionId || generations.get(session) === null) return;
    const manager = session.sessionManager;
    const failed = manager.buildSessionProjection().entries.filter(e => e.messages.length).at(-1)?.sourceEntry;
    if (failed?.type !== "message" || failed.message.role !== "assistant" || !["error", "aborted"].includes(failed.message.stopReason)) return;
    try {
        manager.appendCustomEntry(checkpointType, { sessionID, failedEntryID: failed.id, context: recoveryContext(session, cwd), forcedPrompt });
        syncReceipt(session);
        unavailableCheckpoints.delete(session);
    } catch {
        unavailableCheckpoints.add(session);
        session._emit({ type: "extension_error", extensionPath: "checkpoint-recovery", event: "checkpoint",
            error: "The failed turn has no durable recovery checkpoint. Nothing will be resent." });
    }
}

export function recoveryTranscript(session) {
    // Provider omission/compaction affects context, not the inspectable branch transcript.
    return session.sessionManager.getBranch().flatMap(sessionEntryToContextMessages);
}
