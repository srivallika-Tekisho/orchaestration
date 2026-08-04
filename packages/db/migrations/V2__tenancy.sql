-- V2 — Tenancy (design doc §6.2)
-- =============================================================================
-- The tenant root. Every business row in the schema traces back to an
-- organizations row via organization_id.
-- =============================================================================


CREATE TABLE organizations (
  id          uuid PRIMARY KEY,
  name        text NOT NULL,
  -- Autonomy defaults per action class, intake email address, branding.
  settings    jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz
);

CREATE TRIGGER organizations_set_updated_at
  BEFORE UPDATE ON organizations
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


CREATE TABLE users (
  id              uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  email           citext NOT NULL,
  full_name       text NOT NULL,
  role            text NOT NULL CHECK (role IN ('RECRUITER', 'LEAD', 'ADMIN')),
  -- Per-user autonomy opt-ins (the §8.7 trust ramp writes here) and UI prefs.
  preferences     jsonb NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,

  -- Design doc §6.2 declares `email citext NOT NULL UNIQUE` — globally unique
  -- across all tenants. That prevents a recruiter who contracts for two orgs
  -- from holding an account in each, and leaks the existence of another
  -- tenant's user through the constraint violation. Scoped per-org instead.
  CONSTRAINT users_org_email_key UNIQUE (organization_id, email),

  -- Enables composite FKs from children (e.g. candidates.owner_user_id), so a
  -- row in org A can never reference a user in org B.
  CONSTRAINT users_org_id_key UNIQUE (organization_id, id)
);

CREATE INDEX users_org_role_idx ON users (organization_id, role)
  WHERE deleted_at IS NULL;

CREATE TRIGGER users_set_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();


-- =============================================================================