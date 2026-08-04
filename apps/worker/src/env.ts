import dotenv from "dotenv";
import { fileURLToPath } from "node:url";
import { z } from "zod";

const rootEnvPath = fileURLToPath(
  new URL("../../../.env", import.meta.url),
);

dotenv.config({
  path: rootEnvPath,
});

const EnvironmentSchema = z.object({
  DATABASE_MIGRATOR_URL: z
    .string()
    .min(1, "DATABASE_MIGRATOR_URL is required")
    .refine(
      (value) => value.startsWith("postgresql://"),
      "DATABASE_MIGRATOR_URL must start with postgresql://",
    ),
});

export const env = EnvironmentSchema.parse(
  process.env,
);