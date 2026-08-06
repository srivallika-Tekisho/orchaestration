import * as PgBossModule from "pg-boss";
import { env } from "./env.js";
import pg from 'pg';
import { SimpleRunbookResolver } from "@tekisho/orchestrator/src/resolver/runbook.js";
import { GraphCompiler } from "@tekisho/orchestrator/src/graphs/compiler.js";
import type { GraphDefinition } from "@tekisho/orchestrator/src/graphs/compiler.js";
import { WorkflowRunner } from "@tekisho/orchestrator/src/workflow/runner.js";
import { EVENT_TYPES } from "@tekisho/domain";
import type { EventEnvelope } from "@tekisho/domain";
import type { EventInput } from "@tekisho/orchestrator/src/types.js";

const databaseUrl = new URL(env.DATABASE_MIGRATOR_URL);

console.log("Database connection target:", {
  username: decodeURIComponent(databaseUrl.username),
  passwordLength: decodeURIComponent(databaseUrl.password).length,
  hostname: databaseUrl.hostname,
  port: databaseUrl.port,
  database: databaseUrl.pathname,
});

const syntraDefinition: GraphDefinition = {
  graphKey: 'syntra.matching.workflow',
  stateSchema: 'SyntraState',
  entryInput: 'EventInput',
  nodes: [
    { id: 'summarise', impl: 'syntra.summarise' },
    { id: 'persistResults', impl: 'syntra.persist' },
    { id: 'emit', impl: 'syntra.emit' }
  ],
  edges: [
    ['__start__', 'summarise'],
    ['summarise', 'persistResults'],
    ['persistResults', 'emit'],
    ['emit', '__end__']
  ]
};

async function bootstrapPgBoss(): Promise<void> {
  console.log("Starting pg-boss bootstrap & dispatcher...");

  const boss = new PgBossModule.PgBoss({
    connectionString: env.DATABASE_MIGRATOR_URL,
    schema: "pgboss",
    ssl: { rejectUnauthorized: false },
  });

  await boss.start();
  console.log("pg-boss tables created successfully");

  // Construct Resolver & Compiler
  const resolver = new SimpleRunbookResolver({
    [EVENT_TYPES.JD_RECEIVED]: syntraDefinition
  });
  
  const compiler = new GraphCompiler();

  // Construct Pool for WorkflowRunner
  const pool = new pg.Pool({
    connectionString: env.DATABASE_MIGRATOR_URL,
    ssl: { rejectUnauthorized: false }
  });

  const runner = new WorkflowRunner(pool);

  console.log("Listening for orchestration.dispatch events...");
  await boss.createQueue("orchestration.dispatch");
  
  await boss.work("orchestration.dispatch", async (jobs: any) => {
    for (const job of jobs) {
      const envelope = job.data as EventEnvelope;
      
      console.log(`[Dispatcher] Received event: ${envelope.event_type} (ID: ${envelope.event_id})`);

      try {
        const definition = resolver.resolve(envelope.event_type, {
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
        
        const graph = await compiler.compile(definition);
        const result = await runner.executeWorkflow(graph, eventInput);
        
        if (result.status === 'FAILED') {
          console.error(`[Dispatcher] Workflow failed: ${result.error}`);
          throw new Error(result.error);
        }
        
        console.log(`[Dispatcher] Workflow ${definition.graphKey} completed successfully.`);
      } catch (error) {
        console.error(`[Dispatcher] Error processing job ${job.id}:`, error);
        throw error; // Let pg-boss handle retry/dlq
      }
    }
  });

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