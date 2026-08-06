// check-db-events.mjs
//
// Standalone DB check script — no psql required.
// Run from repo root with:  node check-db-events.mjs

import { Pool } from "pg";

const connectionString = process.env.DATABASE_MIGRATOR_URL;

if (!connectionString) {
  console.error("❌ DATABASE_MIGRATOR_URL is not set in your environment.");
  process.exit(1);
}

const pool = new Pool({
  connectionString,
  ssl: { rejectUnauthorized: false },
  connectionTimeoutMillis: 5000,
});

async function main() {
  console.log("Connecting to DB...");
  const client = await pool.connect();
  console.log("✅ Connected.\n");

  try {
    console.log("── event_schemas ──────────────────────────");
    const schemas = await client.query(
      `SELECT event_type FROM event_schemas ORDER BY event_type`
    );
    if (schemas.rows.length === 0) {
      console.log("⚠️  No rows found. Seed migration may not have run.");
    } else {
      schemas.rows.forEach((r) => console.log(" -", r.event_type));
    }

    console.log("\n── event_outbox summary ───────────────────");
    const summary = await client.query(`
      SELECT
        count(*) AS total,
        count(*) FILTER (WHERE published_at IS NULL) AS unpublished,
        count(*) FILTER (WHERE published_at IS NOT NULL) AS published,
        max(occurred_at) AS most_recent_event
      FROM event_outbox
    `);
    console.table(summary.rows);

    console.log("── last 10 event_outbox rows ──────────────");
    const recent = await client.query(`
      SELECT id, event_type, aggregate_type, aggregate_id, published_at, occurred_at
      FROM event_outbox
      ORDER BY id DESC
      LIMIT 10
    `);
    if (recent.rows.length === 0) {
      console.log("⚠️  event_outbox is empty — nothing has been written yet.");
    } else {
      console.table(recent.rows);
    }
  } finally {
    client.release();
    await pool.end();
  }
}

main().catch((err) => {
  console.error("❌ DB check failed:", err.message);
  process.exit(1);
});