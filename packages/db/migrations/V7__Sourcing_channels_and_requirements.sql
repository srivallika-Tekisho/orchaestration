-- V7 — Sourcing channels and requirements (design doc §6.8, §6.7)
-- =============================================================================
-- ORDERING NOTE: the design doc presents requirements (§6.7) before channels
-- (§6.8), but requirements.source_channel_id and .ingestion_id reference them,
-- so the order is inverted here. ingestion_events.resolved_entity_id stays
-- polymorphic and un-FK'd, which is what breaks the apparent cycle back to
-- requirements.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- channels — reference list of arrival channels
-- -----------------------------------------------------------------------------
-- Kept as a table rather than a CHECK constraint so that enabling a new channel
-- stays a data change, which is what makes the §6.15 claim ("adding Dice =
-- zero schema changes") true. Platform reference data.
CREATE TABLE channels (
  id           uuid PRIMARY KEY,
  channel_type text NOT NULL CHECK (channel_type IN (
                 'EMAIL', 'LINKEDIN', 'DICE', 'MONSTER', 'INDEED',
                 'PORTAL', 'WHATSAPP', 'MANUAL', 'API')),
  display_name text NOT NULL,
  is_enabled   boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT channels_channel_type_key UNIQUE (channel_type)
);

CREATE TRIGGER channels_set_updated_at
  BEFORE UPDATE ON channels
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- channel_accounts — one org's connection to one channel
-- -----------------------------------------------------------------------------
-- Day 1 only EMAIL is live ('intake@org.syntra.ai'). Adding Dice in phase 2 is
-- one row here plus a connector service — no schema change.
--
-- credentials_ref is a secret-manager reference. Secrets are never stored here.
CREATE TABLE channel_accounts (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  channel_id      uuid NOT NULL REFERENCES channels (id),
  label           text NOT NULL,               -- "dice-main", "intake@org.syntra.ai"
  credentials_ref text,
  config          jsonb NOT NULL DEFAULT '{}', -- polling rules, folder filters
  status          text NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'PAUSED', 'ERROR', 'DISABLED')),
  last_sync_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT channel_accounts_org_label_key UNIQUE (organization_id, label),
  CONSTRAINT channel_accounts_org_id_key    UNIQUE (organization_id, id)
);

CREATE INDEX channel_accounts_polling_idx
  ON channel_accounts (channel_id, last_sync_at)
  WHERE status = 'ACTIVE';

CREATE TRIGGER channel_accounts_set_updated_at
  BEFORE UPDATE ON channel_accounts
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- ingestion_events — raw arrivals, before interpretation
-- -----------------------------------------------------------------------------
-- An email lands here first; the Intake Agent then resolves it into a
-- requirement, a candidate update, or a review item.
CREATE TABLE ingestion_events (
  id                   uuid PRIMARY KEY,
  organization_id      uuid NOT NULL REFERENCES organizations (id),
  channel_account_id   uuid NOT NULL,
  -- Message-id, post URN or listing id. The dedup key against re-polling the
  -- same source.
  external_ref         text,
  payload_ref          jsonb NOT NULL,   -- document ids / storage keys, headers
  received_at          timestamptz NOT NULL DEFAULT now(),
  status               text NOT NULL DEFAULT 'PENDING' CHECK (status IN (
                         'PENDING', 'PROCESSED', 'NEEDS_REVIEW', 'REJECTED', 'DUPLICATE')),
  resolved_entity_type text,             -- 'REQUIREMENT' | 'CANDIDATE' | ...
  resolved_entity_id   uuid,             -- polymorphic, deliberately un-FK'd
  agent_run_id         uuid,             -- the Intake Agent run that handled it
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),

  -- The design doc's UNIQUE (channel_account_id, external_ref) permits
  -- unlimited duplicates, because external_ref is nullable and NULLs compare
  -- as distinct. NULLS NOT DISTINCT (PG15+) closes that: at most one
  -- null-ref arrival per account.
  CONSTRAINT ingestion_events_account_ref_key
    UNIQUE NULLS NOT DISTINCT (channel_account_id, external_ref),

  CONSTRAINT ingestion_events_org_id_key UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, channel_account_id)
    REFERENCES channel_accounts (organization_id, id),
  FOREIGN KEY (organization_id, agent_run_id)
    REFERENCES agent_runs (organization_id, id)
);

CREATE INDEX ingestion_events_pending_idx
  ON ingestion_events (organization_id, received_at)
  WHERE status = 'PENDING';

CREATE INDEX ingestion_events_review_idx
  ON ingestion_events (organization_id, received_at DESC)
  WHERE status = 'NEEDS_REVIEW';

