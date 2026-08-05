-- V3 — Agentic spine (design doc §6.14)
-- =============================================================================
-- ORDERING NOTE: the design doc presents this domain last, but
-- ingestion_events.agent_run_id, requirements' ingestion path,
-- match_jobs.agent_run_id and activities.agent_run_id all point at agent_runs.
-- The doc leaves those as bare `uuid` columns with no REFERENCES; once they
-- become real foreign keys the spine has to exist first, so it moves to V3.
--
-- Shared by every agent forever: definitions, runs, step traces, the approval
-- loop, the event schema registry, the transactional outbox, consumer
-- idempotency and the audit log.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- agent_definitions — the versioned contract for an agent
-- -----------------------------------------------------------------------------
-- Platform reference data (not org-scoped): which tools an agent may call, its
-- autonomy policy per action class, model config and per-run cost budget.
-- Day 1 holds matching-agent, intake-agent and copilot.
CREATE TABLE agent_definitions (
  id                uuid PRIMARY KEY,
  name              text NOT NULL,               -- 'matching-agent'
  version           text NOT NULL,               -- semver
  purpose           text NOT NULL,
  system_prompt_ref text NOT NULL,               -- versioned prompt artifact
  allowed_tools     jsonb NOT NULL,              -- [{name, min_version}]
  autonomy          jsonb NOT NULL,              -- action_class -> SUGGEST|APPROVE|AUTO
  model_config      jsonb NOT NULL,              -- provider, model, temperature, budgets
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT agent_definitions_name_version_key UNIQUE (name, version)
);

CREATE UNIQUE INDEX agent_definitions_active_name_idx
  ON agent_definitions (name) WHERE is_active;

CREATE TRIGGER agent_definitions_set_updated_at
  BEFORE UPDATE ON agent_definitions
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- agent_runs — one row per agent execution
-- -----------------------------------------------------------------------------
CREATE TABLE agent_runs (
  id                  uuid PRIMARY KEY,
  organization_id     uuid NOT NULL REFERENCES organizations (id),
  agent_definition_id uuid NOT NULL REFERENCES agent_definitions (id),
  trigger_type        text NOT NULL CHECK (trigger_type IN ('EVENT', 'USER', 'SCHEDULE')),
  triggered_by        uuid,        -- user id when trigger_type = 'USER'

  -- The outbox event that caused this run. Together with the unique index
  -- below this is the database-level backstop for §12 acceptance criterion 1:
  -- redelivery of an event must not produce a second agent run.
  trigger_event_id    uuid,

  input_ref           jsonb NOT NULL,   -- entity references, never blobs
  status              text NOT NULL DEFAULT 'QUEUED' CHECK (status IN (
                        'QUEUED', 'RUNNING', 'WAITING_APPROVAL', 'COMPLETED',
                        'FAILED', 'CANCELLED', 'EXPIRED')),

  -- LangGraph checkpoint thread key, formatted '<org_uuid>:<agent_run_uuid>'.
  -- The org prefix is what lets R__runtime_table_policies.sql apply RLS to the
  -- checkpoint tables, which otherwise carry JD text and candidate PII with no
  -- tenant column at all. Retrofitting this later means rewriting every
  -- thread_id, so the format is fixed on day 1.
  thread_id           text NOT NULL,

  cost                jsonb NOT NULL DEFAULT '{}',  -- tokens and USD by model
  error               jsonb,
  started_at          timestamptz,
  completed_at        timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT agent_runs_thread_id_key UNIQUE (thread_id),
  CONSTRAINT agent_runs_org_id_key    UNIQUE (organization_id, id),
  CONSTRAINT agent_runs_thread_id_format CHECK (thread_id = organization_id::text || ':' || id::text),
  FOREIGN KEY (organization_id, triggered_by) REFERENCES users (organization_id, id)
);

-- "Exactly one agent run per triggering event" (§12 criterion 1).
CREATE UNIQUE INDEX agent_runs_definition_trigger_event_idx
  ON agent_runs (agent_definition_id, trigger_event_id)
  WHERE trigger_event_id IS NOT NULL;

-- The design doc declares no index on agent_runs at all. This serves the run
-- list and the "what is my org currently doing" poll.
CREATE INDEX agent_runs_org_status_created_idx
  ON agent_runs (organization_id, status, created_at DESC);

CREATE TRIGGER agent_runs_set_updated_at
  BEFORE UPDATE ON agent_runs
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- agent_steps — one row per graph node execution or tool call
-- -----------------------------------------------------------------------------
-- Written BEFORE effects become visible (§5.2). Powers the expandable progress
-- lines in §8.4 and the step-level attribution in §12 criterion 8.
CREATE TABLE agent_steps (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  agent_run_id    uuid NOT NULL,
  seq             int  NOT NULL,
  node            text NOT NULL,
  tool_name       text,
  tool_version    text,
  input           jsonb,          -- redacted per data policy (§10)
  output_ref      jsonb,          -- entity refs / storage keys, never blobs
  tokens_in       int,
  tokens_out      int,
  latency_ms      int,
  status          text NOT NULL CHECK (status IN ('OK', 'RETRIED', 'FAILED', 'SKIPPED')),
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT agent_steps_run_seq_key UNIQUE (agent_run_id, seq),
  FOREIGN KEY (organization_id, agent_run_id) REFERENCES agent_runs (organization_id, id)
);

CREATE INDEX agent_steps_run_seq_idx ON agent_steps (agent_run_id, seq);


