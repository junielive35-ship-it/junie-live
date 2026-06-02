import { describe, expect, it } from "vitest";
import { chmod, mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import entry, { applyCronRunHistoryToStatus, handleAgentEnd, handleBeforeAgentRun, reconcileMarinatorStatuses, resolveDeliverySpec } from "./index.js";
import type { MarinatorStatus } from "./index.js";

const execFileAsync = promisify(execFile);

async function writeFakeOpenclaw(binDir: string) {
  const openclawBin = path.join(binDir, "openclaw");
  await writeFile(openclawBin, `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "cron" && "\${2:-}" == "add" ]]; then
  printf '{"id":"cron-test"}\n'
  exit 0
fi
if [[ "\${1:-}" == "infer" ]]; then
  printf '{"text":"summary"}\n'
  exit 0
fi
if [[ "\${1:-}" == "system" && "\${2:-}" == "event" ]]; then
  exit 0
fi
if [[ "\${1:-}" == "message" && "\${2:-}" == "send" ]]; then
  exit 0
fi
exit 0
`, "utf8");
  await chmod(openclawBin, 0o755);
}

async function writeRunnerJob(workspaceDir: string, runDir: string, repo: string, promptFile: string, jobFile: string, overrides: Record<string, unknown> = {}) {
  await writeFile(jobFile, `${JSON.stringify({
    job_id: "job-runner-test",
    repo,
    prompt_file: promptFile,
    run_dir: runDir,
    update_interval_seconds: 300,
    no_progress_seconds: 300,
    timeout_seconds: 30,
    orchestrator_session_key: "agent:junie-live:test",
    delivery: { channel: "telegram", target: "test" },
    ...overrides,
  }, null, 2)}\n`, "utf8");
}

async function readEvents(runDir: string) {
  return (await readFile(path.join(runDir, "events.jsonl"), "utf8"))
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as { event: string });
}

