import 'dotenv/config';
import * as PgBossModule from "pg-boss";
import { EVENT_TYPES } from '@tekisho/domain';
import type { EventEnvelope } from '@tekisho/domain';
import { v4 as uuidv4 } from 'uuid';
import { env } from '../src/env.js';

async function sendMsg() {
  console.log("Connecting to pg-boss at:", env.DATABASE_MIGRATOR_URL.split('@')[1]);
  const boss = new PgBossModule.PgBoss({
    connectionString: env.DATABASE_MIGRATOR_URL,
    schema: "pgboss",
    ssl: { rejectUnauthorized: false },
  });

  await boss.start();

  const envelope: EventEnvelope = {
    event_id: uuidv4(),
    event_type: EVENT_TYPES.JD_RECEIVED,
    schema_version: '1.0',
    occurred_at: new Date().toISOString(),
    correlation_id: uuidv4(),
    causation_id: null,
    organization_id: '8032f15b-186e-4340-a93f-417688a8f1c2',
    aggregate: {
      id: uuidv4(),
      type: 'requirement'
    },
    producer: 'test-script',
    payload_ref: { requirement_id: 'req-live-2' }
  };

  console.log('Sending message to pg-boss orchestration.dispatch queue...');
  const jobId = await boss.send('orchestration.dispatch', envelope);
  console.log(`Message sent! Job ID: ${jobId}`);

  await boss.stop();
}

sendMsg().catch(console.error);
