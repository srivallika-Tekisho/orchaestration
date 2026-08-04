-- R__seed_channels — arrival-channel reference data (design doc §6.8)
-- =============================================================================
-- `channels` is a table rather than a CHECK constraint precisely so that turning
-- a channel on is a data change. This file owns the catalogue; operators own the
-- switch.
--
-- SEED IDs ARE LITERAL AND FIXED. IDs have no database default (V1 convention:
-- the application supplies UUIDv7), and channel_accounts.channel_id points here,
-- so a stable id per channel means fixtures, eval golden sets and prod/staging
-- diffs all line up. The 019000000000 timestamp prefix is deliberately synthetic
-- so seed rows are recognisable on sight.
--
-- IDEMPOTENCY: conflict is resolved on channel_type, not id — if a row already
-- exists its id is left untouched, so nothing that references it breaks.
--
-- WHY is_enabled IS NOT IN THE UPDATE LIST: an operator enabling Dice through
-- the connector admin UI is a production state change. Including is_enabled here
-- would silently revert it on the next deploy that touches this file's checksum.
-- The seed establishes the initial value on INSERT and never speaks for it again.
-- =============================================================================

INSERT INTO channels (id, channel_type, display_name, is_enabled) VALUES
  -- Live day 1: §4.3 intake is a forwarded email, a paste, or an upload.
  ('01900000-0000-7000-8000-000000000101', 'EMAIL',     'Email Intake',      true),
  ('01900000-0000-7000-8000-000000000102', 'PORTAL',    'Portal Upload',     true),
  ('01900000-0000-7000-8000-000000000103', 'MANUAL',    'Manual Entry',      true),
  ('01900000-0000-7000-8000-000000000104', 'API',       'Public API',        true),

  -- Phase 2+ connectors. Present from day 1 so that enabling one is a row
  -- update plus a connector service — the §6.15 "zero schema changes" claim.
  ('01900000-0000-7000-8000-000000000105', 'LINKEDIN',  'LinkedIn',          false),
  ('01900000-0000-7000-8000-000000000106', 'DICE',      'Dice',              false),
  ('01900000-0000-7000-8000-000000000107', 'MONSTER',   'Monster',           false),
  ('01900000-0000-7000-8000-000000000108', 'INDEED',    'Indeed',            false),
  ('01900000-0000-7000-8000-000000000109', 'WHATSAPP',  'WhatsApp',          false)
ON CONFLICT (channel_type) DO UPDATE
  SET display_name = EXCLUDED.display_name;


-- =============================================================================