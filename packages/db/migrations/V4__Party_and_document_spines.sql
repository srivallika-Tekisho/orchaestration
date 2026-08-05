-- V4 — Party and document spines (design doc §6.3, §6.4)
-- =============================================================================


-- -----------------------------------------------------------------------------
-- parties — the unified counterparty model
-- -----------------------------------------------------------------------------
-- Vendors, prime vendors, clients, end clients, MSPs and implementation
-- partners in one table, because a bench sales counterparty routinely plays
-- more than one role (§6.3). Day 1 writes this as the requirement's source;
-- vendor management in a later phase then starts with real relationship data
-- rather than an empty table.
CREATE TABLE parties (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  party_type      text NOT NULL CHECK (party_type IN (
                    'VENDOR', 'PRIME_VENDOR', 'CLIENT', 'END_CLIENT',
                    'MSP', 'IMPLEMENTATION_PARTNER', 'OTHER')),
  name            text NOT NULL,
  website         text,
  status          text NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'WATCHLIST', 'BLOCKED', 'INACTIVE')),
  tier            text CHECK (tier IN ('A', 'B', 'C')),   -- vendor scorecard output
  terms           jsonb NOT NULL DEFAULT '{}',            -- net terms, markup rules
  metadata        jsonb NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,

  CONSTRAINT parties_org_id_key UNIQUE (organization_id, id)
);

-- Design doc §6.3 declares this as a plain UNIQUE (organization_id, name,
-- party_type). Combined with soft delete that is a trap: a deleted vendor
-- permanently blocks re-creating a vendor of the same name. Partial index
-- instead, so uniqueness applies only to live rows.
CREATE UNIQUE INDEX parties_org_name_type_idx
  ON parties (organization_id, name, party_type)
  WHERE deleted_at IS NULL;

CREATE INDEX parties_org_type_status_idx
  ON parties (organization_id, party_type, status)
  WHERE deleted_at IS NULL;

-- Vendor name lookup during JD intake attribution is fuzzy ("ABC Tech" vs
-- "ABC Technologies Inc"), hence trigram rather than btree.
CREATE INDEX parties_name_trgm_idx ON parties USING gin (name gin_trgm_ops);

CREATE TRIGGER parties_set_updated_at
  BEFORE UPDATE ON parties
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- -----------------------------------------------------------------------------
-- documents — the polymorphic document spine
-- -----------------------------------------------------------------------------
-- Day 1 stores JDs and resumes; the same table takes RTRs, MSAs, timesheets
-- and invoices in later phases without restructuring. Bytes live in object
-- storage under an org-prefixed key; only the key is stored here.
--
-- entity_id is deliberately polymorphic and un-FK'd — it points at whichever
-- entity_type names.
CREATE TABLE documents (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  entity_type     text NOT NULL,   -- 'CANDIDATE', 'REQUIREMENT', 'PARTY', ...
  entity_id       uuid NOT NULL,
  doc_type        text NOT NULL CHECK (doc_type IN (
                    'RESUME', 'FORMATTED_RESUME', 'JD', 'RTR', 'MSA', 'NDA', 'PO',
                    'TIMESHEET', 'INVOICE', 'OFFER_LETTER', 'OTHER')),
  storage_key     text NOT NULL,   -- s3://{org_id}/{entity_type}/{id}/v{n}
  file_name       text NOT NULL,
  mime_type       text NOT NULL,
  byte_size       bigint NOT NULL CHECK (byte_size >= 0),
  sha256          text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  version         int  NOT NULL DEFAULT 1 CHECK (version >= 1),
  uploaded_by     uuid,            -- NULL when an agent ingested it
  source          text NOT NULL DEFAULT 'UPLOAD'
                    CHECK (source IN ('UPLOAD', 'EMAIL', 'CHANNEL', 'AGENT')),
  created_at      timestamptz NOT NULL DEFAULT now(),

  -- Absent from the design doc entirely: nothing stopped two rows claiming the
  -- same version of the same entity's document.
  CONSTRAINT documents_entity_version_key
    UNIQUE (organization_id, entity_type, entity_id, version),

  CONSTRAINT documents_org_id_key UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, uploaded_by) REFERENCES users (organization_id, id)
);

CREATE INDEX documents_entity_idx
  ON documents (organization_id, entity_type, entity_id);

-- Content-hash lookup drives both dedup and the parse cache: §4.3 step 6 skips
-- re-parsing and re-embedding a resume whose bytes have not changed.
CREATE INDEX documents_sha256_idx ON documents (organization_id, sha256);