-- V8 REPAIR: matching_policies exists; create remaining V8 objects
-- Generated for the observed partial migration state.
-- Run once in the Supabase SQL Editor as postgres.

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.matching_policies') IS NULL THEN
    RAISE EXCEPTION 'matching_policies is missing; run the original V8 migration instead.';
  END IF;

  IF to_regclass('public.match_jobs') IS NOT NULL
     OR to_regclass('public.match_results') IS NOT NULL
     OR to_regclass('public.embeddings') IS NOT NULL THEN
    RAISE EXCEPTION 'One or more repair target tables already exist. Stop and inspect before rerunning.';
  END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS matching_policies_active_idx
  ON matching_policies (organization_id) NULLS NOT DISTINCT
  WHERE is_active;

DROP TRIGGER IF EXISTS matching_policies_set_updated_at ON matching_policies;
CREATE TRIGGER matching_policies_set_updated_at
  BEFORE UPDATE ON matching_policies
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

-- match_jobs — one matching execution for one requirement
-- -----------------------------------------------------------------------------
-- The business-facing handle on a run; the full trace lives on agent_runs.
CREATE TABLE match_jobs (
  id               uuid PRIMARY KEY,
  organization_id  uuid NOT NULL REFERENCES organizations (id),
  requirement_id   uuid NOT NULL,
  agent_run_id     uuid NOT NULL,
  -- Plain (not composite) FK: matching_policies rows may have a NULL
  -- organization_id for the platform default, so a composite key is impossible.
  policy_id        uuid NOT NULL REFERENCES matching_policies (id),

  -- The outbox event that triggered this job. See the unique constraint below.
  trigger_event_id uuid,

  status           text NOT NULL DEFAULT 'RUNNING' CHECK (status IN (
                     'RUNNING', 'COMPLETED', 'FAILED', 'CANCELLED')),
  stats            jsonb NOT NULL DEFAULT '{}',  -- retrieved / deduped / scored counts
  completed_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT match_jobs_org_id_key UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, requirement_id) REFERENCES requirements (organization_id, id),
  FOREIGN KEY (organization_id, agent_run_id)   REFERENCES agent_runs (organization_id, id)
);

-- §12 criterion 1: redelivery of a trigger event must not produce a second
-- match job. A "one RUNNING job per requirement" constraint alone would not
-- cover this — after the first job COMPLETES, a replayed event would insert
-- cleanly. Keying on the event closes that.
CREATE UNIQUE INDEX match_jobs_requirement_trigger_idx
  ON match_jobs (requirement_id, trigger_event_id)
  WHERE trigger_event_id IS NOT NULL;

-- Backstop for the concurrent case (pg-boss singleton keys are the primary
-- mechanism; this is the database-level guarantee).
CREATE UNIQUE INDEX match_jobs_one_running_idx
  ON match_jobs (requirement_id) WHERE status = 'RUNNING';

-- Requirement Inbox "match preview count" chip. The design doc declares no
-- index on match_jobs at all.
CREATE INDEX match_jobs_org_requirement_idx
  ON match_jobs (organization_id, requirement_id, status);

CREATE TRIGGER match_jobs_set_updated_at
  BEFORE UPDATE ON match_jobs
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- match_results — the ranked output
-- -----------------------------------------------------------------------------
-- The product's payload. Every row carries its full score breakdown, the
-- evidence pointers behind matched and missing skills, and the `versions`
-- object (policy, parser, embedding model, index) that makes the result
-- reproducible (§10).
--
-- recruiter_action / action_reason are the deliberate learning-to-rank seam
-- (§7.3, §12 criterion 9).
CREATE TABLE match_results (
  id               uuid PRIMARY KEY,
  -- Absent from the design doc's DDL, which leaves this table with no tenancy
  -- column to write an RLS policy against.
  organization_id  uuid NOT NULL REFERENCES organizations (id),
  match_job_id     uuid NOT NULL,
  candidate_id     uuid NOT NULL,
  rank             int  NOT NULL CHECK (rank >= 1),
  total_score      numeric(5,4) NOT NULL CHECK (total_score >= 0 AND total_score <= 1),
  score_breakdown  jsonb NOT NULL,   -- per-criterion score, weight, method
  matched_skills   jsonb NOT NULL,   -- [{skill_id, evidence:[profile pointers]}]
  missing_skills   jsonb NOT NULL,
  similarity       numeric(5,4),     -- raw cosine similarity from pgvector
  explanation      text,             -- recruiter-language, evidence-cited
  versions         jsonb NOT NULL,   -- policy, parser, embedding model, index
  recruiter_action text CHECK (recruiter_action IN (
                     'SHORTLISTED', 'SUBMITTED', 'REJECTED', 'IGNORED')),
  action_reason    text,             -- labeled feedback for learning-to-rank
  acted_by         uuid,
  acted_at         timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),  -- also absent from the doc
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT match_results_job_candidate_key UNIQUE (match_job_id, candidate_id),
  -- Without this, "rank" is not a well-defined ordering.
  CONSTRAINT match_results_job_rank_key      UNIQUE (match_job_id, rank),

  FOREIGN KEY (organization_id, match_job_id) REFERENCES match_jobs (organization_id, id),
  FOREIGN KEY (organization_id, candidate_id) REFERENCES candidates (organization_id, id),
  FOREIGN KEY (organization_id, acted_by)     REFERENCES users (organization_id, id)
);

