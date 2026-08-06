import { StateGraph, Annotation } from '@langchain/langgraph';
import { v4 as uuidv4 } from 'uuid';
import type { EventInput } from '../../types.js';
import { EVENT_TYPES } from '@tekisho/domain';

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
  }),
  trigger_event: Annotation<EventInput | null>({
    reducer: (x, y) => y ?? x,
    default: () => null
  })
});

