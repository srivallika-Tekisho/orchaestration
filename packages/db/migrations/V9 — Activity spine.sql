-- V9 — Activity spine (design doc §6.13)
-- =============================================================================
-- One append-only timeline for everything that happened to any entity, by human
-- or agent. A single query pattern powers Candidate 360, vendor history and the
-- audit views.
--
-- Distinct from audit_logs: this is the human-readable narrative that recruiters
-- read; audit_logs is the before/after compliance record.
-- =============================================================================


CREATE TABLE activities (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  entity_type     text NOT NULL,   -- any spine entity
  entity_id       uuid NOT NULL,
  activity_type   text NOT NULL,   -- 'JD_RECEIVED', 'MATCH_COMPLETED', 'NOTE', ...
  actor_type      text NOT NULL CHECK (actor_type IN ('USER', 'AGENT', 'SYSTEM')),
  actor_id        uuid,            -- user id, or agent_definition id
  agent_run_id    uuid,            -- drill from the timeline into the full trace
  summary         text NOT NULL,   -- human-readable one-liner
  payload         jsonb NOT NULL DEFAULT '{}',

  -- This table is append-only, so a replayed event would duplicate entries in
  -- the Candidate 360 timeline. Writers that can be replayed set a stable
  -- dedupe_key (typically the triggering event_id plus a discriminator);
  -- genuinely repeatable entries such as recruiter notes leave it NULL.
  dedupe_key      text,

  occurred_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT activities_org_dedupe_key UNIQUE (organization_id, dedupe_key),
  FOREIGN KEY (organization_id, agent_run_id) REFERENCES agent_runs (organization_id, id)
);

-- The universal timeline query: everything about one entity, newest first.
CREATE INDEX activities_entity_timeline_idx
  ON activities (organization_id, entity_type, entity_id, occurred_at DESC);

-- Org-wide activity feed.
CREATE INDEX activities_org_occurred_idx
  ON activities (organization_id, occurred_at DESC);

-- "What did this run do", reached from the run trace side.
CREATE INDEX activities_agent_run_idx
  ON activities (agent_run_id) WHERE agent_run_id IS NOT NULL;


-- =============================================================================