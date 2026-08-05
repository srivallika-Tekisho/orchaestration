-- V6 — Candidate domain (design doc §6.6)
-- =============================================================================
-- The bench. One of the two day-1 centres of gravity, and the driving table of
-- the hybrid retrieval query in §7.1.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- candidates — one row per canonical consultant
-- -----------------------------------------------------------------------------
CREATE TABLE candidates (
  id                 uuid PRIMARY KEY,
  organization_id    uuid NOT NULL REFERENCES organizations (id),
  full_name          text NOT NULL,
  primary_email      citext,
  primary_phone      text,
  location_city      text,
  location_state     text,
  location_country   text,
  work_authorization text CHECK (work_authorization IN (
                       'USC', 'GC', 'GC_EAD', 'H1B', 'H4_EAD', 'OPT', 'CPT', 'TN', 'OTHER')),
  relocation         text CHECK (relocation IN ('YES', 'NO', 'REMOTE_ONLY', 'HYBRID_OK')),
  availability       text NOT NULL DEFAULT 'AVAILABLE' CHECK (availability IN (
                       'AVAILABLE', 'AVAILABLE_SOON', 'ENGAGED', 'PLACED', 'INACTIVE')),
  available_from     date,
  bench_since        date,
  experience_years   numeric(4,1) CHECK (experience_years >= 0),
  title_headline     text,                    -- "Senior Java Developer"

  -- {"type":"C2C","expected":85,"min":75,"currency":"USD","unit":"HOUR"}
  rate               jsonb NOT NULL DEFAULT '{}',

  -- The §7.1 retrieval query filters on `(c.rate->>'min')::numeric <= $6`.
  -- That expression is NULL for every candidate whose rate is '{}' — the
  -- column default — and `NULL <= x` is NULL, so those candidates are silently
  -- excluded from every match. Extracting to a real column lets the query use
  -- an IS NULL-tolerant predicate and an index:
  --   AND (c.rate_min IS NULL OR c.rate_min <= $6)
  -- A non-numeric rate->>'min' now fails loudly at INSERT rather than
  -- corrupting retrieval silently.
  rate_min           numeric GENERATED ALWAYS AS
                       (NULLIF(rate ->> 'min', '')::numeric) STORED,

  employment_model   text CHECK (employment_model IN ('W2', 'C2C', '1099', 'ANY')),
  marketing_status   text NOT NULL DEFAULT 'ACTIVE'
                       CHECK (marketing_status IN ('ACTIVE', 'PAUSED', 'DO_NOT_MARKET')),
  owner_user_id      uuid,                    -- owning recruiter
  merged_into_id     uuid,                    -- non-NULL => not canonical

  -- Denormalised text of the current resume, written by the profile-preparation
  -- tool. The design doc puts search_tsv on candidates but the resume body
  -- lives in candidate_profiles.parsed, which would reduce the fts_rank signal
  -- in §7.1 to name + title. Keeping the text here lets the full-text half of
  -- hybrid retrieval actually contribute.
  resume_text        text,

  -- GENERATED rather than the doc's trigger. to_tsvector with a *literal*
  -- regconfig is IMMUTABLE and therefore legal here; the one-argument form is
  -- only STABLE and would be rejected.
  -- Note: changing this expression later requires DROP/ADD column plus a full
  -- table rewrite.
  search_tsv         tsvector GENERATED ALWAYS AS (
                       setweight(to_tsvector('english', coalesce(full_name, '')),      'A') ||
                       setweight(to_tsvector('english', coalesce(title_headline, '')), 'B') ||
                       setweight(to_tsvector('english', coalesce(resume_text, '')),    'C')
                     ) STORED,

  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,

  CONSTRAINT candidates_org_id_key UNIQUE (organization_id, id),
  CONSTRAINT candidates_not_self_merged CHECK (merged_into_id IS NULL OR merged_into_id <> id),
  FOREIGN KEY (organization_id, owner_user_id)  REFERENCES users (organization_id, id),
  FOREIGN KEY (organization_id, merged_into_id) REFERENCES candidates (organization_id, id)
);

