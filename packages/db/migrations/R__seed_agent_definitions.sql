-- R__seed_agent_definitions — the day-1 agent contracts (design doc §5)
-- =============================================================================
-- WHY THIS FILE EXISTS: agent_runs.agent_definition_id is NOT NULL, and V10
-- revokes INSERT on agent_definitions from syntra_app because it is platform
-- reference data. Those two facts together mean an unseeded agent_definitions
-- table makes the application unable to start any run at all — the schema would
-- apply cleanly and then nothing would work. So the definitions are seeded here
-- rather than left to application bootstrap.
--
-- WHAT LIVES HERE VS. IN CODE: this table holds the *contract* — which tools an
-- agent may call, what autonomy it has per action class, which model and budget.
-- The graph and the prompt text live in packages/agents; system_prompt_ref
-- points at the versioned prompt artifact. That split is what lets an operator
-- tighten autonomy or swap a model without a deploy, while keeping prompt
-- changes in code review.
--
-- VERSIONING: `version` is semver and (name, version) is unique, with a partial
-- unique index allowing exactly one is_active row per name. Changing an agent's
-- tool list or autonomy means seeding a new version row and flipping is_active
-- in the same transaction — never editing a row that agent_runs already point
-- at, for the same reproducibility reason as matching_policies.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Autonomy defaults
-- -----------------------------------------------------------------------------
-- Keyed by the tool side-effect classes from §5.5, valued SUGGEST | APPROVE |
-- AUTO (§5, "Suggest → Approve → Auto with audit").
--
--   READ            AUTO      Retrieval and scoring have no external effect.
--   INTERNAL_WRITE  AUTO      Parsed profiles, embeddings, match results. All
--                             versioned and all reversible from audit_logs.
--   DATA_SHAPING    AUTO      Only reached for identity-based EXACT merges,
--                             which §4.3 step 6 makes automatic. Probable
--                             duplicates never arrive here — the dedup tool
--                             returns REVIEW_REQUIRED and routes through
--                             request_approval, so §12 criterion 3 ("never
--                             merged silently") holds regardless of this value.
--   CONTROL         AUTO      Creating an approval item and pausing is itself
--                             the safe action; gating it would deadlock.
--   EXTERNAL_COMM   SUGGEST   §5.5 marks draft_communication "External (draft
--                             only day 1)". Nothing leaves the system without a
--                             recruiter pressing send.
--
-- An organisation tightens these through organizations.settings and a recruiter
-- through users.preferences (§8.7 trust ramp); this row is the floor they start
-- from, not the final word.

INSERT INTO agent_definitions (
  id, name, version, purpose, system_prompt_ref,
  allowed_tools, autonomy, model_config, is_active
) VALUES

-- ---------------------------------------------------------------------------
-- 1. matching-agent — the runtime's first tenant (§4.3)
-- ---------------------------------------------------------------------------
('01900000-0000-7000-8000-000000000501',
 'matching-agent',
 '1.0.0',
 'Turn a requirement into a ranked, deduplicated, evidence-explained shortlist of bench consultants.',
 'prompts/matching-agent@1.0.0',
 '[
    { "name": "extract_document_text",       "min_version": "1.0.0" },
    { "name": "parse_jd",                    "min_version": "1.0.0" },
    { "name": "normalize_skills",            "min_version": "1.0.0" },
    { "name": "generate_embedding",          "min_version": "1.0.0" },
    { "name": "upsert_embedding",            "min_version": "1.0.0" },
    { "name": "search_bench_hybrid",         "min_version": "1.0.0" },
    { "name": "deduplicate_candidates",      "min_version": "1.0.0" },
    { "name": "calculate_match_score",       "min_version": "1.0.0" },
    { "name": "generate_match_explanation",  "min_version": "1.0.0" },
    { "name": "persist_match_results",       "min_version": "1.0.0" },
    { "name": "record_activity",             "min_version": "1.0.0" },
    { "name": "request_approval",            "min_version": "1.0.0" }
  ]'::jsonb,
 '{
    "READ":           "AUTO",
    "INTERNAL_WRITE": "AUTO",
    "DATA_SHAPING":   "AUTO",
    "CONTROL":        "AUTO",
    "EXTERNAL_COMM":  "SUGGEST"
  }'::jsonb,
 -- temperature 0 on the reasoning model: §10 promises reproducible results, and
 -- the explanation text is part of what a recruiter is asked to trust.
 -- embedding.model must match both matching_policies.embedding_model and the
 -- HNSW partial index predicate in V8.
 '{
    "provider":              "anthropic",
    "model":                 "claude-sonnet-5",
    "temperature":           0,
    "max_output_tokens":     8192,
    "embedding": { "provider": "voyage", "model": "voyage-3-large", "dims": 1024 },
    "cost_budget_usd_per_run": 0.50,
    "timeout_ms":            300000
  }'::jsonb,
 true),

