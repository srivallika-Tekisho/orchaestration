-- V1 — Extensions, conventions, RLS helpers
-- =============================================================================
-- Syntra day-1 schema. Reference: docs/Syntra_Agentic_Bench_Sales_Platform_Design_v2.docx
--
-- CONVENTIONS ESTABLISHED HERE (assumed by every later migration):
--
--   * IDs are `uuid PRIMARY KEY` with NO database default. The application
--     supplies UUIDv7 (npm `uuid`, v7 export). PostgreSQL 16 has no native
--     uuidv7(); rather than depend on the pg_uuidv7 extension we keep ID
--     generation in the app, which also keeps the ID available before INSERT.
--
--   * organization_id uuid NOT NULL REFERENCES organizations(id) on every
--     business table (design doc §3, "Tenant isolation everywhere").
--
--   * Every org-owned parent carries UNIQUE (organization_id, id) so children
--     can take a COMPOSITE foreign key on (organization_id, parent_id). This
--     makes the denormalised organization_id structurally unable to drift from
--     its parent's, instead of relying on write-path discipline.
--
--   * created_at / updated_at timestamptz NOT NULL DEFAULT now().
--     updated_at is maintained by the app.set_updated_at() trigger below.
--     Append-only tables (activities, audit_logs, event_outbox, agent_steps,
--     processed_events) carry only a creation timestamp.
--
--   * Enums are text + CHECK, per design doc §6.1 (cheap to extend).
--
-- DEPLOY ORDER — this migration set assumes:
--   1. IaC provisions the database and the three roles (see below).
--   2. Application bootstrap runs pg-boss `boss.migrate()` and the LangGraph
--      `checkpointer.setup()`. Both own and version their own DDL; duplicating
--      it in Flyway guarantees drift on library upgrade. They must run BEFORE
--      Flyway so that R__runtime_table_policies.sql can apply RLS to the tables
--      they create.
--   3. `flyway migrate`.
--
-- REQUIRED PRIVILEGES: creating extensions needs rds_superuser (RDS),
-- neon_superuser (Neon), or superuser. Run V1 as the migrator role with that
-- grant; later migrations need only ordinary DDL rights.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Extensions
-- -----------------------------------------------------------------------------
-- vector  — embeddings + HNSW index (design doc §6.10)
-- citext  — case-insensitive email and skill-alias columns (§6.2, §6.5).
--           The design doc's DDL uses citext but never creates the extension;
--           without this V2 fails immediately on users.email.
-- pg_trgm — trigram name similarity for probable-duplicate detection (§7.2),
--           likewise used but never declared in the design doc.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;


-- pgvector 0.8.0 introduced iterative index scans (hnsw.iterative_scan), which
-- the hybrid retrieval tool sets to 'strict_order'. Without it, post-filtering
-- an ANN scan by RLS + availability + work authorisation silently truncates
-- top-K recall for smaller tenants. Design doc §4.1 says "pgvector 0.7+";
-- 0.8+ is the real floor.
DO $$
DECLARE
  v text;
BEGIN
  SELECT extversion INTO v FROM pg_extension WHERE extname = 'vector';
  IF string_to_array(v, '.')::int[] < ARRAY[0, 8, 0] THEN
    RAISE EXCEPTION
      'pgvector >= 0.8.0 is required (found %). Needed for hnsw.iterative_scan.', v;
  END IF;
END
$$;


-- -----------------------------------------------------------------------------
-- Role assertions
-- -----------------------------------------------------------------------------
-- Roles are CLUSTER-scoped, so creating them here would race between parallel
-- CI databases sharing a cluster. They are provisioned by IaC; this migration
-- only asserts they exist and are safe.
--
--   syntra_app     API + agent runtime. Sets app.org_id per request.
--                   Subject to RLS. Never BYPASSRLS.
--   syntra_relay   Outbox relay + pg-boss workers. Operates cross-org and
--                   cannot set app.org_id, so it gets explicit USING (true)
--                   policies on the queue tables in V10 — deliberately narrower
--                   than granting BYPASSRLS.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'syntra_app') THEN
    RAISE EXCEPTION
      'Role "%" does not exist. Provision it in IaC before running migrations.',
      'syntra_app';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'syntra_relay') THEN
    RAISE EXCEPTION
      'Role "%" does not exist. Provision it in IaC before running migrations.',
      'syntra_relay';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'syntra_app' AND (rolsuper OR rolbypassrls)
  ) THEN
    RAISE EXCEPTION
      'Role "%" is SUPERUSER or BYPASSRLS; row-level security would not apply to it.',
      'syntra_app';
  END IF;
END
$$;


-- -----------------------------------------------------------------------------
-- app schema — tenancy helpers
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS app;

GRANT USAGE ON SCHEMA app    TO syntra_app, syntra_relay;
GRANT USAGE ON SCHEMA public TO syntra_app, syntra_relay;


-- The tenancy predicate used by every RLS policy.
--
-- STABLE (not IMMUTABLE): the planner folds it once per query, so policies
-- still resolve to index scans, while a change of GUC between statements is
-- picked up correctly.
--
-- current_setting(..., true) returns NULL rather than raising when app.org_id
-- is unset. Combined with `organization_id = app.current_org_id()`, an unset
-- GUC yields NULL and therefore matches no rows — the system FAILS CLOSED.
CREATE OR REPLACE FUNCTION app.current_org_id() RETURNS uuid
  LANGUAGE sql
  STABLE
  AS $$
    SELECT NULLIF(current_setting('app.org_id', true), '')::uuid
  $$;

COMMENT ON FUNCTION app.current_org_id() IS
  'Current tenant from the app.org_id GUC. NULL when unset, so RLS fails closed.';


-- Design doc §6.1 promises updated_at on all tables but no DDL maintains it.
CREATE OR REPLACE FUNCTION app.set_updated_at() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    NEW.updated_at := now();
    RETURN NEW;
  END
  $$;


-- -----------------------------------------------------------------------------
-- Default privileges
-- -----------------------------------------------------------------------------
-- Applied BEFORE any table exists, so every table created by later migrations
-- picks these up automatically and no migration has to remember to GRANT.
-- Scoped to objects created by the current (migrator) role.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO syntra_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO syntra_relay;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO syntra_app, syntra_relay;


-- -----------------------------------------------------------------------------
-- Schemas owned by the runtime libraries
-- -----------------------------------------------------------------------------
-- Created here so pg-boss and the LangGraph checkpointer do not scatter tables
-- into public (which would also confuse R__rls_assert.sql). The libraries
-- create and version their own tables inside these schemas.
--
-- Configure pg-boss with `schema: 'pgboss'` and the LangGraph PostgresSaver
-- with a search_path of 'langgraph'.
--
-- IMPORTANT: bootstrap must run boss.migrate() and checkpointer.setup() as
-- syntra_migrator, NOT as syntra_app. A role that creates a table owns it,
-- and an owner is not constrained by REVOKE — so letting the application role
-- create these tables would hand it permanent unmediated access to every
-- tenant's checkpoint state. Neither runtime role gets CREATE here.
CREATE SCHEMA IF NOT EXISTS pgboss;
CREATE SCHEMA IF NOT EXISTS langgraph;

-- Only the relay touches the job queue; the API role is denied entirely.
GRANT USAGE ON SCHEMA pgboss TO syntra_relay;

-- The agent runtime reads and writes checkpoints at run time, under the RLS
-- policy applied by R__runtime_table_policies.sql.
GRANT USAGE ON SCHEMA langgraph TO syntra_app;


-- =============================================================================