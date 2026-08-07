-- Fix the unique indexes so org_id can become uuid (COALESCE can't mix
-- uuid and text; NULLS NOT DISTINCT replaces that pattern natively)
-- syntra_migrator needs REFERENCES on organizations to create the FK below.
-- Minimal privilege — does not grant SELECT/INSERT/UPDATE/DELETE.
GRANT REFERENCES ON organizations TO syntra_migrator;

ALTER TABLE graph_definitions
  ADD CONSTRAINT graph_definitions_org_id_fkey
  FOREIGN KEY (org_id) REFERENCES organizations(id);

DROP INDEX graph_definitions_unique_version;
DROP INDEX graph_definitions_one_active;

-- Fix org_id type to match organizations(id)
ALTER TABLE graph_definitions
  ALTER COLUMN org_id TYPE uuid USING org_id::uuid;

-- Recreate the indexes on the now-uuid column
CREATE UNIQUE INDEX graph_definitions_unique_version
  ON graph_definitions (graph_key, org_id, version) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX graph_definitions_one_active
  ON graph_definitions (graph_key, org_id) NULLS NOT DISTINCT
  WHERE status = 'active';

-- Add foreign key constraint
ALTER TABLE graph_definitions
  ADD CONSTRAINT graph_definitions_org_id_fkey
  FOREIGN KEY (org_id) REFERENCES organizations(id);

-- Enable RLS and Force RLS
ALTER TABLE graph_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE graph_definitions FORCE ROW LEVEL SECURITY;

-- Add RLS policies (modeled after matching_policies / skill_aliases)
-- Users can read global definitions (org_id IS NULL) or their own
CREATE POLICY graph_definitions_read ON graph_definitions
  FOR SELECT TO syntra_app
  USING (org_id IS NULL OR org_id = app.current_org_id());

-- Users can only insert/update/delete their own org's definitions
CREATE POLICY graph_definitions_insert ON graph_definitions
  FOR INSERT TO syntra_app
  WITH CHECK (org_id = app.current_org_id());

CREATE POLICY graph_definitions_update ON graph_definitions
  FOR UPDATE TO syntra_app
  USING (org_id = app.current_org_id())
  WITH CHECK (org_id = app.current_org_id());

CREATE POLICY graph_definitions_delete ON graph_definitions
  FOR DELETE TO syntra_app
  USING (org_id = app.current_org_id());

-- Migrator needs full access
CREATE POLICY graph_definitions_migrator ON graph_definitions
  FOR ALL TO syntra_migrator
  USING (true)
  WITH CHECK (true);