import 'dotenv/config';
import pg from 'pg';
async function test() {
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_MIGRATOR_URL, ssl: { rejectUnauthorized: false } });
  try {
    const res1 = await pool.query("SELECT nspname, rolname AS owner FROM pg_namespace n JOIN pg_roles r ON n.nspowner = r.oid WHERE nspname = 'app'");
    console.log("Owner:", res1.rows);
    
    const res2 = await pool.query("SELECT has_schema_privilege('syntra_migrator', 'app', 'USAGE') AS usage");
    console.log("Usage:", res2.rows);

    const res3 = await pool.query("SELECT has_function_privilege('syntra_migrator', 'app.current_org_id()', 'EXECUTE') AS exec");
    console.log("Exec:", res3.rows);
  } catch(e) { console.error(e.message); }
  pool.end();
}
test();
