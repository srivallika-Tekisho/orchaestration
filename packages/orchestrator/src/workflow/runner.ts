import type { EventInput, WorkflowResult } from '../types.js';
import type { PolicyEngine } from '../policy/engine.js';
import type { WorkflowRegistry } from './registry.js';

export class WorkflowRunner {
  private policyEngine: PolicyEngine;
  private registry: WorkflowRegistry;

  constructor(policyEngine: PolicyEngine, registry: WorkflowRegistry) {
    this.policyEngine = policyEngine;
    this.registry = registry;
  }

  public async executeWorkflow(event: EventInput): Promise<WorkflowResult> {
    try {
      const { workflow_name } = this.policyEngine.resolveWorkflow(event.event_type);
      const graph = this.registry.getGraph(workflow_name);

      const finalState = await graph.invoke({});

      const events: EventInput[] = finalState._emittedEvents || [];
      const cleanState = { ...finalState };
      delete cleanState._emittedEvents;

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
