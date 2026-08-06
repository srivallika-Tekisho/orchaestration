export interface ResolveContext {
  organization_id: string;
  payload: Record<string, any>;
}

export interface RunbookResolver {
  resolve(eventType: string, context: ResolveContext): string;
}

export class SimpleRunbookResolver implements RunbookResolver {
  private routingTable: Record<string, string>;

  constructor(routingTable: Record<string, string>) {
    this.routingTable = routingTable;
  }

  public resolve(eventType: string, context: ResolveContext): string {
    const runbook = this.routingTable[eventType];
    if (!runbook) {
      throw new Error(`No runbook defined for event type: ${eventType}`);
    }
    return runbook;
  }
}
