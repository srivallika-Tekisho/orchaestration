import { StateGraph, Annotation } from '@langchain/langgraph';
import type { EventInput } from '../../types.js';

export const SyntraState = Annotation.Root({
  summary: Annotation<string>({
    reducer: (x, y) => y ?? x,
    default: () => ''
  }),
  saved: Annotation<boolean>({
    reducer: (x, y) => y ?? x,
    default: () => false
  }),
  _emittedEvents: Annotation<EventInput[]>({
    reducer: (x, y) => x.concat(y),
    default: () => []
  })
});

export const syntraGraph = new StateGraph(SyntraState)
  .addNode('summarise', async () => {
    return { summary: 'resume processed' };
  })
  .addNode('persistResults', async () => {
    return { saved: true };
  })
  .addNode('emit', async () => {
    const generatedEvent: EventInput = {
      event_id: 'auto-gen-123',
      event_type: 'match.completed',
      aggregate_id: 'placeholder',
      payload: { status: 'completed' }
    };
    return { _emittedEvents: [generatedEvent] };
  })
  .addEdge('__start__', 'summarise')
  .addEdge('summarise', 'persistResults')
  .addEdge('persistResults', 'emit')
  .addEdge('emit', '__end__')
  .compile();
