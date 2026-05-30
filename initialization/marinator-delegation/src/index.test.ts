import { describe, expect, it } from "vitest";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import entry, { handleAgentEnd, handleBeforeAgentRun, reconcileMarinatorStatuses } from "./index.js";

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

  it("surfaces stale scheduled and active handoffs as anomalies", async () => {
    const workspaceDir = await mkdtemp(path.join(os.tmpdir(), "marinator-test-"));
    const runDir = path.join(workspaceDir, ".openclaw", "state", "marinator", "runs", "job-2");
    const statusPath = path.join(runDir, "status.json");
    await mkdir(runDir, { recursive: true });
    await writeFile(statusPath, `${JSON.stringify({
      job_id: "job-2",
      state: "completed",
      handoff: { state: "scheduled", session_key: "agent:junie-live:def", scheduled_at: "2026-05-31T00:00:00.000Z" },
    }, null, 2)}\n`, "utf8");

    await reconcileMarinatorStatuses(workspaceDir, new Date("2026-05-31T01:00:00.000Z"), 30);
    const status = JSON.parse(await readFile(statusPath, "utf8"));
    expect(status.anomalies.map((item: { type: string }) => item.type)).toContain("handoff_scheduled_not_consumed");
  });
});
