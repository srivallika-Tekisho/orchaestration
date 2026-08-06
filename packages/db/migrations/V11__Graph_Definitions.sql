CREATE TABLE graph_definitions (
  id          text PRIMARY KEY,                    -- ULID
  org_id      text,            -- NULL = global default
  graph_key   text NOT NULL,                       -- e.g. 'resume.intake'
  version     int  NOT NULL,
  definition  jsonb NOT NULL,
  checksum    text NOT NULL,                       -- sha256 of canonicalized JSON
  status      text NOT NULL DEFAULT 'draft'
              CHECK (status IN ('draft','active','retired')),
  created_by  text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz
);

CREATE UNIQUE INDEX graph_definitions_unique_version
  ON graph_definitions (graph_key, COALESCE(org_id,'~global~'), version);

-- Invariant: at most one active version per (graph_key, scope)
CREATE UNIQUE INDEX graph_definitions_one_active
  ON graph_definitions (graph_key, COALESCE(org_id,'~global~'))
  WHERE status = 'active';


