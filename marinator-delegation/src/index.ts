import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { Type } from "typebox";
import { defineToolPlugin } from "openclaw/plugin-sdk/tool-plugin";
import { jsonResult } from "openclaw/plugin-sdk/core";

type MarinatorDelegateParams = {
  job_id: string;
  repo: string;
  prompt_file: string;
  attachments?: string[];
  opencode_previous_session_id?: string | null;
};

const SUMMARY_MODEL = "openai/gpt-4.1-mini";
const UPDATE_INTERVAL_SECONDS = 300;
const NO_PROGRESS_SECONDS = 900;
const TIMEOUT_SECONDS = 7200;

const parameters = Type.Object({
  job_id: Type.String({ description: "Stable Marinator job id. Allowed characters: letters, digits, dot, underscore, dash." }),
  repo: Type.String({ description: "Absolute path to the target repository." }),
  prompt_file: Type.String({ description: "Absolute path to the prompt file for opencode." }),
  attachments: Type.Optional(Type.Array(Type.String(), { description: "Optional attachment file paths for the worker." })),
  opencode_previous_session_id: Type.Optional(Type.Union([Type.String(), Type.Null()], { description: "Optional previous opencode session id for follow-up/resume." })),
});

function requireNonEmpty(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`marinator_delegate missing required ${label}`);
  }
  return value.trim();
}

function safeJobId(jobId: string): string {
  if (!/^[A-Za-z0-9._-]+$/.test(jobId)) {
    throw new Error("job_id may only contain letters, digits, dot, underscore, and dash");
  }
  if (jobId === "." || jobId === "..") {
    throw new Error("job_id must not be a path traversal segment");
  }
  return jobId;
}

function resolveWorkspaceDir(agentDir?: string, workspaceDir?: string): string {
  if (workspaceDir && workspaceDir.trim()) return workspaceDir;
  if (agentDir && agentDir.trim()) return agentDir;
  return process.cwd();
}

function runDetached(command: string, args: string[], cwd: string): { pid?: number } {
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
            const input = params as MarinatorDelegateParams;
            const jobId = safeJobId(requireNonEmpty(input.job_id, "job_id"));
            const repo = path.resolve(requireNonEmpty(input.repo, "repo"));
            const promptFile = path.resolve(requireNonEmpty(input.prompt_file, "prompt_file"));
            const workspaceDir = resolveWorkspaceDir(toolContext.agentDir, toolContext.workspaceDir);
            const orchestratorSessionKey = requireNonEmpty(toolContext.sessionKey, "toolContext.sessionKey");
            const deliveryContext = toolContext.deliveryContext;
            const deliveryChannel = requireNonEmpty(deliveryContext?.channel, "toolContext.deliveryContext.channel");
            const deliveryTarget = requireNonEmpty(deliveryContext?.to, "toolContext.deliveryContext.to");
            const threadId = deliveryContext?.threadId;
            const accountId = deliveryContext?.accountId ?? toolContext.agentAccountId;
            const runDir = path.join(workspaceDir, ".openclaw", "state", "marinator", "runs", jobId);
            const specPath = path.join(runDir, "spec.json");
            const runnerPath = path.join(repo, "scripts", "delegate-coding-task.sh");

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
                target: deliveryTarget,
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
