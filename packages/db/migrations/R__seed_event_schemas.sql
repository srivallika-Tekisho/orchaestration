-- R__seed_event_schemas — the day-1 event contract registry (Appendix B)
-- =============================================================================
-- docs/spec_database: "The events table should capture the schema used for this
-- particular event." This file is the literal answer — one row per
-- (event_type, schema_version) holding the JSON Schema that every producer
-- validates against and every consumer can read back.
--
-- WHY A REGISTRY AND NOT A CHECK CONSTRAINT: event_outbox.payload_ref is jsonb.
-- Without a registry the only description of a payload's shape lives in whatever
-- TypeScript happened to write it, so a consumer written six months later has no
-- way to know what an event from before its own deploy contained. The composite
-- FK from event_outbox (event_type, schema_version) makes registration
-- mandatory: an unregistered event type cannot be published at all.
--
-- -----------------------------------------------------------------------------
-- payload_schema IS IMMUTABLE PER VERSION
-- -----------------------------------------------------------------------------
-- The ON CONFLICT clause below refreshes only the documentation columns. It
-- deliberately does NOT update payload_schema or envelope_fields, because rows
-- already in event_outbox were validated against the stored schema — silently
-- rewriting it would retroactively change the contract of events that have
-- already been published and consumed.
--
-- Editing a payload_schema here therefore does not take effect. It fails the
-- migration instead, via the assertion at the bottom of this file, with a
-- message telling you to add a new schema_version row. That is the intended
-- workflow: contracts evolve by version, not by mutation. A new version is one
-- extra row and costs nothing.
--
-- For the same reason this file must never DELETE: event_outbox holds FK
-- references to these rows. Retiring an event type means status='DEPRECATED'.
--
-- -----------------------------------------------------------------------------
-- additionalProperties: false
-- -----------------------------------------------------------------------------
-- Chosen over permissive schemas because the failure this registry exists to
-- prevent is a producer typo — `requirment_id` — which a permissive schema
-- accepts and every consumer then silently reads as undefined. Strictness turns
-- that into a validation error at publish time. The cost is that adding a field
-- needs a schema_version bump, which is the point.
-- =============================================================================


-- Staged in a temp table so the seed data is written once and can be used both
-- for the upsert and for the immutability assertion, with no duplication.
--
-- Explicitly dropped at the end of the file rather than declared ON COMMIT DROP:
-- ON COMMIT DROP is fine under Flyway (which wraps each migration in a
-- transaction) but destroys the table at the end of the CREATE statement when
-- the file is run straight through `psql -f` with autocommit, which is how CI
-- runs the repeatables. This way both paths work.
DROP TABLE IF EXISTS _seed_event_schemas;

CREATE TEMP TABLE _seed_event_schemas (
  event_type       text PRIMARY KEY,
  description      text  NOT NULL,
  produced_when    text  NOT NULL,   -- Appendix B, column 2
  primary_consumer text  NOT NULL,   -- Appendix B, column 3
  payload_schema   jsonb NOT NULL
);


INSERT INTO _seed_event_schemas VALUES

-- ---------------------------------------------------------------------------
-- 1. syntra.jd.received — the trigger for the entire §4.3 day-1 flow
-- ---------------------------------------------------------------------------
-- `title` is carried so the SSE toast can name the requirement without a second
-- round trip. Everything else is a reference: payloads never carry JD text.
('syntra.jd.received',
 'A requirement was created from any channel and is ready to be matched.',
 'Requirement created (any channel)',
 'Matching Agent trigger',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.jd.received payload",
    "type": "object",
    "required": ["requirement_id"],
    "additionalProperties": false,
    "properties": {
      "requirement_id": { "type": "string", "format": "uuid" },
      "ingestion_id":   { "type": ["string", "null"], "format": "uuid",
                          "description": "Set when the JD arrived through a channel connector; null for direct upload or paste." },
      "jd_document_id": { "type": ["string", "null"], "format": "uuid" },
      "channel_type":   { "type": "string",
                          "enum": ["EMAIL", "LINKEDIN", "DICE", "MONSTER", "INDEED",
                                   "PORTAL", "WHATSAPP", "MANUAL", "API"] },
      "priority":       { "type": "string", "enum": ["HOT", "NORMAL", "LOW"] },
      "title":          { "type": "string", "maxLength": 500 }
    }
  }'),

