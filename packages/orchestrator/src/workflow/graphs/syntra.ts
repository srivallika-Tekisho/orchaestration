import { StateGraph, Annotation } from '@langchain/langgraph';
import { v4 as uuidv4 } from 'uuid';
import type { EventInput } from '../../types.js';
import { EVENT_TYPES } from '@tekisho/domain';

const SYNTRA_BASE = process.env.SYNTRA_API_URL || 'http://localhost:4000';

// Shared state shape for all Syntra workflows.
const SyntraState = Annotation.Root({
  result: Annotation<string>({ reducer: (x, y) => y ?? x, default: () => '' }),
  _emittedEvents: Annotation<EventInput[]>({
    reducer: (x, y) => x.concat(y),
    default: () => []
  }),
  trigger_event: Annotation<EventInput | null>({
    reducer: (x, y) => y ?? x,
    default: () => null
  })
});

async function postSyntra(path: string, body?: Record<string, unknown>): Promise<any> {
  const res = await fetch(`${SYNTRA_BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  });
  if (!res.ok) {
    throw new Error(`Syntra ${path} failed: ${res.status} ${await res.text()}`);
  }
  return res.json();
}

// --- JD workflow: summarize the job ---
export const jdGraph = new StateGraph(SyntraState)
  .addNode('process', async (state) => {
    const jobId = state.trigger_event?.payload?.jobId;
    if (!jobId) throw new Error('jd workflow: no jobId in payload');
    const r = await postSyntra(`/internal/jobs/${jobId}/process`);
    return { result: `job ${jobId}: ${r.status}` };
  })
  .addEdge('__start__', 'process')
  .addEdge('process', '__end__')
  .compile();

// --- Resume workflow: summarize the resume + profile ---
export const resumeGraph = new StateGraph(SyntraState)
  .addNode('process', async (state) => {
    const resumeId = state.trigger_event?.payload?.resumeId;
    const candidateId = state.trigger_event?.payload?.candidateId;
    if (!resumeId) throw new Error('resume workflow: no resumeId in payload');
    const r = await postSyntra(`/internal/resumes/${resumeId}/process`, { candidateId });
    return { result: `resume ${resumeId}: ${r.status}` };
  })
  .addEdge('__start__', 'process')
  .addEdge('process', '__end__')
  .compile();

// --- Match workflow: score a job x resume pair ---
export const matchGraph = new StateGraph(SyntraState)
  .addNode('process', async (state) => {
    const jobId = state.trigger_event?.payload?.jobId;
    const resumeId = state.trigger_event?.payload?.resumeId;
    if (!jobId || !resumeId) throw new Error('match workflow: need jobId and resumeId');
    const r = await postSyntra(`/internal/matches/process`, { jobId, resumeId });
    return { result: `match ${jobId}/${resumeId}: ${r.status}` };
  })
  .addEdge('__start__', 'process')
  .addEdge('process', '__end__')
  .compile();