describe("marinator-delegation", () => {
  it("declares Marinator delegation plugin metadata", () => {
    expect(entry.id).toBe("marinator-delegation");
    expect(entry.name).toBe("Marinator Delegation");
    expect(typeof entry.register).toBe("function");
  });

  it("resolves delivery spec when delivery context is present and allows headless sessions without delivery target", () => {
    expect(resolveDeliverySpec({
      deliveryContext: { channel: "telegram", to: "telegram:400847234:topic:7" },
      agentAccountId: "junie-live",
    })).toEqual({ channel: "telegram", target: "400847234", threadId: "7", accountId: "junie-live" });

    expect(resolveDeliverySpec({ sessionKey: "agent:junie-live:headless" })).toBeNull();
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
    const anomalies = status.anomalies.filter((item: { type: string }) => item.type === "handoff_scheduled_not_consumed");
    expect(anomalies).toHaveLength(1);
    expect(anomalies[0].detail).toContain("schedule_job_id=cron-2");
    expect(anomalies[0].detail).toContain("retry_state=unknown");
  });

  it("marks setup timeout cron evidence as retrying with accounting fields", () => {
    const status = applyCronRunHistoryToStatus({
      job_id: "job-retry",
      handoff: {
        state: "scheduled",
        schedule_job_id: "cron-retry",
        scheduled_at: "2026-05-31T00:00:00.000Z",
      },
    }, {
      job: { state: { nextRunAtMs: Date.parse("2026-05-31T00:05:00.000Z"), consecutiveErrors: 2 } },
      entries: [{ status: "error", error: "setup timed out before runner start", runAt: "2026-05-31T00:00:00.000Z", durationMs: 30000 }],
    }, new Date("2026-05-31T00:01:00.000Z"));

    expect(status.handoff?.retry_state).toBe("retrying");
    expect(status.handoff?.consecutive_errors).toBe(2);
    expect(status.handoff?.next_retry_at).toBe("2026-05-31T00:05:00.000Z");
    expect(status.handoff?.last_checked_at).toBe("2026-05-31T00:01:00.000Z");
    expect(status.handoff?.run_history).toEqual([{
      checked_at: "2026-05-31T00:01:00.000Z",
      status: "error",
      error: "setup timed out before runner start",
      run_at: "2026-05-31T00:00:00.000Z",
      duration_ms: 30000,
      next_retry_at: "2026-05-31T00:05:00.000Z",
    }]);
  });

  it("does not rewrite consumed handoff from cron history", () => {
    const status: MarinatorStatus = {
      job_id: "job-consumed",
      handoff: {
        state: "consumed",
        retry_state: "none" as const,
        consumed_by_run_id: "run-1",
        consumed_at: "2026-05-31T00:02:00.000Z",
      },
    };

    expect(applyCronRunHistoryToStatus(status, {
      job: { nextRunAtMs: Date.parse("2026-05-31T00:05:00.000Z"), state: { consecutiveErrors: 2 } },
      entries: [{ status: "error", error: "setup timed out before runner start" }],
    })).toBe(status);
    expect(status.handoff).toEqual({
      state: "consumed",
      retry_state: "none",
      consumed_by_run_id: "run-1",
      consumed_at: "2026-05-31T00:02:00.000Z",
    });
  });

  it("dedupes and caps cron run history while reconciliation anomalies remain unique", async () => {
    const status: MarinatorStatus = {
      job_id: "job-history",
      handoff: {
        state: "scheduled",
        schedule_job_id: "cron-history",
        scheduled_at: "2026-05-31T00:00:00.000Z",
      },
    };

    for (let i = 0; i < 12; i += 1) {
      applyCronRunHistoryToStatus(status, {
        job: { nextRunAtMs: Date.parse("2026-05-31T00:30:00.000Z"), state: { consecutiveErrors: i + 1 } },
        entries: [
          { status: "error", error: "setup timed out before runner start", runAt: `2026-05-31T00:${String(i).padStart(2, "0")}:00.000Z` },
          { status: "error", error: "setup timed out before runner start", runAt: `2026-05-31T00:${String(i).padStart(2, "0")}:00.000Z` },
        ],
      }, new Date(`2026-05-31T00:${String(i).padStart(2, "0")}:30.000Z`));
    }

    expect(status.handoff).toBeDefined();
    const handoff = status.handoff!;
    expect(handoff.run_history).toHaveLength(10);
    expect(handoff.run_history?.[0].run_at).toBe("2026-05-31T00:02:00.000Z");
    expect(handoff.consecutive_errors).toBe(12);

    const workspaceDir = await mkdtemp(path.join(os.tmpdir(), "marinator-test-"));
    const runDir = path.join(workspaceDir, ".openclaw", "state", "marinator", "runs", "job-history");
    const statusPath = path.join(runDir, "status.json");
    await mkdir(runDir, { recursive: true });
    await writeFile(statusPath, `${JSON.stringify(status, null, 2)}\n`, "utf8");

    await reconcileMarinatorStatuses(workspaceDir, new Date("2026-05-31T01:00:00.000Z"), 30);
    await reconcileMarinatorStatuses(workspaceDir, new Date("2026-05-31T01:10:00.000Z"), 30);
    const reconciled = JSON.parse(await readFile(statusPath, "utf8"));
    expect(reconciled.anomalies.filter((item: { type: string }) => item.type === "handoff_scheduled_not_consumed")).toHaveLength(1);
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

  it("schedules durable handoff after control_kill", async () => {
    const workspaceDir = await mkdtemp(path.join(os.tmpdir(), "marinator-runner-test-"));
    const binDir = path.join(workspaceDir, "bin");
    const repoDir = path.join(workspaceDir, "repo");
    const runDir = path.join(workspaceDir, "run");
    const promptFile = path.join(workspaceDir, "prompt.txt");
    const jobFile = path.join(workspaceDir, "job.json");
    await mkdir(binDir, { recursive: true });
    await mkdir(repoDir, { recursive: true });
    await mkdir(runDir, { recursive: true });
    await writeFile(promptFile, "keep running", "utf8");
    await writeFakeOpenclaw(binDir);

    const opencodeBin = path.join(binDir, "opencode");
    await writeFile(opencodeBin, `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "run" && "\${2:-}" == "--help" ]]; then
  exit 0
fi
mkdir -p "$FAKE_RUN_DIR/control"
touch "$FAKE_RUN_DIR/control/kill"
sleep 60
`, "utf8");
    await chmod(opencodeBin, 0o755);
    await writeRunnerJob(workspaceDir, runDir, repoDir, promptFile, jobFile);

    await expect(execFileAsync(path.resolve("scripts/delegate-coding-task.sh"), ["--job", jobFile], {
      cwd: path.resolve("."),
      env: { ...process.env, PATH: `${binDir}:${process.env.PATH ?? ""}`, OPENCODE_BIN: opencodeBin, FAKE_RUN_DIR: runDir },
      timeout: 15_000,
    })).rejects.toMatchObject({ code: 130 });

    const eventNames = (await readEvents(runDir)).map((event) => event.event);
    expect(eventNames).toContain("killed");
    expect(eventNames).toContain("handoff_pending");
    expect(eventNames).toContain("handoff_scheduled");
    expect(eventNames.indexOf("handoff_pending")).toBeGreaterThan(eventNames.indexOf("killed"));
    expect(eventNames.indexOf("handoff_scheduled")).toBeGreaterThan(eventNames.indexOf("handoff_pending"));
  }, 20_000);

  it("schedules durable handoff after early setup failure", async () => {
    const workspaceDir = await mkdtemp(path.join(os.tmpdir(), "marinator-runner-test-"));
    const binDir = path.join(workspaceDir, "bin");
    const repoDir = path.join(workspaceDir, "missing-repo");
    const runDir = path.join(workspaceDir, "run");
    const promptFile = path.join(workspaceDir, "prompt.txt");
    const jobFile = path.join(workspaceDir, "job.json");
    await mkdir(binDir, { recursive: true });
    await mkdir(runDir, { recursive: true });
    await writeFile(promptFile, "setup should fail", "utf8");
    await writeFakeOpenclaw(binDir);

    const opencodeBin = path.join(binDir, "opencode");
    await writeFile(opencodeBin, `#!/usr/bin/env bash
exit 0
`, "utf8");
    await chmod(opencodeBin, 0o755);
    await writeRunnerJob(workspaceDir, runDir, repoDir, promptFile, jobFile);

    await expect(execFileAsync(path.resolve("scripts/delegate-coding-task.sh"), ["--job", jobFile], {
      cwd: path.resolve("."),
      env: { ...process.env, PATH: `${binDir}:${process.env.PATH ?? ""}`, OPENCODE_BIN: opencodeBin },
      timeout: 10_000,
    })).rejects.toMatchObject({ code: 66 });

    const eventNames = (await readEvents(runDir)).map((event) => event.event);
    expect(eventNames).toContain("failed");
    expect(eventNames).toContain("handoff_pending");
    expect(eventNames).toContain("handoff_scheduled");
    expect(eventNames.indexOf("handoff_pending")).toBeGreaterThan(eventNames.indexOf("failed"));
    expect(eventNames.indexOf("handoff_scheduled")).toBeGreaterThan(eventNames.indexOf("handoff_pending"));
  });

  it("starts runner and schedules durable handoff when delivery spec is absent", async () => {
    const workspaceDir = await mkdtemp(path.join(os.tmpdir(), "marinator-runner-test-"));
    const binDir = path.join(workspaceDir, "bin");
    const repoDir = path.join(workspaceDir, "repo");
    const runDir = path.join(workspaceDir, "run");
    const promptFile = path.join(workspaceDir, "prompt.txt");
    const jobFile = path.join(workspaceDir, "job.json");
    await mkdir(binDir, { recursive: true });
    await mkdir(repoDir, { recursive: true });
    await mkdir(runDir, { recursive: true });
    await writeFile(promptFile, "headless setup should not require delivery", "utf8");
    await writeFakeOpenclaw(binDir);

    const opencodeBin = path.join(binDir, "opencode");
    await writeFile(opencodeBin, `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "run" && "\${2:-}" == "--help" ]]; then
  exit 0
fi
exit 0
`, "utf8");
    await chmod(opencodeBin, 0o755);

    await writeFile(jobFile, `${JSON.stringify({
      job_id: "job-headless-runner-test",
      repo: repoDir,
      prompt_file: promptFile,
      run_dir: runDir,
      update_interval_seconds: 300,
      no_progress_seconds: 300,
      timeout_seconds: 30,
      orchestrator_session_key: "agent:junie-live:headless",
    }, null, 2)}
`, "utf8");

    await execFileAsync(path.resolve("scripts/delegate-coding-task.sh"), ["--job", jobFile], {
      cwd: path.resolve("."),
      env: { ...process.env, PATH: `${binDir}:${process.env.PATH ?? ""}`, OPENCODE_BIN: opencodeBin },
      timeout: 10_000,
    });

    const eventNames = (await readEvents(runDir)).map((event) => event.event);
    expect(eventNames).toContain("started");
    expect(eventNames).toContain("opencode_started");
    expect(eventNames).toContain("completed");
    expect(eventNames).toContain("handoff_scheduled");
  });

});
