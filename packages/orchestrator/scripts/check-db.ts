import 'dotenv/config';
import pg from 'pg';
import { env } from '../../../apps/worker/src/env.js';

async function check() {
  const pool = new pg.Pool({
    connectionString: env.DATABASE_MIGRATOR_URL,
    ssl: { rejectUnauthorized: false }
  });

  const res = await pool.query('SELECT * FROM event_outbox ORDER BY occurred_at DESC LIMIT 5');
  console.log(JSON.stringify(res.rows, null, 2));
  await pool.end();
}

check().catch(console.error);
