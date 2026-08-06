import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import pg from 'pg';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function apply() {
  const pool = new pg.Pool({
    connectionString: process.env.DATABASE_MIGRATOR_URL,
    ssl: { rejectUnauthorized: false }
  });

  const sql = fs.readFileSync(path.join(__dirname, 'migrations', 'V11__Graph_Definitions.sql'), 'utf-8');
  await pool.query(sql);
  console.log("Migration applied successfully!");
  await pool.end();
}

apply().catch(console.error);