-- ---------------------------------------------------------------------------
-- 2. syntra.jd.parsed
-- ---------------------------------------------------------------------------
-- parser_version is required, not optional: it is what makes a later re-parse
-- attributable and is half of the reproducibility contract in §10.
('syntra.jd.parsed',
 'Structured requirement and its skill demands were persisted.',
 'Structured requirement persisted',
 'UI notify; future continuous-match',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.jd.parsed payload",
    "type": "object",
    "required": ["requirement_id", "parser_version"],
    "additionalProperties": false,
    "properties": {
      "requirement_id":         { "type": "string", "format": "uuid" },
      "parser_version":         { "type": "string" },
      "agent_run_id":           { "type": ["string", "null"], "format": "uuid" },
      "mandatory_skill_count":  { "type": "integer", "minimum": 0 },
      "optional_skill_count":   { "type": "integer", "minimum": 0 }
    }
  }'),

-- ---------------------------------------------------------------------------
-- 3. syntra.resume.received
-- ---------------------------------------------------------------------------
-- sha256 travels in the payload so the profile-preparation consumer can hit the
-- documents parse cache (§4.3 step 6) without first reading the document row.
('syntra.resume.received',
 'A resume document was stored and is ready for parsing and embedding.',
 'Resume document stored',
 'Profile preparation job',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.resume.received payload",
    "type": "object",
    "required": ["document_id", "candidate_id"],
    "additionalProperties": false,
    "properties": {
      "document_id":  { "type": "string", "format": "uuid" },
      "candidate_id": { "type": "string", "format": "uuid",
                        "description": "Provisional on bulk upload; dedup may later merge this candidate away." },
      "sha256":       { "type": "string", "pattern": "^[a-f0-9]{64}$" },
      "source":       { "type": "string", "enum": ["UPLOAD", "EMAIL", "CHANNEL", "AGENT"] }
    }
  }'),

-- ---------------------------------------------------------------------------
-- 4. syntra.profile.prepared
-- ---------------------------------------------------------------------------
('syntra.profile.prepared',
 'Resume parse, skill normalisation and embedding completed for one profile version.',
 'Parse + embed complete',
 'Dedup check; future bench alerts',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.profile.prepared payload",
    "type": "object",
    "required": ["candidate_id", "candidate_profile_id", "profile_version"],
    "additionalProperties": false,
    "properties": {
      "candidate_id":         { "type": "string", "format": "uuid" },
      "candidate_profile_id": { "type": "string", "format": "uuid" },
      "profile_version":      { "type": "integer", "minimum": 1 },
      "parser_version":       { "type": "string" },
      "embedding_model":      { "type": "string" },
      "skill_count":          { "type": "integer", "minimum": 0 },
      "agent_run_id":         { "type": ["string", "null"], "format": "uuid" }
    }
  }'),

-- ---------------------------------------------------------------------------
-- 5. syntra.duplicate.review_required
-- ---------------------------------------------------------------------------
-- §12 criterion 3: probable duplicates are never merged silently. The signals
-- object is a summary for the queue card; the authoritative copy is
-- duplicate_reviews.signals.
('syntra.duplicate.review_required',
 'Two candidates are probably the same person and need a human decision. Never auto-merged.',
 'Probable duplicate detected',
 'Approvals queue',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.duplicate.review_required payload",
    "type": "object",
    "required": ["duplicate_review_id", "candidate_a", "candidate_b"],
    "additionalProperties": false,
    "properties": {
      "duplicate_review_id": { "type": "string", "format": "uuid" },
      "candidate_a":         { "type": "string", "format": "uuid" },
      "candidate_b":         { "type": "string", "format": "uuid" },
      "approval_id":         { "type": ["string", "null"], "format": "uuid" },
      "agent_run_id":        { "type": ["string", "null"], "format": "uuid" },
      "signals": {
        "type": "object",
        "additionalProperties": true,
        "properties": {
          "name_similarity":      { "type": "number", "minimum": 0, "maximum": 1 },
          "embedding_similarity": { "type": "number", "minimum": 0, "maximum": 1 },
          "employer_overlap":     { "type": "boolean" },
          "education_match":      { "type": "boolean" }
        }
      }
    }
  }'),

