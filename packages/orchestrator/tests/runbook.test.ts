import { describe, it, expect } from 'vitest';
import { SimpleRunbookResolver } from '../src/resolver/runbook.js';

describe('SimpleRunbookResolver', () => {
  it('should resolve a known event type to the correct runbook', () => {
    const resolver = new SimpleRunbookResolver({
      'test.event': 'test.runbook'
    });

    const runbook = resolver.resolve('test.event', {
      organization_id: 'org1',
      payload: {}
    });

    expect(runbook).toBe('test.runbook');
  });

  it('should throw an error for an unknown event type', () => {
    const resolver = new SimpleRunbookResolver({
      'test.event': 'test.runbook'
    });

    expect(() => {
      resolver.resolve('unknown.event', {
        organization_id: 'org1',
        payload: {}
      });
    }).toThrowError('No runbook defined for event type: unknown.event');
  });
});
