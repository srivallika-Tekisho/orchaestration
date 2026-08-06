import * as PgBossModule from "pg-boss";
import { env } from "./env.js";
import pg from 'pg';
import { SimpleRunbookResolver } from "@tekisho/orchestrator/src/resolver/runbook.js";
import { WorkflowRegistry } from "@tekisho/orchestrator/src/workflow/registry.js";
import { WorkflowRunner } from "@tekisho/orchestrator/src/workflow/runner.js";
import { jdGraph, resumeGraph, matchGraph } from "@tekisho/orchestrator/src/workflow/graphs/syntra.js";
import { EVENT_TYPES } from "@tekisho/domain";
import type { EventEnvelope } from "@tekisho/domain";
import type { EventInput } from "@tekisho/orchestrator/src/types.js";
import { v4 as uuidv4 } from "uuid";

// Syntra publishes jd.uploaded with a minimal payload { jobId }. The orchestrator
// runbook keys off syntra.jd.received, so we translate the queue name and
// synthesize the envelope fields Syntra doesn't send. Org id must exist in
// public.organizations (Test Org) so the final event_outbox write doesn't fail.
const SYNTRA_TEST_ORG_ID = "2b8e12b3-1745-4ae9-902c-5a249c28ba94";

const databaseUrl = new URL(env.DATABASE_MIGRATOR_URL);

console.log("Database connection target:", {
  username: decodeURIComponent(databaseUrl.username),
  passwordLength: decodeURIComponent(databaseUrl.password).length,
  hostname: databaseUrl.hostname,
  port: databaseUrl.port,
  database: databaseUrl.pathname,
});

async function bootstrapPgBoss(): Promise<void> {
  console.log("Starting pg-boss bootstrap & dispatcher...");

  // Supabase session-mode pooler caps clients at pool_size (often 15). Default
  // pg.Pool/pg-boss max is 10 each — two pools alone blow past the limit.
  const boss = new PgBossModule.PgBoss({
    connectionString: env.DATABASE_MIGRATOR_URL,
    schema: "pgboss",
    ssl: { rejectUnauthorized: false },
    max: 3,
  });

  // Transient pooler errors (EMAXCONNSESSION) must not crash the process.
  boss.on("error", (error: unknown) => {
    console.error("[Dispatcher] pg-boss error:", error);
  });

  await boss.start();
  console.log("pg-boss tables created successfully");

  // Construct Resolver & Registry
  const resolver = new SimpleRunbookResolver({
    [EVENT_TYPES.JD_RECEIVED]: 'syntra.jd.workflow',
    [EVENT_TYPES.RESUME_RECEIVED]: 'syntra.resume.workflow',
    'syntra.match.requested': 'syntra.match.workflow'
  });
  const registry = new WorkflowRegistry();
  registry.register('syntra.jd.workflow', jdGraph);
  registry.register('syntra.resume.workflow', resumeGraph);
  registry.register('syntra.match.workflow', matchGraph);

  // Construct Pool for WorkflowRunner — keep small; shares the same pooler budget.
  const pool = new pg.Pool({
    connectionString: env.DATABASE_MIGRATOR_URL,
    ssl: { rejectUnauthorized: false },
    max: 2,
  });

  const runner = new WorkflowRunner(registry, pool);

  console.log("Listening for orchestration.dispatch events...");
  await boss.createQueue("orchestration.dispatch");
  
  await boss.work("orchestration.dispatch", async (jobs: any) => {
    for (const job of jobs) {
      const envelope = job.data as EventEnvelope;
      
      console.log(`[Dispatcher] Received event: ${envelope.event_type} (ID: ${envelope.event_id})`);

      try {
        const workflowName = resolver.resolve(envelope.event_type, {
          organization_id: envelope.organization_id,
          payload: envelope.payload_ref
        });
        
        const eventInput: EventInput = {
          event_id: envelope.event_id,
          event_type: envelope.event_type,
          aggregate_id: envelope.aggregate.id,
          aggregate_type: envelope.aggregate.type,
          organization_id: envelope.organization_id,
          correlation_id: envelope.correlation_id,
          payload: envelope.payload_ref
        };
        
        const result = await runner.executeWorkflow(workflowName, eventInput);
        
        if (result.status === 'FAILED') {
          console.error(`[Dispatcher] Workflow failed: ${result.error}`);
          throw new Error(result.error);
        }
        
        console.log(`[Dispatcher] Workflow ${workflowName} completed successfully.`);
      } catch (error) {
        console.error(`[Dispatcher] Error processing job ${job.id}:`, error);
        throw error; // Let pg-boss handle retry/dlq
      }
    }
  });

  // Map each Syntra queue to its runbook event type + how to extract ids.
  const SYNTRA_QUEUES = [
    { queue: "jd.uploaded",      eventType: EVENT_TYPES.JD_RECEIVED },
    { queue: "resume.uploaded",  eventType: EVENT_TYPES.RESUME_RECEIVED },
    { queue: "match.requested",  eventType: "syntra.match.requested" },
  ];

  for (const { queue, eventType } of SYNTRA_QUEUES) {
    await boss.createQueue(queue);
    await boss.work(queue, async (jobs: any) => {
      for (const job of jobs) {
        console.log(`[Dispatcher] Received ${queue}:`, job.data);
        try {
          const eventInput: EventInput = {
            event_id: uuidv4(),
            event_type: eventType,
            aggregate_id: job.data.jobId || job.data.resumeId || uuidv4(),
            aggregate_type: "requirement",
            organization_id: SYNTRA_TEST_ORG_ID,
            correlation_id: uuidv4(),
            payload: job.data,   // pass Syntra's payload straight through
          };
          const workflowName = resolver.resolve(eventInput.event_type, {
            organization_id: eventInput.organization_id,
            payload: eventInput.payload,
          });
          const result = await runner.executeWorkflow(workflowName, eventInput);
          if (result.status === "FAILED") throw new Error(result.error);
          console.log(`[Dispatcher] ${queue} → ${workflowName} completed.`);
        } catch (error) {
          console.error(`[Dispatcher] Error on ${queue} job ${job.id}:`, error);
          throw error;
        }
      }
    });
  }

  // Graceful shutdown handling
  const shutdown = async () => {
    console.log("\nShutting down dispatcher...");
    await boss.stop();
    await pool.end();
    process.exit(0);
  };
  
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

bootstrapPgBoss().catch((error: unknown) => {
  console.error("pg-boss bootstrap failed:", error);
  process.exitCode = 1;
});