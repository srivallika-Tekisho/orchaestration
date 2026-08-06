import 'dotenv/config';
import pg from 'pg';
import { SimpleRunbookResolver } from '../src/resolver/runbook.js';
import { WorkflowRegistry } from '../src/workflow/registry.js';
import { WorkflowRunner } from '../src/workflow/runner.js';
import { jdGraph } from '../src/workflow/graphs/syntra.js';
import { EVENT_TYPES } from '@tekisho/domain';
import type { EventInput } from '../src/types.js';

// Note: This script's ONLY purpose is to let us manually trigger one real workflow run
// against the live DB, so we can verify that a row actually lands in event_outbox.
// It is not meant to be the permanent runtime entry point. `bootstrap-pgboss.ts` 
// still needs its own wiring (Runbook Resolver) in the future.

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

  // Construct SimpleRunbookResolver, WorkflowRegistry, and WorkflowRunner
  const resolver = new SimpleRunbookResolver({
    [EVENT_TYPES.JD_RECEIVED]: 'syntra.matching.workflow'
  });
  const registry = new WorkflowRegistry();
  registry.register('syntra.matching.workflow', jdGraph);
  
  const runner = new WorkflowRunner(registry, pool);

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
  const workflowName = resolver.resolve(event.event_type, {
    organization_id: event.organization_id,
    payload: event.payload
  });

  console.log(`Executing workflow: ${workflowName}...`);
  try {
    const result = await runner.executeWorkflow(workflowName, event);
    console.log('Workflow executed successfully. Result:', JSON.stringify(result, null, 2));
  } catch (error) {
    console.error('Workflow execution failed:', error);
  } finally {
    await pool.end();
  }
}

main().catch(console.error);
