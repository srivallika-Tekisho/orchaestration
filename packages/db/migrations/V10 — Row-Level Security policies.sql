-- V10 — Row-Level Security policies (design doc §3, §10)
-- =============================================================================
-- "Cross-org access is structurally impossible, not just filtered."
--
-- Two mechanisms carry that claim:
--
--   1. ENABLE ROW LEVEL SECURITY makes policies apply to ordinary roles.
--   2. FORCE ROW LEVEL SECURITY makes them apply to the TABLE OWNER too.
--      Without FORCE, anything connecting as the owner — including a
--      misconfigured application — bypasses every policy silently, and the
--      isolation tests in §12 pass vacuously.
--
-- All predicates go through app.current_org_id() (V1), which returns NULL when
-- the app.org_id GUC is unset. `organization_id = NULL` matches nothing, so an
-- unset tenant context yields zero rows rather than all rows: FAIL CLOSED.
--
-- ROLES
--   syntra_app       API + agent runtime. One org at a time, set per request.
--   syntra_relay     Outbox relay + pg-boss workers. Cross-org by nature and
--                     unable to set app.org_id. Given explicit USING (true)
--                     policies on the two queue tables only — deliberately
--                     narrower than granting it BYPASSRLS.
--   syntra_migrator  Flyway. Owns the tables. Needs an explicit policy on
--                     matching_policies because that table is FORCE'd and the
--                     repeatable seed writes the platform default row.
--
-- PLATFORM REFERENCE TABLES (skills, skill_aliases, channels, agent_definitions,
-- event_schemas) hold no tenant data. They get RLS with a read-for-all policy
-- but NOT FORCE, so migrations can seed them, and write access is withheld from
-- syntra_app by GRANT rather than by policy. R__rls_assert.sql knows this
-- exemption list.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Standard tenant isolation
-- -----------------------------------------------------------------------------
-- Applied as a loop rather than 18 hand-written blocks so that no single table
-- can be given a subtly different predicate by a typo.
DO $$
DECLARE
  t text;
  tenant_tables text[] := ARRAY[
    'users',
    'parties',
    'documents',
    'candidates',
    'candidate_identities',
    'candidate_profiles',
    'candidate_skills',
    'duplicate_reviews',
    'channel_accounts',
    'ingestion_events',
    'requirements',
    'requirement_skills',
    'match_jobs',
    'match_results',
    'embeddings',
    'agent_runs',
    'agent_steps',
    'approvals'
  ];
BEGIN
  FOREACH t IN ARRAY tenant_tables
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR ALL TO %I '
      'USING (organization_id = app.current_org_id()) '
      'WITH CHECK (organization_id = app.current_org_id())',
      t || '_tenant_isolation', t, 'syntra_app'
    );
  END LOOP;
END
$$;


-- -----------------------------------------------------------------------------
-- organizations — a tenant sees only itself
-- -----------------------------------------------------------------------------
-- Note the predicate is `id`, not `organization_id`.
-- The application may read and update only its own row. It gets no INSERT or
-- DELETE policy: provisioning and deprovisioning a tenant is an operator action.
--
-- The migrator policy below is what makes that operator action possible, and it
-- is not optional. `FORCE ROW LEVEL SECURITY` subjects the table owner to
-- policies too, so without an explicit migrator policy *no role can create an
-- organization at all* — the first onboarding INSERT fails with "new row
-- violates row-level security policy". A real superuser would bypass FORCE, but
-- managed platforms do not hand one out (rds_superuser and neon_superuser are
-- not superusers), so this would surface in production and not in local testing.
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations FORCE  ROW LEVEL SECURITY;

CREATE POLICY organizations_self_select ON organizations
  FOR SELECT TO syntra_app
  USING (id = app.current_org_id());

CREATE POLICY organizations_self_update ON organizations
  FOR UPDATE TO syntra_app
  USING (id = app.current_org_id())
  WITH CHECK (id = app.current_org_id());

CREATE POLICY organizations_migrator ON organizations
  FOR ALL TO syntra_migrator
  USING (true)
  WITH CHECK (true);


-- -----------------------------------------------------------------------------
-- Append-only tenant tables
-- -----------------------------------------------------------------------------
-- SELECT and INSERT only. No UPDATE or DELETE policy exists, so the append-only
-- guarantee is enforced by the database rather than by convention — which is
-- what makes the activity timeline and the audit trail trustworthy as evidence.
ALTER TABLE activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities FORCE  ROW LEVEL SECURITY;

CREATE POLICY activities_tenant_select ON activities
  FOR SELECT TO syntra_app
  USING (organization_id = app.current_org_id());

CREATE POLICY activities_tenant_insert ON activities
  FOR INSERT TO syntra_app
  WITH CHECK (organization_id = app.current_org_id());


ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs FORCE  ROW LEVEL SECURITY;

CREATE POLICY audit_logs_tenant_select ON audit_logs
  FOR SELECT TO syntra_app
  USING (organization_id = app.current_org_id());

CREATE POLICY audit_logs_tenant_insert ON audit_logs
  FOR INSERT TO syntra_app
  WITH CHECK (organization_id = app.current_org_id());