-- Match Workspace: render one job's ranked list.
CREATE INDEX match_results_job_rank_idx ON match_results (match_job_id, rank);

-- Candidate 360: "where has this consultant been matched".
CREATE INDEX match_results_candidate_idx
  ON match_results (organization_id, candidate_id);

-- §12 criterion 9: recruiter reject/shortlist reasons must be queryable as the
-- training signal for future ranking work.
CREATE INDEX match_results_feedback_idx
  ON match_results (organization_id, recruiter_action, acted_at DESC)
  WHERE recruiter_action IS NOT NULL;

CREATE TRIGGER match_results_set_updated_at
  BEFORE UPDATE ON match_results
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- embeddings — pgvector store (§6.10)
-- -----------------------------------------------------------------------------
-- Model- and version-scoped so migration is additive: write new rows under the
-- new model name, backfill, flip the active model, drop the old rows. Never an
-- in-place mutation.
--
-- DIMENSIONALITY: vector(1024) is a hard typmod — an embedding of a different
-- width cannot be inserted at all, so the "write new rows under the new model"
-- story only works while dimensions match. Migrating to a wider model is an
-- additive DDL step:
--     ALTER TABLE embeddings ADD COLUMN embedding_v2 vector(3072);
--     ALTER TABLE embeddings ADD CONSTRAINT embeddings_one_vector
--       CHECK (num_nonnulls(embedding, embedding_v2) = 1);
--     CREATE INDEX ... USING hnsw (embedding_v2 vector_cosine_ops) WHERE model = '<new>';
-- 1024 matches the day-1 model (voyage-3-large).
CREATE TABLE embeddings (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  entity_type     text NOT NULL CHECK (entity_type IN ('CANDIDATE_PROFILE', 'REQUIREMENT')),
  entity_id       uuid NOT NULL,
  entity_version  int  NOT NULL,        -- profile_version / requirement parse version
  model           text NOT NULL,        -- 'voyage-3-large'
  dims            int  NOT NULL,
  embedding       vector(1024) NOT NULL,
  source_hash     text NOT NULL,        -- skip re-embedding unchanged text
  created_at      timestamptz NOT NULL DEFAULT now(),

  -- The doc carries a `dims` column alongside a fixed-width vector, where it
  -- can only ever drift. Pin it to the truth.
  CONSTRAINT embeddings_dims_match CHECK (dims = vector_dims(embedding)),

  CONSTRAINT embeddings_entity_model_key
    UNIQUE (organization_id, entity_type, entity_id, entity_version, model)
);

-- Approximate-nearest-neighbour index for candidate retrieval.
--
-- The model predicate is not optional. Without it, the index holds vectors from
-- two incompatible embedding spaces during a model migration and returns
-- meaningless neighbours *before* any filter can discard them. The migration
-- that flips the active model ships its own partial index.
--
-- RECALL: RLS and the business filters (availability, marketing_status, work
-- authorisation, rate band) are applied ABOVE this scan, so a small tenant can
-- have its true top-K truncated by post-filtering. The retrieval tool must set
--     SET LOCAL hnsw.iterative_scan = 'strict_order';
-- (pgvector 0.8+, asserted in V1). If a single tenant passes roughly 100k
-- vectors, LIST-partitioning this table by organization_id is the structural
-- fix and is an additive migration.
CREATE INDEX embeddings_candidate_hnsw_idx
  ON embeddings USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64)
  WHERE entity_type = 'CANDIDATE_PROFILE' AND model = 'voyage-3-large';

-- JD vector fetch: WHERE entity_type='REQUIREMENT' AND entity_id=$1 AND
-- model=$2 ORDER BY entity_version DESC LIMIT 1. This is an equality lookup,
-- not an ANN search, so a btree is the right structure.
CREATE INDEX embeddings_requirement_lookup_idx
  ON embeddings (organization_id, entity_id, model, entity_version DESC)
  WHERE entity_type = 'REQUIREMENT';

-- Content-hash cache probe: "has this exact text already been embedded under
-- this model?" (§4.3 step 5 skips re-embedding when it has).
CREATE INDEX embeddings_source_hash_idx
  ON embeddings (organization_id, model, source_hash);


COMMIT;

SELECT *
FROM (
  VALUES
    ('matching_policies', to_regclass('public.matching_policies')),
    ('match_jobs',        to_regclass('public.match_jobs')),
    ('match_results',     to_regclass('public.match_results')),
    ('embeddings',        to_regclass('public.embeddings'))
) AS v(table_name, relation);
