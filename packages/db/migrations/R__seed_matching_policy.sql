-- R__seed_matching_policy — the platform default scoring policy (design doc §7.3)
-- =============================================================================
-- organization_id IS NULL marks the platform default that every tenant reads
-- through the matching_policies_read RLS policy. A tenant that wants different
-- weights inserts its own row under its own organization_id; it can neither
-- update nor delete this one (V10 splits the read and write predicates
-- specifically so that it cannot).
--
-- WHY DO NOTHING AND NOT DO UPDATE: §7.3 — "weights can be tuned per
-- organization — through a new policy version, never a silent change". Every
-- match_results row records the policy it was scored under in its `versions`
-- object; mutating version 1 in place would make that record a lie and break
-- the §10 reproducibility guarantee for every historical result. Tuning the
-- platform default means seeding version 2 and deactivating version 1, which is
-- a new file, not an edit to this one.
--
-- The assertion below turns an edit to the weights in this file from a silent
-- no-op into a failed migration that says so.
--
-- NOTE ON ORDERING: this file runs before R__seed_skills (Flyway orders
-- repeatables alphabetically by description) but has no dependency on it.
-- =============================================================================

INSERT INTO matching_policies (
  id, organization_id, version, weights, thresholds, embedding_model, is_active
) VALUES (
  '01900000-0000-7000-8000-000000000401',
  NULL,     -- platform default
  1,

  -- §7.3 initial weights, in the doc's own order. Sum to exactly 1.00 —
  -- asserted below, because a fat-fingered weight here silently rescales every
  -- score in the product and nothing else would catch it.
  '{
     "mandatory_skills": 0.30,
     "semantic":         0.20,
     "experience":       0.15,
     "optional_skills":  0.10,
     "domain":           0.10,
     "location":         0.05,
     "work_auth":        0.05,
     "rate":             0.05
   }'::jsonb,

  -- min_total     — below this a candidate is not shown at all.
  -- auto_shortlist— above this the UI pre-selects; it is NOT an auto-submit.
  --                 Submission is always a recruiter action on day 1.
  '{
     "min_total":      0.45,
     "auto_shortlist": 0.80
   }'::jsonb,

  -- The embedding model the 0.20 semantic weight was calibrated against. Kept
  -- on the policy rather than in config because a model change invalidates the
  -- calibration, and this column is what makes that dependency visible: the
  -- migration that flips the active model also seeds a new policy version.
  -- Must match the model in the embeddings HNSW partial index predicate (V8).
  'voyage-3-large',

  true
)
ON CONFLICT ON CONSTRAINT matching_policies_org_version_key DO NOTHING;


-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  seeded       matching_policies;
  weight_total numeric;
BEGIN
  SELECT * INTO seeded
  FROM matching_policies
  WHERE organization_id IS NULL AND version = 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Platform default matching policy was not seeded.';
  END IF;

  -- 1. Weights must sum to 1.00. jsonb_each_text over the stored row rather
  --    than the literal above, so this also catches a hand-edited production
  --    row. (There is no table-level CHECK for this: tenant policies are
  --    inserted by the application, which validates with the same rule. If
  --    that ever proves insufficient, the constraint is an additive migration.)
  SELECT sum(value::numeric) INTO weight_total
  FROM jsonb_each_text(seeded.weights);

  IF weight_total <> 1.00 THEN
    RAISE EXCEPTION
      'Platform matching policy weights sum to %, not 1.00. Every match score '
      'would be silently rescaled. Weights: %', weight_total, seeded.weights;
  END IF;

  -- 2. An edit to this file that ON CONFLICT DO NOTHING swallowed.
  IF seeded.embedding_model <> 'voyage-3-large'
     OR seeded.thresholds <> '{"min_total": 0.45, "auto_shortlist": 0.80}'::jsonb
     OR seeded.weights <> '{"mandatory_skills": 0.30, "semantic": 0.20,
                            "experience": 0.15, "optional_skills": 0.10,
                            "domain": 0.10, "location": 0.05,
                            "work_auth": 0.05, "rate": 0.05}'::jsonb THEN
    RAISE EXCEPTION
      'The registered platform policy v1 differs from this file '
      '(registered: weights %, thresholds %, model %). Policy versions are '
      'immutable — match_results reference them for reproducibility. Seed a '
      'version 2 row instead of editing version 1.',
      seeded.weights, seeded.thresholds, seeded.embedding_model;
  END IF;

  RAISE NOTICE 'Platform default matching policy v1 present (model %).',
    seeded.embedding_model;
END
$$;

-- =============================================================================