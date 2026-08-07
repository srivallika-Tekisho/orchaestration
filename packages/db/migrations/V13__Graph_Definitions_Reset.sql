-- V13__Graph_Definitions_Reset.sql
-- Clean reset of graph_definitions to align with project conventions and design doc invariants

DROP TABLE IF EXISTS graph_definitions CASCADE;

-- Minimal privilege to allow migrator to construct the FK and RLS policies
GRANT USAGE ON SCHEMA app TO syntra_migrator;
GRANT REFERENCES ON organizations TO syntra_migrator;

CREATE TABLE graph_definitions (
  id          text PRIMARY KEY,
  org_id      uuid REFERENCES organizations(id),
  graph_key   text NOT NULL,
  version     int  NOT NULL,
  definition  jsonb NOT NULL,
  checksum    text NOT NULL,
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','retired')),
  created_by  text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz
);

-- NULLS NOT DISTINCT elegantly replaces the COALESCE hack for uuid
CREATE UNIQUE INDEX graph_definitions_unique_version
  ON graph_definitions (graph_key, org_id, version) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX graph_definitions_one_active
  ON graph_definitions (graph_key, org_id) NULLS NOT DISTINCT
  WHERE status = 'active';

-- Enable and Force RLS
ALTER TABLE graph_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE graph_definitions FORCE ROW LEVEL SECURITY;

-- Read policy: Global definitions (org_id IS NULL) or tenant's own
CREATE POLICY graph_definitions_read ON graph_definitions
  FOR SELECT TO syntra_app
  USING (org_id IS NULL OR org_id = app.current_org_id());

-- Write policies: Strictly restricted to the tenant's own org
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

-- Migrator requires full access (e.g., for seed migrations)
CREATE POLICY graph_definitions_migrator ON graph_definitions
  FOR ALL TO syntra_migrator
  USING (true)
  WITH CHECK (true);
