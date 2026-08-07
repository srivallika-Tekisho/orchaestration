import 'dotenv/config';
import pg from 'pg';

async function check() {
  const pool = new pg.Pool({
    connectionString: process.env.DATABASE_MIGRATOR_URL,
    ssl: { rejectUnauthorized: false }
  });

  try {
    console.log("=== Query 1: organizations.id type ===");
    const res1 = await pool.query(`
      SELECT column_name, data_type, udt_name
      FROM information_schema.columns
      WHERE table_name = 'organizations' AND column_name = 'id';
    `);
    console.log(res1.rows);

    console.log("\n=== Query 2: other org_id columns ===");
    const res2 = await pool.query(`
      SELECT table_name, column_name, data_type, udt_name
      FROM information_schema.columns
      WHERE column_name IN ('org_id', 'organization_id')
      ORDER BY table_name;
    `);
    console.log(res2.rows);

    console.log("\n=== Query 3: graph_definitions.org_id type ===");
    const res3 = await pool.query(`
      SELECT column_name, data_type, udt_name
      FROM information_schema.columns
      WHERE table_name = 'graph_definitions' AND column_name = 'org_id';
    `);
    console.log(res3.rows);

    console.log("\n=== Query 3: flyway schema history ===");
    try {
      const res4 = await pool.query(`
        SELECT version, description, installed_on
        FROM flyway_schema_history ORDER BY installed_rank;
      `);
      console.log(res4.rows);
    } catch (e) {
      console.log("flyway_schema_history failed/does not exist:", e.message);
    }

  } catch (err) {
    console.error(err);
  } finally {
    await pool.end();
  }
}

check();
