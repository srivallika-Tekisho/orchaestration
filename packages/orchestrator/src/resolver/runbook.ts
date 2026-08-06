import type { EventType } from '@tekisho/domain';
import type { GraphDefinition } from '../graphs/compiler.js';

export interface ResolveContext {
  organization_id: string;
  payload: Record<string, unknown>;
}

export interface RunbookResolver {
  resolve(eventType: EventType, context: ResolveContext): GraphDefinition;
}

export class SimpleRunbookResolver implements RunbookResolver {
  constructor(private readonly routingTable: Record<string, GraphDefinition>) {}

  resolve(eventType: EventType, context: ResolveContext): GraphDefinition {
    const definition = this.routingTable[eventType];
    if (!definition) {
      throw new Error(`No runbook defined for event type: ${eventType}`);
    }
    return definition;
  }
}
