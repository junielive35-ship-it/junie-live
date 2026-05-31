type AgentHookContext = {
    sessionKey?: string;
    runId?: string;
    agentDir?: string;
    workspaceDir?: string;
};
export type MarinatorStatus = {
    job_id?: string;
    state?: string;
    updated_at?: string;
    handoff?: {
        state?: string;
        session_key?: string;
        schedule_job_id?: string | null;
        scheduled_at?: string | null;
        consumed_by_run_id?: string | null;
        consumed_at?: string | null;
        last_error?: string | null;
        retry_state?: "none" | "retrying" | "stale" | "failed_final";
        last_checked_at?: string | null;
        consecutive_errors?: number | null;
        next_retry_at?: string | null;
        run_history?: Array<{
            checked_at: string;
            status?: string;
            error?: string;
            run_at?: string;
            duration_ms?: number;
            next_retry_at?: string | null;
        }>;
    };
    active_run?: {
        sessionKey?: string;
        runId?: string;
        state?: "active" | "ended";
        startedAt?: string;
        endedAt?: string;
    };
    anomalies?: Array<{
        type: string;
        detected_at: string;
        detail?: string;
    }>;
};
export declare function canonicalizeDeliveryTarget(channel: string, target: string, threadId: string | number | undefined): {
    target: string;
    threadId?: string | number;
};
export declare function resolveDeliverySpec(toolContext: any): {
    channel: string;
    target: string;
    threadId?: string | number;
    accountId?: string;
} | null;
export declare function applyCronRunHistoryToStatus(status: MarinatorStatus, cron: {
    entries?: Array<any>;
    job?: any;
}, checkedAt?: Date): MarinatorStatus;
export declare function handleBeforeAgentRun(_event: unknown, ctx: AgentHookContext): Promise<void>;
export declare function handleAgentEnd(_event: unknown, ctx: AgentHookContext): Promise<void>;
export declare function reconcileMarinatorStatuses(workspaceDir: string, now?: Date, staleMinutes?: number): Promise<void>;
declare const _default: {
    id: string;
    name: string;
    description: string;
    configSchema: import("openclaw/plugin-sdk/plugin-entry").OpenClawPluginConfigSchema;
    register: NonNullable<import("openclaw/plugin-sdk/plugin-entry").OpenClawPluginDefinition["register"]>;
} & Pick<import("openclaw/plugin-sdk/plugin-entry").OpenClawPluginDefinition, "kind" | "reload" | "nodeHostCommands" | "securityAuditCollectors">;
export default _default;