-- Primary retrieval filter (§7.1) and the Bench Board availability lanes.
CREATE INDEX candidates_bench_idx
  ON candidates (organization_id, availability, marketing_status)
  WHERE merged_into_id IS NULL AND deleted_at IS NULL;

-- Bench Board aging-on-bench sort.
CREATE INDEX candidates_bench_aging_idx
  ON candidates (organization_id, bench_since)
  WHERE merged_into_id IS NULL AND deleted_at IS NULL;

-- "My bench" filter.
CREATE INDEX candidates_owner_idx
  ON candidates (organization_id, owner_user_id)
  WHERE merged_into_id IS NULL AND deleted_at IS NULL;

-- Rate-band compatibility filter (§7.1).
CREATE INDEX candidates_rate_min_idx
  ON candidates (organization_id, rate_min)
  WHERE merged_into_id IS NULL AND deleted_at IS NULL;

-- Full-text half of hybrid retrieval.
CREATE INDEX candidates_fts_idx ON candidates USING gin (search_tsv);

-- Trigram name similarity for probable-duplicate detection (§7.2).
CREATE INDEX candidates_name_trgm_idx ON candidates USING gin (full_name gin_trgm_ops);

-- Follow a merge chain back to the canonical row.
CREATE INDEX candidates_merged_into_idx
  ON candidates (merged_into_id) WHERE merged_into_id IS NOT NULL;

CREATE TRIGGER candidates_set_updated_at
  BEFORE UPDATE ON candidates
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- candidate_identities — the dedup identity graph
-- -----------------------------------------------------------------------------
-- Each row is one strong identifier. A shared value within an org is what
-- drives §7.2's automatic exact merge.
--
-- Design doc §6.6 declares UNIQUE (identity_type, identity_value) — GLOBAL,
-- across tenants, described as "global uniqueness drives exact-dedup". In a
-- multi-tenant system that is a functional break, not just a leak: the same
-- consultant is legitimately marketed by several bench sales firms, and
-- RESUME_SHA256 collides whenever one PDF reaches two orgs. Under the doc's
-- constraint the second org simply cannot bench that consultant, and the
-- constraint violation reveals that another tenant holds the identifier.
--
-- Scoping per-org does not weaken §7.2: dedup is inherently intra-org
-- (merged_into_id targets same-org rows, match results are org-scoped), so the
-- "a person appears at most once per ranking" guarantee is unaffected.
CREATE TABLE candidate_identities (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  candidate_id    uuid NOT NULL,
  identity_type   text NOT NULL CHECK (identity_type IN (
                    'EMAIL', 'PHONE', 'LINKEDIN', 'DICE', 'MONSTER',
                    'ATS_ID', 'RESUME_SHA256')),
  -- Normalised before insert: lowercased email, E.164 phone, cleaned URL.
  identity_value  text NOT NULL,
  source          text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT candidate_identities_org_type_value_key
    UNIQUE (organization_id, identity_type, identity_value),
  FOREIGN KEY (organization_id, candidate_id) REFERENCES candidates (organization_id, id)
);

-- Candidate 360 lists a consultant's identities. The unique constraint above is
-- on the value pair, so without this the lookup is a sequential scan.
CREATE INDEX candidate_identities_candidate_idx
  ON candidate_identities (organization_id, candidate_id);


-- -----------------------------------------------------------------------------
-- candidate_profiles — the versioned parsed view of a resume
-- -----------------------------------------------------------------------------
-- Immutable per version, so re-parsing under a newer parser_version never
-- destroys the evidence an earlier match result cited.
CREATE TABLE candidate_profiles (
  id                 uuid PRIMARY KEY,
  organization_id    uuid NOT NULL REFERENCES organizations (id),
  candidate_id       uuid NOT NULL,
  source_document_id uuid NOT NULL,
  profile_version    int  NOT NULL CHECK (profile_version >= 1),
  parsed             jsonb NOT NULL,   -- experiences[], education[], summary, ...
  parser_version     text NOT NULL,
  is_current         boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT candidate_profiles_version_key UNIQUE (candidate_id, profile_version),
  FOREIGN KEY (organization_id, candidate_id)       REFERENCES candidates (organization_id, id),
  FOREIGN KEY (organization_id, source_document_id) REFERENCES documents  (organization_id, id)
);

