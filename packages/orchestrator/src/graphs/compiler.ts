import { StateGraph, CompiledStateGraph } from '@langchain/langgraph';
import { nodeRegistry } from '../nodes/registry.js';
import { PostgresSaver } from '@langchain/langgraph-checkpoint-postgres';
import { SyntraState } from '../workflow/graphs/syntra.js';

export interface GraphDefinitionNode {
  id: string;
  impl: string;
  config?: any;
}

export interface GraphDefinition {
  graphKey: string;
  stateSchema: string;
  entryInput: string;
  nodes: GraphDefinitionNode[];
  edges: [string, string][];
}

export class GraphCompiler {
  private cache = new Map<string, CompiledStateGraph<any, any, any>>();

  public async compile(
    definition: GraphDefinition,
    checkpointer?: PostgresSaver
  ): Promise<CompiledStateGraph<any, any, any>> {
    // Basic caching by key for now.
    // In full implementation, we'd cache by checksum.
    if (this.cache.has(definition.graphKey)) {
      return this.cache.get(definition.graphKey)!;
    }

    // Initialize graph with state schema.
    // For now we hardcode SyntraState as per design step 1,
    // later it resolves based on `stateSchema` property.
    let graph = new StateGraph(SyntraState);

    // Add nodes dynamically
    for (const node of definition.nodes) {
      const implFn = nodeRegistry[node.impl];
      if (!implFn) {
        throw new Error(`Node implementation not found in registry: ${node.impl}`);
      }
      graph = graph.addNode(node.id, implFn);
    }

    // Add edges dynamically
    for (const edge of definition.edges) {
      graph = graph.addEdge(edge[0] as any, edge[1] as any);
    }

    // Compile
    const compiledGraph = graph.compile({ checkpointer });
    
    this.cache.set(definition.graphKey, compiledGraph);
    return compiledGraph;
  }
}
