import { PostgresSaver } from
  "@langchain/langgraph-checkpoint-postgres";

import { env } from "./env.js";

function createLangGraphConnectionString(
  connectionString: string,
): string {
  const url = new URL(connectionString);

  url.searchParams.set(
    "options",
    "-c search_path=langgraph",
  );

  return url.toString();
}

async function bootstrapCheckpointer(): Promise<void> {
  const connectionString =
    createLangGraphConnectionString(
      env.DATABASE_MIGRATOR_URL,
    );

  console.log(
    "Starting LangGraph checkpointer bootstrap...",
  );

  const checkpointer =
    PostgresSaver.fromConnString(
      connectionString,
    );

  await checkpointer.setup();

  console.log(
    "LangGraph checkpoint tables created successfully",
  );
}

bootstrapCheckpointer().catch(
  (error: unknown) => {
    console.error(
      "LangGraph bootstrap failed:",
      error,
    );

    process.exitCode = 1;
  },
);