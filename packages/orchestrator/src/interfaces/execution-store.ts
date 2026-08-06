import type { WorkflowContext } from '../types.js';

export interface ExecutionStore {
  saveExecution(context: WorkflowContext): Promise<void>;
  getExecution(executionId: string): Promise<any>;
  markCompleted(executionId: string): Promise<void>;
}
