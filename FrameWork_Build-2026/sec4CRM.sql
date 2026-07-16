-- ============================================================
-- 02_CRM
-- ============================================================

CREATE TABLE crm.client (
  client_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES core.tenant(tenant_id),
  client_number   TEXT NOT NULL UNIQUE,
  legal_name      TEXT NOT NULL,
  dba_name        TEXT,
  entity_type     TEXT NOT NULL CHECK (entity_type IN
                  ('corporation','llc','llp','partnership','sole_prop',
                   'nonprofit','government','trust','individual','other')),
  jurisdiction    TEXT,
  formation_date  DATE,
  ein_enc         BYTEA,                       -- pgcrypto encrypted
  duns_number     TEXT,
  cage_code       TEXT,
  uei_number      TEXT,
  naics_codes     TEXT[],
  website         TEXT,
  industry_sector TEXT,
  is_regulated    BOOLEAN NOT NULL DEFAULT false,
  regulators      TEXT[],                      -- FDIC, OCC, SEC, FINRA...
  risk_rating     core.risk_rating,
  onboarded_at    TIMESTAMPTZ,
  relationship_owner UUID REFERENCES core.app_user(user_id),
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'draft'
);
CREATE INDEX ix_client_tenant ON crm.client (tenant_id, record_status);
CREATE INDEX ix_client_name_trgm ON crm.client USING gin (legal_name gin_trgm_ops);

CREATE TABLE crm.address (
  address_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   UUID NOT NULL REFERENCES crm.client(client_id) ON DELETE CASCADE,
  address_type TEXT NOT NULL CHECK (address_type IN
                ('registered','mailing','physical','billing','other')),
  line1 TEXT NOT NULL, line2 TEXT,
  city TEXT NOT NULL, state_province TEXT,
  postal_code TEXT, country_code CHAR(2) NOT NULL DEFAULT 'US',
  is_primary  BOOLEAN NOT NULL DEFAULT false,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

CREATE TABLE crm.contact (
  contact_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   UUID NOT NULL REFERENCES crm.client(client_id) ON DELETE CASCADE,
  first_name  TEXT NOT NULL,
  last_name   TEXT NOT NULL,
  title       TEXT,
  email       CITEXT,
  phone       TEXT,
  is_primary  BOOLEAN NOT NULL DEFAULT false,
  is_signatory BOOLEAN NOT NULL DEFAULT false,
  portal_user_id UUID REFERENCES core.app_user(user_id),
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
CREATE UNIQUE INDEX uq_contact_primary ON crm.contact (client_id)
  WHERE is_primary AND record_status = 'active';

-- Beneficial ownership (KYB requirement, FinCEN CDD Rule)
CREATE TABLE crm.beneficial_owner (
  bo_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    UUID NOT NULL REFERENCES crm.client(client_id) ON DELETE CASCADE,
  person_name  TEXT NOT NULL,
  dob          DATE,
  ssn_enc      BYTEA,
  passport_enc BYTEA,
  nationality  CHAR(2),
  ownership_pct NUMERIC(5,2) CHECK (ownership_pct BETWEEN 0 AND 100),
  is_control_person BOOLEAN NOT NULL DEFAULT false,
  is_pep       BOOLEAN NOT NULL DEFAULT false,
  pep_details  TEXT,
  verified_at  TIMESTAMPTZ,
  verified_by  UUID REFERENCES core.app_user(user_id),
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
CREATE INDEX ix_bo_client ON crm.beneficial_owner (client_id);

-- Corporate structure / parent-subsidiary (self-referential M:N)
CREATE TABLE crm.client_relationship (
  relationship_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_client_id UUID NOT NULL REFERENCES crm.client(client_id) ON DELETE CASCADE,
  child_client_id  UUID NOT NULL REFERENCES crm.client(client_id) ON DELETE CASCADE,
  relationship_type TEXT NOT NULL CHECK (relationship_type IN
                    ('parent','subsidiary','affiliate','jv','vendor','counterparty')),
  ownership_pct NUMERIC(5,2),
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to   DATE,
  CONSTRAINT ck_rel_distinct CHECK (parent_client_id <> child_client_id),
  CONSTRAINT uq_rel UNIQUE (parent_client_id, child_client_id, relationship_type)
);

CREATE TABLE crm.bank_account (
  bank_account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID NOT NULL REFERENCES crm.client(client_id) ON DELETE CASCADE,
  institution_name TEXT NOT NULL,
  account_nickname TEXT,
  account_number_enc BYTEA NOT NULL,
  account_last4  CHAR(4),
  routing_enc    BYTEA,
  currency_code  CHAR(3) NOT NULL DEFAULT 'USD',
  account_purpose TEXT,
  signatories    UUID[],
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