-- -----------------------------------------------------------------------------
-- approvals — the human-in-the-loop queue
-- -----------------------------------------------------------------------------
-- Created when autonomy policy requires sign-off; the LangGraph run pauses at
-- an interrupt and resumes on decision (§5.2).
CREATE TABLE approvals (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  agent_run_id    uuid NOT NULL,
  action_class    text NOT NULL,   -- 'DATA_SHAPING', 'EXTERNAL_COMM', ...
  entity_type     text NOT NULL,
  entity_id       uuid,
  proposed_action jsonb NOT NULL,  -- exactly what happens if approved
  rationale       text NOT NULL,   -- the agent's stated reasoning
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN (
                    'PENDING', 'APPROVED', 'MODIFIED', 'REJECTED', 'EXPIRED')),
  decided_by      uuid,
  decided_at      timestamptz,
  decision_note   text,
  expires_at      timestamptz NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT approvals_org_id_key UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, agent_run_id) REFERENCES agent_runs (organization_id, id),
  FOREIGN KEY (organization_id, decided_by)   REFERENCES users (organization_id, id)
);

-- A run that is resumed from a checkpoint would otherwise raise a second
-- approval card for the same pending decision. NULLS NOT DISTINCT because
-- entity_id is nullable for run-scoped approvals.
CREATE UNIQUE INDEX approvals_pending_unique_idx
  ON approvals (agent_run_id, action_class, entity_id) NULLS NOT DISTINCT
  WHERE status = 'PENDING';

-- Approvals Queue (§8.2). The design doc declares no index on this table.
CREATE INDEX approvals_queue_idx
  ON approvals (organization_id, status, expires_at)
  WHERE status = 'PENDING';

-- Run resume path: find the approval blocking a given run.
CREATE INDEX approvals_agent_run_idx ON approvals (agent_run_id);

-- Expiry sweeper.
CREATE INDEX approvals_expiry_sweep_idx
  ON approvals (expires_at) WHERE status = 'PENDING';

CREATE TRIGGER approvals_set_updated_at
  BEFORE UPDATE ON approvals
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- event_schemas — the event contract registry
-- -----------------------------------------------------------------------------
-- Implements the spec requirement that "the events table should capture the
-- schema used for this particular event". Every event_outbox row carries a
-- composite FK to this table, so an event whose type/version is not registered
-- cannot be written at all. Seeded from Appendix B by R__seed_event_schemas.sql.
--
-- Platform reference data: the event catalogue is a product contract, not
-- tenant data.
CREATE TABLE event_schemas (
  event_type      text NOT NULL,           -- 'syntra.jd.received'
  schema_version  text NOT NULL,           -- '1.0'
  description     text NOT NULL,
  payload_schema  jsonb NOT NULL,          -- JSON Schema for payload_ref
  envelope_fields jsonb NOT NULL,          -- the Appendix B envelope contract
  produced_when   text,
  primary_consumer text,
  status          text NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'DEPRECATED')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (event_type, schema_version)
);

CREATE TRIGGER event_schemas_set_updated_at
  BEFORE UPDATE ON event_schemas
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- event_outbox — the transactional outbox
-- -----------------------------------------------------------------------------
-- Business write + event + audit row commit in one transaction (§10). The
-- relay is the only publisher into pg-boss. Also serves as the replay log
-- behind SSE Last-Event-ID (§9): LISTEN/NOTIFY is not replayable, so a
-- reconnecting client reads forward from this table by id.
--
-- bigint identity PK gives the relay a monotonic ordering key.
CREATE TABLE event_outbox (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_id        uuid NOT NULL,
  event_type      text NOT NULL,
  schema_version  text NOT NULL DEFAULT '1.0',
  organization_id uuid NOT NULL REFERENCES organizations (id),
  aggregate_type  text NOT NULL,
  aggregate_id    uuid NOT NULL,
  correlation_id  uuid NOT NULL,
  causation_id    uuid,
  producer        text NOT NULL DEFAULT 'api',
  payload_ref     jsonb NOT NULL,
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  published_at    timestamptz,             -- NULL = pending relay to pg-boss

  CONSTRAINT event_outbox_event_id_key UNIQUE (event_id),
  FOREIGN KEY (event_type, schema_version)
    REFERENCES event_schemas (event_type, schema_version)
);

-- Relay claim query: ordered FOR UPDATE SKIP LOCKED over pending rows.
-- The design doc indexes (published_at) WHERE published_at IS NULL, which
-- indexes an all-NULL column and gives the relay no ordering at all.
CREATE INDEX event_outbox_pending_idx
  ON event_outbox (id) WHERE published_at IS NULL;

-- SSE replay: org-scoped forward scan from a Last-Event-ID.
CREATE INDEX event_outbox_org_id_idx ON event_outbox (organization_id, id);


-- -----------------------------------------------------------------------------
-- processed_events — consumer-side idempotency ledger
-- -----------------------------------------------------------------------------
-- A consumer records (event_id, consumer) on success; redelivery is a no-op.
-- Not org-scoped: this is queue infrastructure, written only by the relay role.
CREATE TABLE processed_events (
  event_id     uuid NOT NULL,
  consumer     text NOT NULL,
  processed_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (event_id, consumer)
);


-- -----------------------------------------------------------------------------
-- audit_logs — before/after images for consequential writes
-- -----------------------------------------------------------------------------
-- Distinct from activities: this is the compliance record, and it is what makes
-- §7.2's "merges reversible from the audit trail" actually true. activities is
-- the human-readable narrative.
CREATE TABLE audit_logs (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  actor_type      text NOT NULL CHECK (actor_type IN ('USER', 'AGENT', 'SYSTEM')),
  actor_id        uuid,
  action          text NOT NULL,
  entity_type     text NOT NULL,
  entity_id       uuid,
  before          jsonb,
  after           jsonb,
  at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX audit_logs_org_entity_idx
  ON audit_logs (organization_id, entity_type, entity_id, at DESC);


-- =============================================================================