import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineToolPlugin } from "openclaw/plugin-sdk/tool-plugin";
import { jsonResult } from "openclaw/plugin-sdk/core";
const SUMMARY_MODEL = "openrouter/openai/gpt-4.1-mini";
const UPDATE_INTERVAL_SECONDS = 60;
const NO_PROGRESS_SECONDS = 900;
const TIMEOUT_SECONDS = 7200;
const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REPO_ROOT = path.resolve(PLUGIN_ROOT, "..");
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
function runDetached(command, args, cwd) {
    const child = spawn(command, args, {
        cwd,
        detached: true,
        stdio: "ignore",
    });
    child.unref();
    return { pid: child.pid };
}
export default defineToolPlugin({
    id: "marinator-delegation",
    name: "Marinator Delegation",
    description: "Delegate Marinator coding tasks through a bounded supervised opencode runner.",
    tools: (tool) => [
        tool({
            name: "marinator_delegate",
            label: "Marinator Delegate",
            description: "Create a Marinator run from task intent, inject current OpenClaw delivery context, and start the bounded runner.",
            parameters,
            factory({ toolContext }) {
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
                        const runnerPath = path.join(REPO_ROOT, "scripts", "delegate-coding-task.sh");
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
                        const runner = runDetached(runnerPath, ["--job", specPath], repo);
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
            },
        }),
    ],
});
