import { describe, it, expect, beforeEach } from 'vitest';
import { SimpleRunbookResolver } from '../src/resolver/runbook.js';
import { WorkflowRegistry } from '../src/workflow/registry.js';
import { WorkflowRunner } from '../src/workflow/runner.js';
import { jdGraph } from '../src/workflow/graphs/syntra.js';
import type { EventInput } from '../src/types.js';
import { EVENT_TYPES } from '@tekisho/domain';

describe('Orchestrator Flow Integration Test', () => {
  let resolver: SimpleRunbookResolver;
  let registry: WorkflowRegistry;
  let runner: WorkflowRunner;

  beforeEach(() => {
    // 2. Register SYNTRA graph
    resolver = new SimpleRunbookResolver({
      [EVENT_TYPES.JD_RECEIVED]: 'syntra.matching.workflow'
    });
    
    registry = new WorkflowRegistry();
    registry.register('syntra.matching.workflow', jdGraph);

    runner = new WorkflowRunner(registry);
  });

  it('should process requirement.created and return match.completed without DB', async () => {
    // 1. Create fake event
    const event: EventInput = {
      event_id: '123',
      event_type: EVENT_TYPES.JD_RECEIVED,
      aggregate_id: 'req1',
      aggregate_type: 'requirement',
      organization_id: '123e4567-e89b-12d3-a456-426614174000',
      correlation_id: 'corr-123',
      payload: {}
    };

    // 3. Resolve and execute WorkflowRunner
    const workflowName = resolver.resolve(event.event_type, {
      organization_id: event.organization_id,
      payload: event.payload
    });
    const result = await runner.executeWorkflow(workflowName, event);

    // 4. Verify status and event
    expect(result.status).toBe('COMPLETED');
    expect(result.events).toHaveLength(1);
    expect(result.events[0]!.event_type).toBe(EVENT_TYPES.MATCH_COMPLETED);
    expect(result.events[0]!.payload.status).toBe('completed');
    
    // Verify pure state evolution
    expect(result.finalState.summary).toBe('resume processed');
    expect(result.finalState.saved).toBe(true);
  });

  it('should persist generated events to event_outbox when DB pool is provided', async () => {
    // Mock PG Pool client
    const queries: { text: string; values?: any[] }[] = [];
    const mockClient = {
      query: async (text: string, values?: any[]) => {
        queries.push({ text, values });
      },
      release: () => {}
    };
    const mockPool = {
      connect: async () => mockClient
    } as any;

    const runnerWithDb = new WorkflowRunner(registry, mockPool);

    const event: EventInput = {
      event_id: '123',
      event_type: EVENT_TYPES.JD_RECEIVED,
      aggregate_id: 'req1',
      aggregate_type: 'requirement',
      organization_id: '123e4567-e89b-12d3-a456-426614174000',
      correlation_id: 'corr-123',
      payload: {}
    };

    const workflowName = resolver.resolve(event.event_type, {
      organization_id: event.organization_id,
      payload: event.payload
    });
    const result = await runnerWithDb.executeWorkflow(workflowName, event);

    expect(result.status).toBe('COMPLETED');
    
    // Verify queries
    expect(queries).toHaveLength(3);
    expect(queries[0]!.text).toBe('BEGIN');
    
    const insertQuery = queries[1]!;
    expect(insertQuery.text).toContain('INSERT INTO event_outbox');
    expect(insertQuery.values).toHaveLength(10);
    expect(typeof insertQuery.values![0]).toBe('string');
    expect(insertQuery.values![1]).toBe(EVENT_TYPES.MATCH_COMPLETED);
    expect(insertQuery.values![2]).toBe('1.0');
    expect(insertQuery.values![3]).toBe('123e4567-e89b-12d3-a456-426614174000');
    expect(insertQuery.values![4]).toBe('requirement');
    expect(typeof insertQuery.values![5]).toBe('string'); // aggregate_id
    expect(typeof insertQuery.values![6]).toBe('string'); // correlation_id
    expect(insertQuery.values![7]).toBe('123'); // causation_id is from the trigger event
    expect(insertQuery.values![8]).toBe('orchestrator');
    expect(insertQuery.values![9]).toEqual({ status: 'completed' });

    expect(queries[2]!.text).toBe('COMMIT');
  });
});
