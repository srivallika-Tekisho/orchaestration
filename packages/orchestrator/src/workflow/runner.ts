import type { EventInput, WorkflowResult } from '../types.js';
import type { WorkflowRegistry } from './registry.js';
import type { Pool } from 'pg';

export class WorkflowRunner {
  private registry: WorkflowRegistry;
  private pool?: Pool;

  constructor(registry: WorkflowRegistry, pool?: Pool) {
    this.registry = registry;
    this.pool = pool;
  }

  public async executeWorkflow(workflow_name: string, event: EventInput): Promise<WorkflowResult> {
    try {
      const graph = this.registry.getGraph(workflow_name);

      const finalState = await graph.invoke({ trigger_event: event });

      const events: EventInput[] = finalState._emittedEvents || [];
      const cleanState = { ...finalState };
      delete cleanState._emittedEvents;
      delete cleanState.trigger_event;

      if (events.length > 0) {
        if (this.pool) {
          const client = await this.pool.connect();
          try {
            await client.query('BEGIN');
            for (const generatedEvent of events) {
              await client.query(
                `INSERT INTO event_outbox (
                  event_id, event_type, schema_version, organization_id,
                  aggregate_type, aggregate_id, correlation_id, causation_id,
                  producer, payload_ref
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
                [
                  generatedEvent.event_id,
                  generatedEvent.event_type,
                  '1.0',
                  generatedEvent.organization_id,
                  generatedEvent.aggregate_type,
                  generatedEvent.aggregate_id,
                  generatedEvent.correlation_id,
                  event.event_id,
                  'orchestrator',
                  generatedEvent.payload
                ]
              );
            }
            await client.query('COMMIT');
          } catch (err) {
            await client.query('ROLLBACK');
            throw err;
          } finally {
            client.release();
          }
        } else {
          console.warn('WorkflowRunner: no pool provided, skipping event_outbox persistence');
        }
      }

      return {
        status: 'COMPLETED',
        events,
        finalState: cleanState
      };
    } catch (error: any) {
      return {
        status: 'FAILED',
        events: [],
        finalState: {},
        error: error.message
      };
    }
  }
}
