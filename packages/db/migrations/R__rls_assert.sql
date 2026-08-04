-- R__rls_assert — fail the migration if any table is unprotected
-- =============================================================================
-- Flyway cannot retro-apply ROW LEVEL SECURITY. Nothing stops someone adding a
-- table in V14 and forgetting to write its policy, at which point that table is
-- readable across every tenant and the §12 isolation tests still pass because
-- they only cover the tables they know about. This is the backstop.
--
-- Three assertions over every table in `public` except Flyway's own schema
-- history table (see step 0 for why that one is excluded):
--   1. RLS is enabled.
--   2. At least one policy exists (RLS with no policy denies everything, which
--      is safe but is almost always an oversight rather than intent).
--   3. FORCE is set — except for the platform reference tables, which hold no
--      tenant data and must stay writable by migrations for seeding.
--
-- CAVEAT ON RE-RUNS: Flyway only re-applies a repeatable migration when its
-- checksum changes, so adding a new versioned migration does NOT re-trigger
-- this file. CI must therefore run it directly after `flyway migrate`:
--
--     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/R__rls_assert.sql
--
-- The script is read-only and idempotent, so running it standalone is safe.
-- =============================================================================

DO $$
DECLARE
  -- Platform reference data: no organization_id, no tenant rows, seeded by
  -- repeatable migrations running as the table owner. Kept in sync with the
  -- reference_tables list in V10.
  force_exempt text[] := ARRAY[
    'skills',
    'channels',
    'agent_definitions',
    'event_schemas'
  ];
  not_ours oid[];
  offenders text;
BEGIN
  -- 0. Exclude Flyway's own schema history table.
  --
  --    It lives in `public` but is created and owned by Flyway itself, outside
  --    any migration, so no migration can policy it. It holds the deploy log,
  --    not tenant data. Without this exclusion the assertion fails on the very
  --    first `flyway migrate` against an empty database — which is exactly how
  --    this was caught.
  --
  --    Matched on column signature rather than on name: `flyway.table` is
  --    configurable, and a deployment that renamed it would otherwise trip an
  --    error pointing nowhere near the cause. The signature is specific enough
  --    that no business table will collide with it by accident.
  SELECT coalesce(array_agg(c.oid), '{}')
    INTO not_ours
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND (SELECT count(*) FROM pg_attribute a
          WHERE a.attrelid = c.oid
            AND NOT a.attisdropped
            AND a.attname IN ('installed_rank', 'version', 'description', 'type',
                              'script', 'checksum', 'installed_by', 'installed_on',
                              'execution_time', 'success')) = 10;

  -- 1. RLS enabled everywhere.
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO offenders
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.oid <> ALL (not_ours)
    AND NOT c.relrowsecurity;

  IF offenders IS NOT NULL THEN
    RAISE EXCEPTION
      'RLS is not enabled on: %. Every table in public must ENABLE ROW LEVEL SECURITY.',
      offenders;
  END IF;

  -- 2. At least one policy per table.
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO offenders
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.oid <> ALL (not_ours)
    AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid);

  IF offenders IS NOT NULL THEN
    RAISE EXCEPTION
      'RLS is enabled but no policy is defined on: %. That denies all access; define policies explicitly.',
      offenders;
  END IF;

  -- 3. FORCE set on every tenant table. Without it the table owner bypasses
  --    all policies, and a misconfigured application connecting as the owner
  --    sees every tenant's rows.
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO offenders
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.oid <> ALL (not_ours)
    AND NOT c.relforcerowsecurity
    AND c.relname <> ALL (force_exempt);

  IF offenders IS NOT NULL THEN
    RAISE EXCEPTION
      'FORCE ROW LEVEL SECURITY is not set on: %. Add it, or add the table to the documented reference-data exemption list.',
      offenders;
  END IF;

  RAISE NOTICE 'RLS assertions passed for all tables in schema public.';
END
$$;



-- ==========================================================================