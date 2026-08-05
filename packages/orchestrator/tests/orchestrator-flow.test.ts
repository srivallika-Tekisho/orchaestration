import { describe, it, expect } from "vitest";

import { WorkflowRunner } from "../src/workflow/runner";
import { WorkflowRegistry } from "../src/workflow/registry";


describe("Syntra Orchestrator Flow", () => {

  it("should execute workflow successfully", async () => {

    const mockPolicyEngine = {
      resolveWorkflow(eventType: string) {
        return {
          workflow_name: "syntra"
        };
      }
    };


    const mockGraph = {
      async invoke(input:any) {
        return {
          status:"completed",
          event_type:"match.completed",
          candidate_id:"123",
          score:90
        };
      }
    };


    const registry = new WorkflowRegistry();

    registry.register(
      "syntra",
      mockGraph as any
    );


    const runner = new WorkflowRunner(
      mockPolicyEngine as any,
      registry
    );


    const result = await runner.executeWorkflow({

      event_id:"evt-001",

      event_type:"resume.received",

      aggregate_id:"candidate-001",

      payload:{
        resume:"test resume"
      }

    });


    expect(result.status)
      .toBe("COMPLETED");


    expect(result.events.length)
      .toBe(1);


    expect(result.events[0].event_type)
      .toBe("match.completed");

  });

});