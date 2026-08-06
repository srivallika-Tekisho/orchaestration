import { describe, it, expect, beforeEach } from 'vitest';
import { PolicyEngine } from '../src/policy/engine.js';
import { WorkflowRegistry } from '../src/workflow/registry.js';
import { WorkflowRunner } from '../src/workflow/runner.js';
import { syntraGraph } from '../src/workflow/graphs/syntra.js';
import type { EventInput } from '../src/types.js';

describe('Orchestrator Flow Integration Test', () => {
  let policyEngine: PolicyEngine;
  let registry: WorkflowRegistry;
  let runner: WorkflowRunner;

  beforeEach(() => {
    // 2. Register SYNTRA graph
    policyEngine = new PolicyEngine({
      'requirement.created': 'syntra.matching.workflow'
    });
    
    registry = new WorkflowRegistry();
    registry.register('syntra.matching.workflow', syntraGraph);

    runner = new WorkflowRunner(policyEngine, registry);
  });

  it('should process requirement.created and return match.completed without DB', async () => {
    // 1. Create fake event
    const event: EventInput = {
      event_id: '123',
      event_type: 'requirement.created',
      aggregate_id: 'req1',
      payload: {}
    };

    // 3. Execute WorkflowRunner
    const result = await runner.executeWorkflow(event);

    // 4. Verify status and event
    expect(result.status).toBe('COMPLETED');
    expect(result.events).toHaveLength(1);
    expect(result.events[0]!.event_type).toBe('match.completed');
    expect(result.events[0]!.payload.status).toBe('completed');
    
    // Verify pure state evolution
    expect(result.finalState.summary).toBe('resume processed');
    expect(result.finalState.saved).toBe(true);
  });
});
