import { describe, it, expect, vi } from "vitest";
import { relayOnce, toEnvelope, type OutboxRow } from "./outbox-relay.worker.js";
import { EVENT_TYPES } from "@tekisho/domain";

// A representative outbox row (aggregate stored flat, as the table holds it).
function makeRow(overrides: Partial<OutboxRow> = {}): OutboxRow {
  return {
    id: "1",
    event_id: "11111111-1111-1111-1111-111111111111",
    event_type: EVENT_TYPES.MATCH_COMPLETED,
    schema_version: "1.0",
    organization_id: "22222222-2222-2222-2222-222222222222",
    aggregate_type: "requirement",
    aggregate_id: "33333333-3333-3333-3333-333333333333",
    correlation_id: "44444444-4444-4444-4444-444444444444",
    causation_id: null,
    producer: "api",
    payload_ref: { match_job_id: "job-1", requirement_id: "req-1", result_count: 3 },
    occurred_at: new Date("2026-01-01T00:00:00.000Z"),
    ...overrides,
  };
}

// A fake pg client whose query() returns queued results in order, and records
// every call so we can assert what SQL the relay ran.
function makeFakePool(pendingRows: OutboxRow[]) {
  const calls: Array<{ sql: string; params?: unknown[] }> = [];
  const client = {
    query: vi.fn(async (sql: string, params?: unknown[]) => {
      calls.push({ sql, params });
      // The SELECT of pending rows is the only query that returns rows.
      if (sql.includes("FROM event_outbox") && sql.includes("published_at IS NULL")) {
        return { rows: pendingRows };
      }
      // BEGIN / UPDATE / COMMIT return nothing meaningful.
      return { rows: [] };
    }),
    release: vi.fn(),
  };
  const pool = { connect: vi.fn(async () => client) };
  return { pool, client, calls };
}

// A fake pg-boss that just records what was sent.
function makeFakeBoss() {
  const sent: Array<{ queue: string; data: unknown; options: unknown }> = [];
  const boss = {
    send: vi.fn(async (queue: string, data: unknown, options: unknown) => {
      sent.push({ queue, data, options });
      return "job-id";
    }),
  };
  return { boss, sent };
}

describe("toEnvelope", () => {
  it("composes the flat outbox row into the nested wire envelope", () => {
    const env = toEnvelope(makeRow());
    expect(env.event_id).toBe("11111111-1111-1111-1111-111111111111");
    expect(env.event_type).toBe(EVENT_TYPES.MATCH_COMPLETED);
    // aggregate_type + aggregate_id become the nested aggregate object.
    expect(env.aggregate).toEqual({
      type: "requirement",
      id: "33333333-3333-3333-3333-333333333333",
    });
    // occurred_at is serialized to ISO.
    expect(env.occurred_at).toBe("2026-01-01T00:00:00.000Z");
    expect(env.payload_ref).toEqual({
      match_job_id: "job-1",
      requirement_id: "req-1",
      result_count: 3,
    });
  });
});

describe("relayOnce", () => {
  it("publishes each pending row and reports how many were processed", async () => {
    const rows = [makeRow({ id: "1" }), makeRow({ id: "2", event_id: "aaaaaaaa-1111-1111-1111-111111111111" })];
    const { pool } = makeFakePool(rows);
    const { boss, sent } = makeFakeBoss();

    const processed = await relayOnce(pool as never, boss as never);

    expect(processed).toBe(2);
    expect(sent).toHaveLength(2);
    // Publishes to the dispatch queue with the per-aggregate singletonKey.
    expect(sent[0]?.queue).toBe("orchestration.dispatch");
    expect((sent[0]?.options as { singletonKey: string }).singletonKey).toBe(
      "33333333-3333-3333-3333-333333333333",
    );
  });

  it("marks the published rows via an UPDATE keyed on their ids", async () => {
    const rows = [makeRow({ id: "7" }), makeRow({ id: "9", event_id: "bbbbbbbb-1111-1111-1111-111111111111" })];
    const { pool, calls } = makeFakePool(rows);
    const { boss } = makeFakeBoss();

    await relayOnce(pool as never, boss as never);

    const update = calls.find((c) => c.sql.includes("SET published_at = now()"));
    expect(update).toBeDefined();
    // The UPDATE is parameterized with the exact ids that were published.
    expect(update?.params?.[0]).toEqual(["7", "9"]);
  });

  it("does nothing and returns 0 when the outbox is empty", async () => {
    const { pool } = makeFakePool([]);
    const { boss, sent } = makeFakeBoss();

    const processed = await relayOnce(pool as never, boss as never);

    expect(processed).toBe(0);
    expect(sent).toHaveLength(0);
  });

  it("rolls back if publishing throws (never marks published on failure)", async () => {
    const rows = [makeRow()];
    const { pool, calls } = makeFakePool(rows);
    const boss = { send: vi.fn(async () => { throw new Error("queue down"); }) };

    await expect(relayOnce(pool as never, boss as never)).rejects.toThrow("queue down");

    // A ROLLBACK was issued and no UPDATE published_at ran.
    expect(calls.some((c) => c.sql.includes("ROLLBACK"))).toBe(true);
    expect(calls.some((c) => c.sql.includes("SET published_at"))).toBe(false);
  });
});
