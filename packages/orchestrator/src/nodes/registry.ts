import { v4 as uuidv4 } from 'uuid';
import { EVENT_TYPES } from '@tekisho/domain';
import type { EventInput } from '../types.js';

export const summariseNode = async (state: any) => {
  return { summary: 'resume processed' };
};

export const persistResultsNode = async (state: any) => {
  return { saved: true };
};

export const emitNode = async (state: any) => {
  const trigger = state.trigger_event;
  const generatedEvent: EventInput = {
    event_id: uuidv4(),
    event_type: EVENT_TYPES.MATCH_COMPLETED,
    aggregate_id: uuidv4(),
    aggregate_type: 'requirement',
    organization_id: trigger ? trigger.organization_id : 'fallback-org-id',
    correlation_id: trigger ? trigger.correlation_id : uuidv4(),
    payload: { status: 'completed' }
  };
  return { _emittedEvents: [generatedEvent] };
};

export const nodeRegistry: Record<string, (state: any) => Promise<any>> = {
  'syntra.summarise': summariseNode,
  'syntra.persist': persistResultsNode,
  'syntra.emit': emitNode
};
