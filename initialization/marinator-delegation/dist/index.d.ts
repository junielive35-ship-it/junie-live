type AgentHookContext = {
    sessionKey?: string;
    runId?: string;
    agentDir?: string;
    workspaceDir?: string;
};
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