-- -----------------------------------------------------------------------------
-- matching_policies — tenant rows plus a shared platform default
-- -----------------------------------------------------------------------------
-- organization_id IS NULL is the platform default every tenant reads.
--
-- A single FOR ALL policy with USING (organization_id IS NULL OR ...) would
-- apply that same predicate to UPDATE and DELETE, letting any tenant modify or
-- delete the platform default for everyone. The read and write predicates must
-- therefore differ.
ALTER TABLE matching_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE matching_policies FORCE  ROW LEVEL SECURITY;

CREATE POLICY matching_policies_read ON matching_policies
  FOR SELECT TO syntra_app
  USING (organization_id IS NULL OR organization_id = app.current_org_id());

CREATE POLICY matching_policies_insert ON matching_policies
  FOR INSERT TO syntra_app
  WITH CHECK (organization_id = app.current_org_id());

CREATE POLICY matching_policies_update ON matching_policies
  FOR UPDATE TO syntra_app
  USING (organization_id = app.current_org_id())
  WITH CHECK (organization_id = app.current_org_id());

CREATE POLICY matching_policies_delete ON matching_policies
  FOR DELETE TO syntra_app
  USING (organization_id = app.current_org_id());

-- The table is FORCE'd, so the owner needs an explicit policy for
-- R__seed_matching_policy.sql to write the platform default row.
CREATE POLICY matching_policies_migrator ON matching_policies
  FOR ALL TO syntra_migrator
  USING (true)
  WITH CHECK (true);


-- -----------------------------------------------------------------------------
-- event_outbox — tenant reads, relay publishes
-- -----------------------------------------------------------------------------
-- The app's SELECT policy is load-bearing beyond auditing: §9 specifies SSE
-- with a resumable Last-Event-ID, and LISTEN/NOTIFY is not replayable. A
-- reconnecting client reads forward from this table, so the app must be able to
-- read its own org's events.
--
-- No UPDATE policy for the app: only the relay marks rows published.
ALTER TABLE event_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_outbox FORCE  ROW LEVEL SECURITY;

CREATE POLICY event_outbox_tenant_select ON event_outbox
  FOR SELECT TO syntra_app
  USING (organization_id = app.current_org_id());

CREATE POLICY event_outbox_tenant_insert ON event_outbox
  FOR INSERT TO syntra_app
  WITH CHECK (organization_id = app.current_org_id());

-- Without this the relay reads zero rows under RLS and the entire §4.3 dispatch
-- step stalls silently — no error, just an outbox that never drains.
CREATE POLICY event_outbox_relay_all ON event_outbox
  FOR ALL TO syntra_relay
  USING (true)
  WITH CHECK (true);


-- -----------------------------------------------------------------------------
-- processed_events — queue infrastructure, relay only
-- -----------------------------------------------------------------------------
-- Not org-scoped: it is a consumer idempotency ledger. syntra_app gets no
-- policy at all, so RLS denies it every row.
ALTER TABLE processed_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE processed_events FORCE  ROW LEVEL SECURITY;

CREATE POLICY processed_events_relay_all ON processed_events
  FOR ALL TO syntra_relay
  USING (true)
  WITH CHECK (true);


-- -----------------------------------------------------------------------------
-- Platform reference tables
-- -----------------------------------------------------------------------------
-- No tenant data. RLS is enabled with a read-for-all policy; FORCE is
-- deliberately NOT set so that repeatable seed migrations can maintain them.
-- Write access is withheld from the application by GRANT, not by policy.
DO $$
DECLARE
  t text;
  reference_tables text[] := ARRAY[
    'skills',
    'channels',
    'agent_definitions',
    'event_schemas'
  ];
BEGIN
  FOREACH t IN ARRAY reference_tables
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR SELECT TO %I, %I USING (true)',
      t || '_read_all', t, 'syntra_app', 'syntra_relay'
    );
    EXECUTE format(
      'REVOKE INSERT, UPDATE, DELETE ON %I FROM %I, %I',
      t, 'syntra_app', 'syntra_relay'
    );
  END LOOP;
END
$$;


-- -----------------------------------------------------------------------------
-- skill_aliases — platform rows plus per-tenant additions
-- -----------------------------------------------------------------------------
-- organization_id IS NULL is a platform-wide alias; a non-NULL value scopes the
-- alias to one tenant. Recruiters and the normalize_skills tool may add and
-- curate their own org's aliases, but not touch the platform set. Same
-- read/write predicate split as matching_policies, for the same reason.
ALTER TABLE skill_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE skill_aliases FORCE  ROW LEVEL SECURITY;

CREATE POLICY skill_aliases_read ON skill_aliases
  FOR SELECT TO syntra_app
  USING (organization_id IS NULL OR organization_id = app.current_org_id());

CREATE POLICY skill_aliases_insert ON skill_aliases
  FOR INSERT TO syntra_app
  WITH CHECK (organization_id = app.current_org_id());

CREATE POLICY skill_aliases_update ON skill_aliases
  FOR UPDATE TO syntra_app
  USING (organization_id = app.current_org_id())
  WITH CHECK (organization_id = app.current_org_id());

CREATE POLICY skill_aliases_delete ON skill_aliases
  FOR DELETE TO syntra_app
  USING (organization_id = app.current_org_id());

CREATE POLICY skill_aliases_migrator ON skill_aliases
  FOR ALL TO syntra_migrator
  USING (true)
  WITH CHECK (true);