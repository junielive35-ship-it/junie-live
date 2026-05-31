import { describe, expect, it } from "vitest";
import { chmod, mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import entry, { handleAgentEnd, handleBeforeAgentRun, reconcileMarinatorStatuses } from "./index.js";
const execFileAsync = promisify(execFile);
describe("marinator-delegation", () => {
    it("declares Marinator delegation plugin metadata", () => {
        expect(entry.id).toBe("marinator-delegation");
        expect(entry.name).toBe("Marinator Delegation");
        expect(typeof entry.register).toBe("function");
    });
    it("consumes matching scheduled handoff on before_agent_run and ends it on agent_end", async () => {
        const workspaceDir = await mkdtemp(path.join(os.tmpdir(), "marinator-test-"));
        const runDir = path.join(workspaceDir, ".openclaw", "state", "marinator", "runs", "job-1");
        const statusPath = path.join(runDir, "status.json");
        await mkdir(runDir, { recursive: true });
        await writeFile(statusPath, `${JSON.stringify({
            job_id: "job-1",
            state: "completed",
            handoff: {
                state: "scheduled",
                session_key: "agent:junie-live:abc",
                schedule_job_id: "cron-1",
                scheduled_at: "2026-05-31T00:00:00.000Z",
                consumed_by_run_id: null,
                consumed_at: null,
                last_error: null,
            },
        }, null, 2)}\n`, "utf8");
        await handleBeforeAgentRun({}, { workspaceDir, sessionKey: "agent:junie-live:abc", runId: "run-1" });
        let status = JSON.parse(await readFile(statusPath, "utf8"));
        expect(status.handoff.state).toBe("consumed");
        expect(status.handoff.consumed_by_run_id).toBe("run-1");
        expect(status.active_run).toMatchObject({ sessionKey: "agent:junie-live:abc", runId: "run-1", state: "active" });
        await handleAgentEnd({}, { workspaceDir, sessionKey: "agent:junie-live:abc", runId: "run-1" });
        status = JSON.parse(await readFile(statusPath, "utf8"));
        expect(status.active_run.state).toBe("ended");
        expect(status.active_run.endedAt).toBeTruthy();
    });
    it("surfaces stale scheduled handoffs with schedule id and avoids duplicate anomalies", async () => {
        const workspaceDir = await mkdtemp(path.join(os.tmpdir(), "marinator-test-"));
        const runDir = path.join(workspaceDir, ".openclaw", "state", "marinator", "runs", "job-2");
        const statusPath = path.join(runDir, "status.json");
        await mkdir(runDir, { recursive: true });
        await writeFile(statusPath, `${JSON.stringify({
            job_id: "job-2",
            state: "completed",
            handoff: {
                state: "scheduled",
                session_key: "agent:junie-live:def",
                schedule_job_id: "cron-2",
                scheduled_at: "2026-05-31T00:00:00.000Z",
            },
        }, null, 2)}\n`, "utf8");
        await reconcileMarinatorStatuses(workspaceDir, new Date("2026-05-31T01:00:00.000Z"), 30);
        await reconcileMarinatorStatuses(workspaceDir, new Date("2026-05-31T01:10:00.000Z"), 30);
        const status = JSON.parse(await readFile(statusPath, "utf8"));
        const anomalies = status.anomalies.filter((item) => item.type === "handoff_scheduled_not_consumed");
        expect(anomalies).toHaveLength(1);
        expect(anomalies[0].detail).toContain("schedule_job_id=cron-2");
    });
    it("passes skip-permissions when opencode help prints the flag on stderr only and records cron id from noisy JSON", async () => {
        const workspaceDir = await mkdtemp(path.join(os.tmpdir(), "marinator-runner-test-"));
        const binDir = path.join(workspaceDir, "bin");
        const repoDir = path.join(workspaceDir, "repo");
        const runDir = path.join(workspaceDir, "run");
        const promptFile = path.join(workspaceDir, "prompt.txt");
        const jobFile = path.join(workspaceDir, "job.json");
        const argsFile = path.join(workspaceDir, "opencode-args.txt");
        await mkdir(binDir, { recursive: true });
        await mkdir(repoDir, { recursive: true });
        await mkdir(runDir, { recursive: true });
        await writeFile(promptFile, "Say exactly: flag accepted", "utf8");
        const opencodeBin = path.join(binDir, "opencode");
        await writeFile(opencodeBin, `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "run" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' 'Usage: opencode run [options]' >&2
  printf '%s\n' '  --dangerously-skip-permissions  auto-approve permissions' >&2
  exit 0
fi
printf '%s\n' "$*" > "$FAKE_OPENCODE_ARGS_FILE"
exit 0
`, "utf8");
        await chmod(opencodeBin, 0o755);
        const openclawBin = path.join(binDir, "openclaw");
        await writeFile(openclawBin, `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "cron" && "\${2:-}" == "add" ]]; then
  printf '%s\n' 'No --agent specified; the job will run with the configured default agent.'
  printf '{"id":"cron-noisy-test"}\n'
  exit 0
fi
if [[ "\${1:-}" == "infer" ]]; then
  printf '{"text":"summary"}\n'
  exit 0
fi
exit 0
`, "utf8");
        await chmod(openclawBin, 0o755);
        await writeFile(jobFile, `${JSON.stringify({
            job_id: "job-stderr-help",
            repo: repoDir,
            prompt_file: promptFile,
            run_dir: runDir,
            update_interval_seconds: 300,
            no_progress_seconds: 300,
            timeout_seconds: 30,
            orchestrator_session_key: "agent:junie-live:test",
            delivery: { channel: "telegram", target: "test" },
        }, null, 2)}\n`, "utf8");
        const scriptPath = path.resolve("scripts/delegate-coding-task.sh");
        await execFileAsync(scriptPath, ["--job", jobFile], {
            cwd: path.resolve("."),
            env: {
                ...process.env,
                PATH: `${binDir}:${process.env.PATH ?? ""}`,
                OPENCODE_BIN: opencodeBin,
                FAKE_OPENCODE_ARGS_FILE: argsFile,
            },
            timeout: 10_000,
        });
        const args = await readFile(argsFile, "utf8");
        expect(args).toContain("--dangerously-skip-permissions");
        const events = await readFile(path.join(runDir, "events.jsonl"), "utf8");
        expect(events).not.toContain("opencode_skip_permissions_flag_unavailable");
        expect(events).toContain('"schedule_job_id": "cron-noisy-test"');
        const status = JSON.parse(await readFile(path.join(runDir, "status.json"), "utf8"));
        expect(status.handoff.schedule_job_id).toBe("cron-noisy-test");
    });
});
