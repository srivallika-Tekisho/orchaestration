import type { CompiledGraph } from '@langchain/langgraph';

export class WorkflowRegistry {
  private workflows = new Map<string, CompiledGraph<any, any, any>>();

  public register(name: string, graph: CompiledGraph<any, any, any>): void {
    this.workflows.set(name, graph);
  }

  public getGraph(name: string): CompiledGraph<any, any, any> {
    const graph = this.workflows.get(name);
    if (!graph) {
      throw new Error(`Graph not found for workflow: ${name}`);
    }
    return graph;
  }
}
