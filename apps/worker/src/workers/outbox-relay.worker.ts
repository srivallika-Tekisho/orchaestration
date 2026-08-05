// Outbox relay worker.
//
// The ONLY publisher into pg-boss. Reads unpublished rows from event_outbox,
// composes the wire envelope, publishes each to the dispatch queue, and marks
// the row published — so business writes never touch the queue directly
// (the transactional outbox pattern).

import { Pool } from "pg";
import { PgBoss } from "pg-boss";
import { env } from "../env.js";
import type { EventEnvelope, EventType } from "@tekisho/domain";

// The queue the orchestrator's dispatcher consumes from. Must match exactly
// on the consumer side.
export const DISPATCH_QUEUE = "orchestration.dispatch";
export const DISPATCH_DLQ = "orchestration.dispatch.dlq";

const BATCH_SIZE = 100;
const POLL_INTERVAL_MS = 1000;

// Retry policy for the dispatch queue. Applied to jobs the CONSUMER
// (the orchestrator dispatcher) processes: if its handler throws, pg-boss
// re-runs the job up to retryLimit times with exponential backoff. After
// the retries are exhausted, the job moves to the dead-letter queue instead
// of just failing, so nothing is silently lost.
const RETRY_LIMIT = 5;
const RETRY_DELAY_SECONDS = 5;

export interface OutboxRow {
  id: string; // bigint returns as string from pg
  event_id: string;
  event_type: EventType;
  schema_version: string;
  organization_id: string;
  aggregate_type: string;
  aggregate_id: string;
  correlation_id: string;
  causation_id: string | null;
  producer: string;
  payload_ref: Record<string, unknown>;
  occurred_at: Date;
}

export function toEnvelope(row: OutboxRow): EventEnvelope {
  return {
    event_id: row.event_id,
    event_type: row.event_type,
    schema_version: row.schema_version,
    occurred_at: row.occurred_at.toISOString(),
    correlation_id: row.correlation_id,
    causation_id: row.causation_id,
    organization_id: row.organization_id,
    aggregate: { type: row.aggregate_type, id: row.aggregate_id },
    payload_ref: row.payload_ref,
    producer: row.producer,
  };
}

export async function relayOnce(pool: Pool, boss: PgBoss): Promise<number> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const { rows } = await client.query<OutboxRow>(
      `SELECT id, event_id, event_type, schema_version, organization_id,
              aggregate_type, aggregate_id, correlation_id, causation_id,
              producer, payload_ref, occurred_at
         FROM event_outbox
        WHERE published_at IS NULL
        ORDER BY id
        FOR UPDATE SKIP LOCKED
        LIMIT $1`,
      [BATCH_SIZE],
    );

    if (rows.length === 0) {
      await client.query("COMMIT");
      return 0;
    }

    const publishedIds: string[] = [];
    for (const row of rows) {
      const envelope = toEnvelope(row);
      await boss.send(DISPATCH_QUEUE, envelope, {
        singletonKey: row.aggregate_id, // serialize per aggregate
      });
      publishedIds.push(row.id);
    }

    await client.query(
      `UPDATE event_outbox
          SET published_at = now()
        WHERE id = ANY($1::bigint[])`,
      [publishedIds],
    );

    await client.query("COMMIT");
    return rows.length;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}

export async function startOutboxRelay(): Promise<() => Promise<void>> {
  const pool = new Pool({
    connectionString: env.DATABASE_MIGRATOR_URL,
    ssl: { rejectUnauthorized: false },
  });

  const boss = new PgBoss({
    connectionString: env.DATABASE_MIGRATOR_URL,
    schema: "pgboss",
    ssl: { rejectUnauthorized: false },
  });
  await boss.start();

  // Dead-letter queue must exist before the main queue can reference it.
  await boss.createQueue(DISPATCH_DLQ);

  // Main dispatch queue, with retry policy + dead-letter routing baked in.
  // The consumer inherits these settings; the relay (publisher) just needs
  // the queue to exist.
  await boss.createQueue(DISPATCH_QUEUE, {
    retryLimit: RETRY_LIMIT,
    retryDelay: RETRY_DELAY_SECONDS,
    retryBackoff: true,
    deadLetter: DISPATCH_DLQ,
  });

  let stopped = false;

  const loop = async (): Promise<void> => {
    while (!stopped) {
      try {
        let processed = 0;
        do {
          processed = await relayOnce(pool, boss);
        } while (processed === BATCH_SIZE && !stopped);
      } catch (error) {
        console.error("outbox relay tick failed:", error);
      }
      if (!stopped) {
        await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
      }
    }
  };

  void loop();
  console.log(`Outbox relay started → queue "${DISPATCH_QUEUE}"`);

  return async () => {
    stopped = true;
    await boss.stop();
    await pool.end();
    console.log("Outbox relay stopped");
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  startOutboxRelay()
    .then((stop) => {
      const shutdown = () => void stop().then(() => process.exit(0));
      process.on("SIGINT", shutdown);
      process.on("SIGTERM", shutdown);
    })
    .catch((error) => {
      console.error("Failed to start outbox relay:", error);
      process.exitCode = 1;
    });
}