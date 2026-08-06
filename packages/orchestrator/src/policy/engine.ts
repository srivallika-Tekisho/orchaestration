export class PolicyEngine {
  private config: Record<string, string>;

  constructor(config: Record<string, string>) {
    this.config = config;
  }

  public resolveWorkflow(eventType: string): { workflow_name: string } {
    const workflow_name = this.config[eventType];
    if (!workflow_name) {
      throw new Error(`No workflow registered for event: ${eventType}`);
    }
    return { workflow_name };
  }
}
