import 'dotenv/config';
import pg from 'pg';
import { env } from '../../../apps/worker/src/env.js';

async function check() {
  const pool = new pg.Pool({
    connectionString: env.DATABASE_MIGRATOR_URL,
    ssl: { rejectUnauthorized: false }
  });

  const res = await pool.query("SELECT id, name, state, output FROM pgboss.job WHERE name = 'orchestration.dispatch' ORDER BY created_on DESC LIMIT 5");
  console.log(JSON.stringify(res.rows, null, 2));
  await pool.end();
}

check().catch(console.error);
