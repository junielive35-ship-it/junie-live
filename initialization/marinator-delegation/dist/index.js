import { spawn } from "node:child_process";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { jsonResult } from "openclaw/plugin-sdk/core";
const SUMMARY_MODEL = "openrouter/openai/gpt-4.1-mini";
const UPDATE_INTERVAL_SECONDS = 60;
const NO_PROGRESS_SECONDS = 900;
const TIMEOUT_SECONDS = 7200;
// Resolve the bundled runner relative to this plugin package so the plugin stays
// self-contained and works under any install shape (linked, copied, npm, ClawHub).
// dist/index.js lives at <package>/dist/index.js, so "../scripts" is <package>/scripts.
const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const RUNNER_PATH = path.join(PLUGIN_ROOT, "scripts", "delegate-coding-task.sh");
const parameters = {
    type: "object",
    properties: {
        job_id: { type: "string", description: "Stable Marinator job id. Allowed characters: letters, digits, dot, underscore, dash." },
        repo: { type: "string", description: "Absolute path to the target repository." },
        prompt_file: { type: "string", description: "Absolute path to the prompt file for opencode." },
        attachments: {
            type: "array",
            items: { type: "string" },
            description: "Optional attachment file paths for the worker.",
        },
        opencode_previous_session_id: {
            anyOf: [{ type: "string" }, { type: "null" }],
            description: "Optional previous opencode session id for follow-up/resume.",
        },
    },
    required: ["job_id", "repo", "prompt_file"],
    additionalProperties: false,
};
function requireNonEmpty(value, label) {
    if (typeof value !== "string" || value.trim().length === 0) {
        throw new Error(`marinator_delegate missing required ${label}`);
    }
    return value.trim();
}
function safeJobId(jobId) {
    if (!/^[A-Za-z0-9._-]+$/.test(jobId)) {
        throw new Error("job_id may only contain letters, digits, dot, underscore, and dash");
    }
    if (jobId === "." || jobId === "..") {
        throw new Error("job_id must not be a path traversal segment");
    }
    return jobId;
}
function canonicalizeDeliveryTarget(channel, target, threadId) {
    if (channel !== "telegram") {
        return threadId !== undefined ? { target, threadId } : { target };
    }
    const match = target.match(/^telegram:(-?\d+)(?::topic:(\d+))?$/);
    if (!match) {
        return threadId !== undefined ? { target, threadId } : { target };
    }
    const canonicalThreadId = threadId !== undefined ? threadId : match[2];
    return canonicalThreadId !== undefined ? { target: match[1], threadId: canonicalThreadId } : { target: match[1] };
}
function resolveWorkspaceDir(agentDir, workspaceDir) {
    if (workspaceDir && workspaceDir.trim())
        return workspaceDir;
    if (agentDir && agentDir.trim())
        return agentDir;
    return process.cwd();
}
async function readJson(filePath) {
    try {
        return JSON.parse(await readFile(filePath, "utf8"));
    }
    catch {
        return null;
    }
}
async function writeStatus(statusPath, status) {
    status.updated_at = new Date().toISOString();
    await writeFile(statusPath, `${JSON.stringify(status, null, 2)}\n`, "utf8");
}
async function listRunStatusPaths(workspaceDir) {
    const runsDir = path.join(workspaceDir, ".openclaw", "state", "marinator", "runs");
    try {
        const entries = await readdir(runsDir, { withFileTypes: true });
        return entries.filter((entry) => entry.isDirectory()).map((entry) => path.join(runsDir, entry.name, "status.json"));
    }
    catch {
        return [];
    }
}
function addAnomaly(status, type, detail) {
    status.anomalies = status.anomalies ?? [];
    if (status.anomalies.some((item) => item.type === type && item.detail === detail))
        return;
    status.anomalies.push({ type, detected_at: new Date().toISOString(), ...(detail ? { detail } : {}) });
}
export async function handleBeforeAgentRun(_event, ctx) {
    const workspaceDir = resolveWorkspaceDir(ctx.agentDir, ctx.workspaceDir);
    if (!ctx.sessionKey || !ctx.runId) {
        for (const statusPath of await listRunStatusPaths(workspaceDir)) {
            const status = await readJson(statusPath);
            if (!status)
                continue;
            addAnomaly(status, "invalid_before_agent_run_context", `sessionKey=${ctx.sessionKey ?? ""} runId=${ctx.runId ?? ""}`);
            await writeStatus(statusPath, status);
        }
        return;
    }
    const now = new Date().toISOString();
    for (const statusPath of await listRunStatusPaths(workspaceDir)) {
        const status = await readJson(statusPath);
        if (!status)
            continue;
        if (status.handoff?.state === "scheduled" && status.handoff.session_key === ctx.sessionKey) {
            status.handoff.state = "consumed";
            status.handoff.consumed_by_run_id = ctx.runId;
            status.handoff.consumed_at = now;
            status.active_run = { sessionKey: ctx.sessionKey, runId: ctx.runId, state: "active", startedAt: now };
            await writeStatus(statusPath, status);
        }
    }
}
export async function handleAgentEnd(_event, ctx) {
    const workspaceDir = resolveWorkspaceDir(ctx.agentDir, ctx.workspaceDir);
    if (!ctx.sessionKey || !ctx.runId) {
        for (const statusPath of await listRunStatusPaths(workspaceDir)) {
            const status = await readJson(statusPath);
            if (!status)
                continue;
            addAnomaly(status, "invalid_agent_end_context", `sessionKey=${ctx.sessionKey ?? ""} runId=${ctx.runId ?? ""}`);
            await writeStatus(statusPath, status);
        }
        return;
    }
    const now = new Date().toISOString();
    for (const statusPath of await listRunStatusPaths(workspaceDir)) {
        const status = await readJson(statusPath);
        if (!status?.active_run)
            continue;
        if (status.active_run.sessionKey === ctx.sessionKey && status.active_run.runId === ctx.runId) {
            status.active_run.state = "ended";
            status.active_run.endedAt = now;
            await writeStatus(statusPath, status);
        }
    }
}
export async function reconcileMarinatorStatuses(workspaceDir, now = new Date(), staleMinutes = 30) {
    const staleMs = staleMinutes * 60 * 1000;
    for (const statusPath of await listRunStatusPaths(workspaceDir)) {
        const status = await readJson(statusPath);
        if (!status)
            continue;
        const handoff = status.handoff;
        if (handoff?.state === "scheduled" && handoff.scheduled_at && now.getTime() - Date.parse(handoff.scheduled_at) > staleMs) {
            addAnomaly(status, "handoff_scheduled_not_consumed", `scheduled_at=${handoff.scheduled_at} schedule_job_id=${handoff.schedule_job_id ?? "unknown"}`);
        }
        if (handoff?.state === "consumed" && status.active_run?.state === "active" && status.active_run.startedAt && now.getTime() - Date.parse(status.active_run.startedAt) > staleMs) {
            addAnomaly(status, "active_run_not_ended", `startedAt=${status.active_run.startedAt}`);
        }
        if (status.anomalies?.length)
            await writeStatus(statusPath, status);
    }
}
function runDetached(command, args, cwd) {
    const child = spawn(command, args, {
        cwd,
        detached: true,
        stdio: "ignore",
    });
    child.unref();
    return { pid: child.pid };
}
function createMarinatorDelegateTool(toolContext) {
    return {
        name: "marinator_delegate",
        label: "Marinator Delegate",
        description: "Create a Marinator run from task intent, inject current OpenClaw delivery context, and start the bounded runner.",
        parameters,
        async execute(_toolCallId, params, signal) {
            signal?.throwIfAborted();
            const input = params;
            const jobId = safeJobId(requireNonEmpty(input.job_id, "job_id"));
            const repo = path.resolve(requireNonEmpty(input.repo, "repo"));
            const promptFile = path.resolve(requireNonEmpty(input.prompt_file, "prompt_file"));
            const workspaceDir = resolveWorkspaceDir(toolContext.agentDir, toolContext.workspaceDir);
            const orchestratorSessionKey = requireNonEmpty(toolContext.sessionKey, "toolContext.sessionKey");
            const deliveryContext = toolContext.deliveryContext;
            const deliveryChannel = requireNonEmpty(deliveryContext?.channel, "toolContext.deliveryContext.channel");
            const deliveryTarget = requireNonEmpty(deliveryContext?.to, "toolContext.deliveryContext.to");
            const { target: deliveryTargetCanonical, threadId } = canonicalizeDeliveryTarget(deliveryChannel, deliveryTarget, deliveryContext?.threadId);
            const accountId = deliveryContext?.accountId ?? toolContext.agentAccountId;
            const runDir = path.join(workspaceDir, ".openclaw", "state", "marinator", "runs", jobId);
            const specPath = path.join(runDir, "spec.json");
            const resolvedSpec = {
                job_id: jobId,
                repo,
                prompt_file: promptFile,
                attachments: Array.isArray(input.attachments) ? input.attachments.map((item) => path.resolve(item)) : [],
                opencode_previous_session_id: input.opencode_previous_session_id ?? null,
                run_dir: runDir,
                summary_model: SUMMARY_MODEL,
                update_interval_seconds: UPDATE_INTERVAL_SECONDS,
                no_progress_seconds: NO_PROGRESS_SECONDS,
                timeout_seconds: TIMEOUT_SECONDS,
                orchestrator_session_key: orchestratorSessionKey,
                delivery: {
                    channel: deliveryChannel,
                    target: deliveryTargetCanonical,
                    ...(threadId !== undefined ? { thread_id: threadId } : {}),
                    ...(accountId ? { account_id: accountId } : {}),
                },
            };
            await mkdir(path.join(runDir, "control"), { recursive: true });
            await writeFile(specPath, `${JSON.stringify(resolvedSpec, null, 2)}\n`, "utf8");
            await writeFile(path.join(runDir, "status.json"), `${JSON.stringify({
                job_id: jobId,
                state: "queued",
                created_at: new Date().toISOString(),
                spec_path: specPath,
            }, null, 2)}\n`, "utf8");
            await writeFile(path.join(runDir, "events.jsonl"), `${JSON.stringify({
                ts: new Date().toISOString(),
                event: "queued",
                job_id: jobId,
                spec_path: specPath,
            })}\n`, { encoding: "utf8", flag: "a" });
            // Invoke through `bash` so we do not depend on the runner's executable
            // bit surviving copy/npm/ClawHub installs.
            const runner = runDetached("bash", [RUNNER_PATH, "--job", specPath], repo);
            await writeFile(path.join(runDir, "events.jsonl"), `${JSON.stringify({
                ts: new Date().toISOString(),
                event: "runner_started",
                job_id: jobId,
                runner_pid: runner.pid ?? null,
            })}\n`, { encoding: "utf8", flag: "a" });
            return jsonResult({
                status: "started",
                job_id: jobId,
                run_dir: runDir,
                spec_path: specPath,
                runner_pid: runner.pid ?? null,
            });
        },
    };
}
export default definePluginEntry({
    id: "marinator-delegation",
    name: "Marinator Delegation",
    description: "Delegate Marinator coding tasks through a bounded supervised opencode runner.",
    register(api) {
        api.registerTool((toolContext) => createMarinatorDelegateTool(toolContext), { name: "marinator_delegate" });
        api.registerToolMetadata({
            toolName: "marinator_delegate",
            displayName: "Marinator Delegate",
            description: "Create a Marinator run from task intent, inject current OpenClaw delivery context, and start the bounded runner.",
            risk: "medium",
            tags: ["coding", "delegation", "marinator"],
        });
        api.on("before_agent_run", handleBeforeAgentRun);
        api.on("agent_end", handleAgentEnd);
    },
});
