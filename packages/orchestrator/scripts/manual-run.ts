import 'dotenv/config';
import pg from 'pg';
import { SimpleRunbookResolver } from '../src/resolver/runbook.js';
import { GraphCompiler } from '../src/graphs/compiler.js';
import type { GraphDefinition } from '../src/graphs/compiler.js';
import { WorkflowRunner } from '../src/workflow/runner.js';
import { EVENT_TYPES } from '@tekisho/domain';
import type { EventInput } from '../src/types.js';

// Note: This script's ONLY purpose is to let us manually trigger one real workflow run
// against the live DB, so we can verify that a row actually lands in event_outbox.
// It is not meant to be the permanent runtime entry point. `bootstrap-pgboss.ts` 
// still needs its own wiring (Runbook Resolver) in the future.

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

async function main() {
  if (!process.env.DATABASE_MIGRATOR_URL) {
    console.error('DATABASE_MIGRATOR_URL environment variable is required');
    process.exit(1);
  }

  // Construct real pg.Pool
  const pool = new pg.Pool({
    connectionString: process.env.DATABASE_MIGRATOR_URL,
    ssl: { rejectUnauthorized: false }
  });

  // Construct SimpleRunbookResolver, GraphCompiler, and WorkflowRunner
  const resolver = new SimpleRunbookResolver({
    [EVENT_TYPES.JD_RECEIVED]: syntraDefinition
  });
  const compiler = new GraphCompiler();
  
  const runner = new WorkflowRunner(pool);

  // Build one realistic EventInput
  const event: EventInput = {
    event_id: '123e4567-e89b-12d3-a456-426614174001', // Real UUID
    event_type: EVENT_TYPES.JD_RECEIVED,
    aggregate_id: '123e4567-e89b-12d3-a456-426614174002',
    aggregate_type: 'requirement',
    organization_id: '2b8e12b3-1745-4ae9-902c-5a249c28ba94',
    correlation_id: '123e4567-e89b-12d3-a456-426614174003',
    payload: { status: 'live_test' }
  };

  console.log('Resolving workflow for event...');
  const definition = resolver.resolve(event.event_type, {
    organization_id: event.organization_id,
    payload: event.payload
  });

  console.log(`Executing workflow: ${definition.graphKey}...`);
  try {
    const graph = await compiler.compile(definition);
    const result = await runner.executeWorkflow(graph, event);
    console.log('Workflow executed successfully. Result:', JSON.stringify(result, null, 2));
  } catch (error) {
    console.error('Workflow execution failed:', error);
  } finally {
    await pool.end();
  }
}

main().catch(console.error);