CREATE TRIGGER ingestion_events_set_updated_at
  BEFORE UPDATE ON ingestion_events
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- requirements — the job description
-- -----------------------------------------------------------------------------
-- The trigger for the entire §4.3 flow. raw_text is always preserved so a
-- parser upgrade can safely re-parse (§13); `parsed` holds the structured
-- extraction.
CREATE TABLE requirements (
  id                uuid PRIMARY KEY,
  organization_id   uuid NOT NULL REFERENCES organizations (id),
  title             text NOT NULL,
  status            text NOT NULL DEFAULT 'NEW' CHECK (status IN (
                      'NEW', 'PARSING', 'ACTIVE', 'ON_HOLD', 'FILLED', 'CLOSED', 'EXPIRED')),
  source_channel_id uuid REFERENCES channels (id),   -- how it arrived
  ingestion_id      uuid,
  vendor_party_id   uuid,                            -- who sent it
  client_party_id   uuid,                            -- prime / client if known
  end_client_name   text,                            -- often only a name is known
  jd_document_id    uuid,
  raw_text          text NOT NULL,
  parsed            jsonb,             -- duration, interview process, ...
  parser_version    text,
  location_city     text,
  location_state    text,
  work_mode         text CHECK (work_mode IN ('ONSITE', 'HYBRID', 'REMOTE')),
  employment_type   text CHECK (employment_type IN ('C2C', 'W2', '1099', 'FTE', 'ANY')),
  rate              jsonb NOT NULL DEFAULT '{}',     -- offered / max, unit, currency
  rate_max          numeric GENERATED ALWAYS AS
                      (NULLIF(rate ->> 'max', '')::numeric) STORED,
  positions_count   int NOT NULL DEFAULT 1 CHECK (positions_count >= 1),
  priority          text NOT NULL DEFAULT 'NORMAL'
                      CHECK (priority IN ('HOT', 'NORMAL', 'LOW')),
  owner_user_id     uuid,

  -- §9 mandates an Idempotency-Key on mutating routes but gives it no home in
  -- the schema. This is it for the upload/paste path; the email path is closed
  -- by the ingestion_id unique below.
  idempotency_key   text,

  received_at       timestamptz NOT NULL DEFAULT now(),
  respond_by        timestamptz,

  search_tsv        tsvector GENERATED ALWAYS AS (
                      setweight(to_tsvector('english', coalesce(title, '')),    'A') ||
                      setweight(to_tsvector('english', coalesce(raw_text, '')), 'B')
                    ) STORED,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,

  CONSTRAINT requirements_org_id_key         UNIQUE (organization_id, id),
  CONSTRAINT requirements_org_ingestion_key  UNIQUE (organization_id, ingestion_id),
  CONSTRAINT requirements_org_idempotency_key UNIQUE (organization_id, idempotency_key),

  FOREIGN KEY (organization_id, ingestion_id)    REFERENCES ingestion_events (organization_id, id),
  FOREIGN KEY (organization_id, vendor_party_id) REFERENCES parties (organization_id, id),
  FOREIGN KEY (organization_id, client_party_id) REFERENCES parties (organization_id, id),
  FOREIGN KEY (organization_id, jd_document_id)  REFERENCES documents (organization_id, id),
  FOREIGN KEY (organization_id, owner_user_id)   REFERENCES users (organization_id, id)
);

-- Requirement Inbox (§8.2): triage everything that arrived, hottest first.
-- The design doc's (organization_id, status, received_at DESC) omits both the
-- soft-delete predicate and the priority column the inbox actually sorts by.
CREATE INDEX requirements_inbox_idx
  ON requirements (organization_id, priority, status, received_at DESC)
  WHERE deleted_at IS NULL;

-- Aging / SLA indicator on the inbox cards.
CREATE INDEX requirements_respond_by_idx
  ON requirements (organization_id, respond_by)
  WHERE deleted_at IS NULL AND respond_by IS NOT NULL;

CREATE INDEX requirements_vendor_idx
  ON requirements (organization_id, vendor_party_id)
  WHERE deleted_at IS NULL;

CREATE INDEX requirements_fts_idx ON requirements USING gin (search_tsv);

CREATE TRIGGER requirements_set_updated_at
  BEFORE UPDATE ON requirements
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- requirement_skills — the JD's skill demands
-- -----------------------------------------------------------------------------
-- source_text is the verbatim JD phrase each requirement came from. It is the
-- evidence citation §8.3 requires whenever an explanation claims a skill was
-- mandatory.
CREATE TABLE requirement_skills (
  organization_id uuid NOT NULL REFERENCES organizations (id),
  requirement_id  uuid NOT NULL,
  skill_id        uuid NOT NULL REFERENCES skills (id),
  is_mandatory    boolean NOT NULL DEFAULT true,
  min_years       numeric(4,1) CHECK (min_years >= 0),
  weight          numeric(4,3) CHECK (weight >= 0 AND weight <= 1),  -- per-skill override
  source_text     text,
  created_at      timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (requirement_id, skill_id),
  FOREIGN KEY (organization_id, requirement_id) REFERENCES requirements (organization_id, id)
);

-- Coverage scoring walks the mandatory set for a requirement.
CREATE INDEX requirement_skills_mandatory_idx
  ON requirement_skills (requirement_id) WHERE is_mandatory;

CREATE INDEX requirement_skills_skill_idx
  ON requirement_skills (organization_id, skill_id);


-- =============================================================================