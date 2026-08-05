-- V5 — Skills taxonomy (design doc §6.5)
-- =============================================================================
-- Deterministic taxonomy matching against these tables produces the
-- mandatory-skill-coverage signal, which carries the largest single weight in
-- the §7.3 scoring model (30%).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- skills — the canonical skill vocabulary
-- -----------------------------------------------------------------------------
-- Platform reference data. Read by every tenant, written by migrations and
-- admin tooling only.
CREATE TABLE skills (
  id             uuid PRIMARY KEY,
  canonical_name text NOT NULL,
  category       text,      -- 'LANGUAGE', 'FRAMEWORK', 'CLOUD', 'DOMAIN', ...
  metadata       jsonb NOT NULL DEFAULT '{}',
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT skills_canonical_name_key UNIQUE (canonical_name)
);

CREATE INDEX skills_category_idx ON skills (category);

CREATE TRIGGER skills_set_updated_at
  BEFORE UPDATE ON skills
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- skill_aliases — surface forms mapping to canonical skills
-- -----------------------------------------------------------------------------
-- 'reactjs', 'react.js', 'react js' -> React. Alias lookup runs first in the
-- normalize_skills tool; the LLM is invoked only on a miss, and LLM-proposed
-- aliases land with source='LLM' for periodic recruiter review (§6.5).
--
-- Design doc §6.5 makes `alias` the global PRIMARY KEY while its own comment
-- says "Global seed + org-level additions land here". Those contradict: one
-- org adding 'ml' -> their skill would block every other org from ever adding
-- that alias. organization_id NULL means a platform-wide alias; a non-NULL
-- value scopes it to one tenant.
CREATE TABLE skill_aliases (
  id              uuid PRIMARY KEY,
  organization_id uuid REFERENCES organizations (id),  -- NULL = platform-wide
  alias           citext NOT NULL,
  skill_id        uuid NOT NULL REFERENCES skills (id),
  source          text NOT NULL DEFAULT 'SEED'
                    CHECK (source IN ('SEED', 'LLM', 'RECRUITER')),
  -- LLM-proposed aliases stay unreviewed until a recruiter confirms them.
  reviewed_at     timestamptz,
  reviewed_by     uuid REFERENCES users (id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  -- NULLS NOT DISTINCT (PG15+) so at most one platform-wide row per alias.
  CONSTRAINT skill_aliases_org_alias_key
    UNIQUE NULLS NOT DISTINCT (organization_id, alias)
);

-- normalize_skills resolves an alias to a skill on the hot path: platform rows
-- and the caller's own org rows, nothing else.
CREATE INDEX skill_aliases_lookup_idx ON skill_aliases (alias, organization_id);

CREATE INDEX skill_aliases_skill_idx ON skill_aliases (skill_id);

-- Recruiter review queue for LLM-proposed aliases.
CREATE INDEX skill_aliases_unreviewed_idx
  ON skill_aliases (organization_id, created_at DESC)
  WHERE source = 'LLM' AND reviewed_at IS NULL;

CREATE TRIGGER skill_aliases_set_updated_at
  BEFORE UPDATE ON skill_aliases
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

-- =============================================================================