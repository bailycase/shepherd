export interface RestartRecoveryState {
    version: 1;
    checkpoint?: { token: string; fence: string; leafID: string };
    refusal?: string;
}
export interface CheckpointRecoveryState {
    version: 1;
    checkpoint?: { token: string; failedEntryID: string };
    refusal?: string;
}
export type CheckpointRecoveryReceipt = {
    operationID: string;
    token: string;
    sessionID: string;
} & ({
    state: "accepted" | "settled" | "unknown";
    failedEntryID: string;
    generation: string;
    leafID: string;
    error?: string;
} | {
    state: "refused";
    error: string;
    failedEntryID?: string;
});
