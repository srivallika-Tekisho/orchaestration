-- STEP 18: Verification queries

-- Expected extensions. vector must be 0.8.0 or newer for this design.
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'citext', 'pg_trgm')
ORDER BY extname;

-- Expected public tables from V2-V9: 29 total in the lead's migration set.
SELECT count(*) AS public_table_count
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r';

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;

-- Seed counts.
SELECT 'agent_definitions' AS object, count(*) AS rows FROM agent_definitions
UNION ALL SELECT 'channels', count(*) FROM channels
UNION ALL SELECT 'event_schemas', count(*) FROM event_schemas
UNION ALL SELECT 'matching_policies', count(*) FROM matching_policies
UNION ALL SELECT 'skills', count(*) FROM skills
UNION ALL SELECT 'skill_aliases', count(*) FROM skill_aliases;

-- RLS/force/policy overview.
SELECT c.relname AS table_name,
       c.relrowsecurity AS rls_enabled,
       c.relforcerowsecurity AS rls_forced,
       count(p.oid) AS policy_count
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_policy p ON p.polrelid = c.oid
WHERE n.nspname = 'public' AND c.relkind = 'r'
GROUP BY c.relname, c.relrowsecurity, c.relforcerowsecurity
ORDER BY c.relname;

-- Runtime bootstrap status. These counts may be zero before Node bootstrap.
SELECT n.nspname AS schema_name, count(c.oid) AS table_count
FROM pg_namespace n
LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relkind = 'r'
WHERE n.nspname IN ('pgboss', 'langgraph')
GROUP BY n.nspname
ORDER BY n.nspname;