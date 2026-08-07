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

  const sql = fs.readFileSync(path.join(__dirname, 'migrations', 'V13__Graph_Definitions_Reset.sql'), 'utf-8');
  try {
    await pool.query(sql);
    console.log("Migration V13 applied successfully!");
  } catch (error) {
    console.error("Migration failed:", error);
  } finally {
    await pool.end();
  }
}

apply().catch(console.error);