-- Enforces the single-current-profile invariant and doubles as the lookup for
-- resume-freshness warnings on the Bench Board.
CREATE UNIQUE INDEX candidate_profiles_current_idx
  ON candidate_profiles (candidate_id) WHERE is_current;


-- -----------------------------------------------------------------------------
-- candidate_skills — resolved skills per consultant
-- -----------------------------------------------------------------------------
-- Joined against requirement_skills to compute coverage. `evidence` holds
-- pointers into candidate_profiles.parsed, which is what makes the
-- hover-to-highlight-resume-lines interaction in §8.3 possible and what the
-- explanation tool is required to cite.
CREATE TABLE candidate_skills (
  organization_id uuid NOT NULL REFERENCES organizations (id),
  candidate_id    uuid NOT NULL,
  skill_id        uuid NOT NULL REFERENCES skills (id),
  years           numeric(4,1) CHECK (years >= 0),
  last_used       date,
  evidence        jsonb NOT NULL DEFAULT '[]',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (candidate_id, skill_id),
  FOREIGN KEY (organization_id, candidate_id) REFERENCES candidates (organization_id, id)
);

-- Reverse lookup: "who on the bench has this skill", used when scoring a
-- retrieved candidate set against requirement_skills.
CREATE INDEX candidate_skills_skill_idx
  ON candidate_skills (organization_id, skill_id);

CREATE TRIGGER candidate_skills_set_updated_at
  BEFORE UPDATE ON candidate_skills
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- duplicate_reviews — probable duplicates awaiting a human
-- -----------------------------------------------------------------------------
-- Never auto-merged (§12 criterion 3). `signals` records why the system
-- suspects a duplicate: trigram name similarity, employer overlap, education
-- match, profile embedding similarity.
--
-- §4.3 step 7 says probable duplicates "get a REVIEW_REQUIRED approval item",
-- while §6.6 defines this separate table — as written the Approvals Queue
-- would have to UNION two sources. Resolved by linking the two: this table
-- holds the signals, approvals holds the decision, and there is one queue.
CREATE TABLE duplicate_reviews (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  candidate_a     uuid NOT NULL,
  candidate_b     uuid NOT NULL,
  signals         jsonb NOT NULL,
  approval_id     uuid,
  status          text NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING', 'MERGED', 'DISTINCT', 'EXPIRED')),
  decided_by      uuid,
  decided_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT duplicate_reviews_distinct_pair CHECK (candidate_a <> candidate_b),
  FOREIGN KEY (organization_id, candidate_a) REFERENCES candidates (organization_id, id),
  FOREIGN KEY (organization_id, candidate_b) REFERENCES candidates (organization_id, id),
  FOREIGN KEY (organization_id, approval_id) REFERENCES approvals  (organization_id, id),
  FOREIGN KEY (organization_id, decided_by)  REFERENCES users      (organization_id, id)
);

-- A re-run of the matching agent would otherwise raise a second review row for
-- the same pair. Unordered-pair uniqueness, so (A,B) and (B,A) collide.
CREATE UNIQUE INDEX duplicate_reviews_pair_idx
  ON duplicate_reviews (
    organization_id,
    least(candidate_a, candidate_b),
    greatest(candidate_a, candidate_b)
  );

CREATE INDEX duplicate_reviews_pending_idx
  ON duplicate_reviews (organization_id, created_at DESC)
  WHERE status = 'PENDING';

CREATE TRIGGER duplicate_reviews_set_updated_at
  BEFORE UPDATE ON duplicate_reviews
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- =============================================================================