-- =============================================================================
-- R__runtime_table_policies — tenancy for library-owned tables
-- =============================================================================
-- pg-boss and the LangGraph PostgreSQL checkpointer create and version their
-- own DDL. Reproducing it in Flyway would guarantee drift on library upgrade,
-- so V1 only creates the schemas they live in and this file applies the tenancy
-- controls the libraries do not.
--
-- THE HOLE THIS CLOSES: LangGraph checkpoint rows carry serialised graph state —
-- JD text, parsed resumes, candidate PII — keyed only by thread_id, with no
-- organization_id and no RLS. §10 claims "cross-org access is structurally
-- impossible" and §12 requires RLS tests across tables; both are false for these
-- tables as the libraries ship them.
--
-- The fix relies on agent_runs.thread_id being formatted '<org_uuid>:<run_uuid>'
-- (enforced by a CHECK constraint in V3), so the tenant is recoverable from the
-- key by prefix. Retrofitting this after checkpoints exist means rewriting every
-- thread_id, which is why the format is fixed on day 1.
--
-- DEPLOY ORDER: application bootstrap must run boss.migrate() and
-- checkpointer.setup() BEFORE `flyway migrate`. This file raises if the tables
-- are missing rather than silently skipping — a silent skip is how an
-- unprotected checkpoint table reaches production.
-- =============================================================================

DO $$
DECLARE
  t record;
  found_any boolean := false;
BEGIN
  -- ---------------------------------------------------------------------------
  -- LangGraph checkpoint tables
  -- ---------------------------------------------------------------------------
  IF to_regnamespace('langgraph') IS NULL THEN
    RAISE EXCEPTION
      'Schema "langgraph" does not exist. V1 should have created it.';
  END IF;

  FOR t IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'langgraph'
      AND c.relkind = 'r'
      -- Every checkpoint table is keyed by thread_id; the checkpointer's own
      -- migration bookkeeping table is not, and needs no policy.
      AND EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = c.oid AND a.attname = 'thread_id' AND a.attnum > 0
      )
  LOOP
    found_any := true;

    -- V1's ALTER DEFAULT PRIVILEGES is scoped to schema public, and these tables
    -- are created by ${migrator_role} during bootstrap, so the runtime role has
    -- no table-level rights on them yet. Without this GRANT the agent runtime
    -- cannot checkpoint at all — and the failure surfaces as a permission error
    -- from inside LangGraph rather than anywhere near this file.
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON langgraph.%I TO %I',
                   t.relname, '${app_role}');

    EXECUTE format('ALTER TABLE langgraph.%I ENABLE ROW LEVEL SECURITY', t.relname);
    EXECUTE format('ALTER TABLE langgraph.%I FORCE  ROW LEVEL SECURITY', t.relname);

    EXECUTE format('DROP POLICY IF EXISTS %I ON langgraph.%I',
                   t.relname || '_tenant_isolation', t.relname);

    -- Prefix match on the org uuid. app.current_org_id() is NULL when the GUC
    -- is unset, which makes the whole LIKE pattern NULL and matches no rows —
    -- the same fail-closed behaviour as the business tables.
    EXECUTE format(
      'CREATE POLICY %I ON langgraph.%I FOR ALL TO %I '
      'USING (thread_id LIKE app.current_org_id()::text || '':%%'') '
      'WITH CHECK (thread_id LIKE app.current_org_id()::text || '':%%'')',
      t.relname || '_tenant_isolation', t.relname, '${app_role}'
    );

    RAISE NOTICE 'Applied tenant isolation to langgraph.%', t.relname;
  END LOOP;

  IF NOT found_any THEN
    RAISE EXCEPTION
      'No thread_id-keyed tables found in schema "langgraph". Run the LangGraph '
      'checkpointer setup() before flyway migrate — see the deploy order in V1.';
  END IF;

  -- ---------------------------------------------------------------------------
  -- pg-boss
  -- ---------------------------------------------------------------------------
  -- Job payloads carry entity references rather than blobs, but a job row still
  -- names the requirement and org it belongs to. pg-boss has no tenant column
  -- to filter on and its workers are cross-org by design, so isolation here is
  -- by GRANT: only ${relay_role} may touch the queue, and ${app_role} — the
  -- role serving tenant HTTP requests — is denied entirely.
  IF to_regnamespace('pgboss') IS NULL THEN
    RAISE EXCEPTION 'Schema "pgboss" does not exist. V1 should have created it.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgboss' AND c.relkind = 'r'
  ) THEN
    RAISE EXCEPTION
      'Schema "pgboss" is empty. Run boss.migrate() before flyway migrate — '
      'see the deploy order in V1.';
  END IF;

  EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA pgboss FROM %I', '${app_role}');
  EXECUTE format('REVOKE USAGE, CREATE ON SCHEMA pgboss FROM %I', '${app_role}');
  EXECUTE format('GRANT  ALL ON ALL TABLES IN SCHEMA pgboss TO %I', '${relay_role}');
  EXECUTE format('GRANT  USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgboss TO %I', '${relay_role}');
END
$$;