-- ---------------------------------------------------------------------------
-- 6. syntra.match.completed
-- ---------------------------------------------------------------------------
-- The event the recruiter's browser is waiting on. policy_id and the version
-- refs are included so the UI can label results as reproducible without
-- reading match_results first.
('syntra.match.completed',
 'Ranked, explained match results were persisted for one requirement.',
 'Results persisted',
 'UI notify; activity spine',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.match.completed payload",
    "type": "object",
    "required": ["match_job_id", "requirement_id", "result_count"],
    "additionalProperties": false,
    "properties": {
      "match_job_id":   { "type": "string", "format": "uuid" },
      "requirement_id": { "type": "string", "format": "uuid" },
      "agent_run_id":   { "type": ["string", "null"], "format": "uuid" },
      "policy_id":      { "type": ["string", "null"], "format": "uuid" },
      "result_count":   { "type": "integer", "minimum": 0 },
      "top_score":      { "type": ["number", "null"], "minimum": 0, "maximum": 1 },
      "stats": {
        "type": "object",
        "additionalProperties": true,
        "properties": {
          "retrieved": { "type": "integer", "minimum": 0 },
          "deduped":   { "type": "integer", "minimum": 0 },
          "scored":    { "type": "integer", "minimum": 0 }
        }
      }
    }
  }'),

-- ---------------------------------------------------------------------------
-- 7. syntra.approval.requested
-- ---------------------------------------------------------------------------
-- Appendix B lists requested/decided as one line; they are two event types
-- because they have different payloads and different consumers.
('syntra.approval.requested',
 'An agent hit an autonomy boundary, created an approval item and interrupted its run.',
 'HITL interrupt lifecycle',
 'Runtime resume; UI',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.approval.requested payload",
    "type": "object",
    "required": ["approval_id", "agent_run_id", "action_class"],
    "additionalProperties": false,
    "properties": {
      "approval_id":  { "type": "string", "format": "uuid" },
      "agent_run_id": { "type": "string", "format": "uuid" },
      "action_class": { "type": "string" },
      "entity_type":  { "type": ["string", "null"] },
      "entity_id":    { "type": ["string", "null"], "format": "uuid" },
      "expires_at":   { "type": ["string", "null"], "format": "date-time" }
    }
  }'),

-- ---------------------------------------------------------------------------
-- 8. syntra.approval.decided
-- ---------------------------------------------------------------------------
-- EXPIRED is a valid decision: the sweeper that times an approval out emits
-- this event so the paused run is resumed (and fails cleanly) rather than
-- leaking a checkpoint that nothing will ever wake.
('syntra.approval.decided',
 'An approval item reached a terminal state; the paused run can be resumed.',
 'HITL interrupt lifecycle',
 'Runtime resume; UI',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.approval.decided payload",
    "type": "object",
    "required": ["approval_id", "agent_run_id", "decision"],
    "additionalProperties": false,
    "properties": {
      "approval_id":   { "type": "string", "format": "uuid" },
      "agent_run_id":  { "type": "string", "format": "uuid" },
      "decision":      { "type": "string", "enum": ["APPROVED", "MODIFIED", "REJECTED", "EXPIRED"] },
      "decided_by":    { "type": ["string", "null"], "format": "uuid",
                         "description": "Null when the decision is EXPIRED, i.e. made by the sweeper." },
      "decision_note": { "type": ["string", "null"] }
    }
  }'),

-- ---------------------------------------------------------------------------
-- 9. syntra.agent_run.failed
-- ---------------------------------------------------------------------------
('syntra.agent_run.failed',
 'An agent run exhausted its retries and terminated. Feeds alerting and the replay admin.',
 'Run exhausted retries',
 'Alerting; replay admin',
 '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "syntra.agent_run.failed payload",
    "type": "object",
    "required": ["agent_run_id", "agent_name", "error_code"],
    "additionalProperties": false,
    "properties": {
      "agent_run_id":   { "type": "string", "format": "uuid" },
      "agent_name":     { "type": "string" },
      "error_code":     { "type": "string" },
      "error_message":  { "type": ["string", "null"],
                          "description": "Redacted per data policy. Never carries candidate PII." },
      "failed_node":    { "type": ["string", "null"] },
      "failed_step_seq":{ "type": ["integer", "null"], "minimum": 1 },
      "attempts":       { "type": "integer", "minimum": 1 }
    }
  }');