-- ---------------------------------------------------------------------------
-- 2. intake-agent — resolves raw arrivals into entities (§6.8, §4.3 step 6)
-- ---------------------------------------------------------------------------
-- Reads an ingestion_events row and decides what it is: a requirement, a resume,
-- a candidate update, or something a human should look at. It never scores —
-- it emits syntra.jd.received and lets the matching agent take over.
('01900000-0000-7000-8000-000000000502',
 'intake-agent',
 '1.0.0',
 'Interpret a raw channel arrival into a requirement, a candidate profile, or a review item.',
 'prompts/intake-agent@1.0.0',
 '[
    { "name": "extract_document_text",  "min_version": "1.0.0" },
    { "name": "parse_jd",               "min_version": "1.0.0" },
    { "name": "parse_resume",           "min_version": "1.0.0" },
    { "name": "normalize_skills",       "min_version": "1.0.0" },
    { "name": "generate_embedding",     "min_version": "1.0.0" },
    { "name": "upsert_embedding",       "min_version": "1.0.0" },
    { "name": "deduplicate_candidates", "min_version": "1.0.0" },
    { "name": "record_activity",        "min_version": "1.0.0" },
    { "name": "request_approval",       "min_version": "1.0.0" }
  ]'::jsonb,
 '{
    "READ":           "AUTO",
    "INTERNAL_WRITE": "AUTO",
    "DATA_SHAPING":   "AUTO",
    "CONTROL":        "AUTO",
    "EXTERNAL_COMM":  "SUGGEST"
  }'::jsonb,
 '{
    "provider":              "anthropic",
    "model":                 "claude-sonnet-5",
    "temperature":           0,
    "max_output_tokens":     8192,
    "embedding": { "provider": "voyage", "model": "voyage-3-large", "dims": 1024 },
    "cost_budget_usd_per_run": 0.25,
    "timeout_ms":            300000
  }'::jsonb,
 true),

-- ---------------------------------------------------------------------------
-- 3. copilot — the recruiter's conversational surface (§9)
-- ---------------------------------------------------------------------------
-- §9: "Nothing is possible in chat that is not possible (and audited) in the
-- runtime." That is why the copilot is an agent_definitions row with an explicit
-- tool list and its own autonomy policy, rather than a chat endpoint with
-- ambient database access. Its runs land in agent_runs like any other.
--
-- Note it holds no persist_match_results: "re-run matching without the rate
-- filter" starts a matching-agent run rather than writing results itself.
('01900000-0000-7000-8000-000000000503',
 'copilot',
 '1.0.0',
 'Answer recruiter questions over their own bench and pipeline, and take policy-bounded actions on request.',
 'prompts/copilot@1.0.0',
 '[
    { "name": "search_bench_hybrid",        "min_version": "1.0.0" },
    { "name": "calculate_match_score",      "min_version": "1.0.0" },
    { "name": "generate_match_explanation", "min_version": "1.0.0" },
    { "name": "draft_communication",        "min_version": "1.0.0" },
    { "name": "record_activity",            "min_version": "1.0.0" },
    { "name": "request_approval",           "min_version": "1.0.0" }
  ]'::jsonb,
 -- Stricter than the autonomous agents on data shaping: a merge asked for in
 -- conversation is far more likely to be a misunderstanding than one derived
 -- from the identity graph, so it goes through an approval card.
 '{
    "READ":           "AUTO",
    "INTERNAL_WRITE": "AUTO",
    "DATA_SHAPING":   "APPROVE",
    "CONTROL":        "AUTO",
    "EXTERNAL_COMM":  "SUGGEST"
  }'::jsonb,
 -- Interactive, so a tighter timeout and a smaller budget than a batch run.
 '{
    "provider":              "anthropic",
    "model":                 "claude-sonnet-5",
    "temperature":           0,
    "max_output_tokens":     4096,
    "embedding": { "provider": "voyage", "model": "voyage-3-large", "dims": 1024 },
    "cost_budget_usd_per_run": 0.10,
    "timeout_ms":            60000
  }'::jsonb,
 true)