-- -----------------------------------------------------------------------------
-- Upsert
-- -----------------------------------------------------------------------------
-- The envelope is identical for every event type (Appendix B: "Envelope:
-- unchanged from v1 ... deliberately Kafka-compatible"), so it is written once
-- and cross-joined. Defining it per row would let the nine copies drift.
--
-- NOTE ON SHAPE: the envelope below is the PUBLISHED (wire) form, with a nested
-- `aggregate` object. event_outbox stores it flattened into aggregate_type and
-- aggregate_id — the relay composes the nested form when it publishes. This
-- column documents what a consumer receives, not what the table holds.
--
-- `format` keywords are assertions only if the validator enables the format
-- vocabulary; with Ajv that means registering ajv-formats.
WITH envelope AS (
  SELECT '{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "Syntra event envelope",
    "type": "object",
    "required": ["event_id", "event_type", "schema_version", "occurred_at",
                 "correlation_id", "organization_id", "aggregate", "payload_ref", "producer"],
    "additionalProperties": false,
    "properties": {
      "event_id":        { "type": "string", "format": "uuid" },
      "event_type":      { "type": "string" },
      "schema_version":  { "type": "string" },
      "occurred_at":     { "type": "string", "format": "date-time" },
      "correlation_id":  { "type": "string", "format": "uuid",
                           "description": "Stable across the whole causal chain from one recruiter action." },
      "causation_id":    { "type": ["string", "null"], "format": "uuid",
                           "description": "event_id of the immediately preceding event. Null for chain roots." },
      "organization_id": { "type": "string", "format": "uuid" },
      "aggregate": {
        "type": "object",
        "required": ["type", "id"],
        "additionalProperties": false,
        "properties": {
          "type": { "type": "string" },
          "id":   { "type": "string", "format": "uuid" }
        }
      },
      "payload_ref":     { "type": "object",
                           "description": "Entity references and small scalars only. Never document bytes or resume text." },
      "producer":        { "type": "string" }
    }
  }'::jsonb AS fields
)
INSERT INTO event_schemas (
  event_type, schema_version, description, payload_schema,
  envelope_fields, produced_when, primary_consumer, status
)
SELECT s.event_type, '1.0', s.description, s.payload_schema,
       e.fields, s.produced_when, s.primary_consumer, 'ACTIVE'
FROM _seed_event_schemas s
CROSS JOIN envelope e
ON CONFLICT (event_type, schema_version) DO UPDATE
  SET description      = EXCLUDED.description,
      produced_when    = EXCLUDED.produced_when,
      primary_consumer = EXCLUDED.primary_consumer
      -- payload_schema and envelope_fields are intentionally absent. See header.
  -- Skip the write entirely when nothing changed, so the set_updated_at trigger
  -- does not stamp all nine rows on every re-run and updated_at keeps meaning
  -- "when this contract's documentation last actually changed".
  WHERE event_schemas.description      IS DISTINCT FROM EXCLUDED.description
     OR event_schemas.produced_when    IS DISTINCT FROM EXCLUDED.produced_when
     OR event_schemas.primary_consumer IS DISTINCT FROM EXCLUDED.primary_consumer;


-- -----------------------------------------------------------------------------
-- Immutability assertion
-- -----------------------------------------------------------------------------
-- Turns "my edit to payload_schema had no effect" from a silent no-op into a
-- failed migration. jsonb equality ignores key order and whitespace, so
-- reformatting a literal above will not trip this — only a real change will.
DO $$
DECLARE
  offenders text;
BEGIN
  SELECT string_agg(s.event_type, ', ' ORDER BY s.event_type)
    INTO offenders
  FROM _seed_event_schemas s
  JOIN event_schemas es
    ON es.event_type = s.event_type
   AND es.schema_version = '1.0'
  WHERE es.payload_schema <> s.payload_schema;

  IF offenders IS NOT NULL THEN
    RAISE EXCEPTION
      'payload_schema in this file differs from the registered schema for: %. '
      'Registered schemas are immutable — events already in event_outbox were '
      'validated against them. Add a new schema_version row instead of editing '
      'version 1.0, and have producers emit the new version.',
      offenders;
  END IF;

  RAISE NOTICE 'event_schemas: % day-1 event contracts registered at version 1.0.',
    (SELECT count(*) FROM _seed_event_schemas);
END
$$;

DROP TABLE _seed_event_schemas;


-- =============================================================================