-- Conflict on (name, version), never on id: agent_runs and agent_steps point at
-- these ids, so a re-run must not renumber them.
--
-- purpose and system_prompt_ref are refreshed; allowed_tools, autonomy and
-- model_config are NOT. Those three are the contract a completed run was
-- executed under, and agent_runs rows reference this row to explain what the
-- agent was permitted to do at the time. Widening a tool list in place would
-- rewrite that history. Change them by seeding a new version.
ON CONFLICT (name, version) DO UPDATE
  SET purpose           = EXCLUDED.purpose,
      system_prompt_ref = EXCLUDED.system_prompt_ref
  WHERE agent_definitions.purpose           IS DISTINCT FROM EXCLUDED.purpose
     OR agent_definitions.system_prompt_ref IS DISTINCT FROM EXCLUDED.system_prompt_ref;


-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  offenders text;
BEGIN
  -- 1. An edit to allowed_tools / autonomy / model_config that the ON CONFLICT
  --    clause above deliberately swallowed. Same immutability contract as
  --    event_schemas and matching_policies: fail loudly rather than diverge.
  SELECT string_agg(d.name || '@' || d.version, ', ' ORDER BY d.name)
    INTO offenders
  FROM agent_definitions d
  JOIN (VALUES
    ('matching-agent', 12, 'AUTO'),
    ('intake-agent',    9, 'AUTO'),
    ('copilot',         6, 'APPROVE')
  ) AS expected (name, tool_count, data_shaping)
    ON expected.name = d.name
  WHERE d.version = '1.0.0'
    AND (jsonb_array_length(d.allowed_tools) <> expected.tool_count
         OR d.autonomy ->> 'DATA_SHAPING' <> expected.data_shaping
         OR d.model_config ->> 'model' IS NULL);

  IF offenders IS NOT NULL THEN
    RAISE EXCEPTION
      'The registered contract for % differs from this file. allowed_tools, '
      'autonomy and model_config are immutable per version — agent_runs '
      'reference this row to record what the agent was permitted to do. Seed a '
      'new version row and flip is_active instead of editing 1.0.0.',
      offenders;
  END IF;

  -- 2. Every agent must be able to reach the approval path. An agent with any
  --    non-AUTO action class but no request_approval tool cannot pause for a
  --    human — it can only fail, and the §5 autonomy model quietly stops
  --    working for it.
  SELECT string_agg(d.name, ', ' ORDER BY d.name) INTO offenders
  FROM agent_definitions d
  WHERE d.is_active
    AND EXISTS (
      SELECT 1 FROM jsonb_each_text(d.autonomy) a WHERE a.value <> 'AUTO'
    )
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(d.allowed_tools) t
      WHERE t ->> 'name' = 'request_approval'
    );

  IF offenders IS NOT NULL THEN
    RAISE EXCEPTION
      'Agents % have a non-AUTO autonomy class but no request_approval tool, so '
      'they cannot pause for a human decision.', offenders;
  END IF;

  RAISE NOTICE 'Agent definitions: % active.',
    (SELECT count(*) FROM agent_definitions WHERE is_active);
END
$$;

-- =============================================================================