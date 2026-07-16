-- ============================================================
-- 06_DOCS
-- ============================================================

CREATE TABLE docs.retention_policy (
  policy_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_code   TEXT NOT NULL UNIQUE,
  policy_name   TEXT NOT NULL,
  retention_years INT NOT NULL,
  trigger_event TEXT NOT NULL CHECK (trigger_event IN
                ('creation','engagement_close','relationship_end','fiscal_year_end')),
  disposition   TEXT NOT NULL CHECK (disposition IN ('destroy','archive','review')),
  legal_basis   TEXT,          -- 'BSA 31 CFR 1010.430 - 5 years'
  is_active     BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE docs.document (
  document_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES core.tenant(tenant_id),
  client_id     UUID REFERENCES crm.client(client_id),
  engagement_id UUID REFERENCES engage.engagement(engagement_id),
  case_id       UUID REFERENCES engage.case(case_id),
  kyc_case_id   UUID REFERENCES intake.kyc_case(kyc_case_id),
  doc_number    TEXT NOT NULL UNIQUE,
  title         TEXT NOT NULL,
  doc_type      TEXT NOT NULL CHECK (doc_type IN
                ('policy','procedure','contract','engagement_letter','report',
                 'workpaper','evidence','identification','financial_statement',
                 'bank_statement','certificate','correspondence','deliverable','other')),
  classification TEXT NOT NULL DEFAULT 'confidential'
                CHECK (classification IN ('public','internal','confidential','restricted','privileged')),
  retention_policy_id UUID REFERENCES docs.retention_policy(policy_id),
  legal_hold    BOOLEAN NOT NULL DEFAULT false,
  legal_hold_reason TEXT,
  eligible_for_disposition_on DATE,
  current_version INT NOT NULL DEFAULT 1,
  owner_id      UUID REFERENCES core.app_user(user_id),
  tags          TEXT[],
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
CREATE INDEX ix_doc_client ON docs.document (client_id, doc_type);
CREATE INDEX ix_doc_disposition ON docs.document (eligible_for_disposition_on)
  WHERE legal_hold = false AND record_status = 'active';
CREATE INDEX ix_doc_tags ON docs.document USING gin (tags);

CREATE TABLE docs.document_version (
  version_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id   UUID NOT NULL REFERENCES docs.document(document_id) ON DELETE CASCADE,
  version_no    INT NOT NULL,
  storage_backend TEXT NOT NULL DEFAULT 's3',
  storage_bucket TEXT NOT NULL,
  storage_key   TEXT NOT NULL,
  filename      TEXT NOT NULL,
  mime_type     TEXT,
  byte_size     BIGINT,
  sha256_hash   TEXT NOT NULL,
  is_encrypted  BOOLEAN NOT NULL DEFAULT true,
  kms_key_ref   TEXT,
  virus_scan_status TEXT DEFAULT 'pending'
                CHECK (virus_scan_status IN ('pending','clean','infected','error')),
  virus_scanned_at TIMESTAMPTZ,
  change_note   TEXT,
  uploaded_by   UUID REFERENCES core.app_user(user_id),
  uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_doc_version UNIQUE (document_id, version_no)
);
CREATE INDEX ix_docver_hash ON docs.document_version (sha256_hash);

CREATE TABLE docs.document_access_log (
  access_id   BIGSERIAL PRIMARY KEY,
  document_id UUID NOT NULL REFERENCES docs.document(document_id) ON DELETE CASCADE,
  version_id  UUID REFERENCES docs.document_version(version_id),
  user_id     UUID REFERENCES core.app_user(user_id),
  action      TEXT NOT NULL CHECK (action IN ('view','download','print','share','delete','restore')),
  ip_address  INET,
  user_agent  TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_docaccess ON docs.document_access_log (document_id, occurred_at DESC);

CREATE TABLE docs.esign_envelope (
  envelope_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id   UUID NOT NULL REFERENCES docs.document(document_id),
  provider      TEXT NOT NULL DEFAULT 'globalsign',
  external_ref  TEXT,
  status        TEXT NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft','sent','partially_signed','completed','declined','voided','expired')),
  sent_at TIMESTAMPTZ, completed_at TIMESTAMPTZ, expires_at TIMESTAMPTZ,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

CREATE TABLE docs.esign_signer (
  signer_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  envelope_id UUID NOT NULL REFERENCES docs.esign_envelope(envelope_id) ON DELETE CASCADE,
  contact_id  UUID REFERENCES crm.contact(contact_id),
  certificate_id UUID REFERENCES frame.certificate(certificate_id),
  signer_name TEXT NOT NULL,
  signer_email CITEXT NOT NULL,
  routing_order INT NOT NULL DEFAULT 1,
  status      TEXT NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending','sent','viewed','signed','declined')),
  signed_at   TIMESTAMPTZ,
  signature_hash TEXT,
  ip_address  INET
);

-- Now wire evidence -> document
ALTER TABLE frame.evidence
  ADD CONSTRAINT fk_evidence_document
  FOREIGN KEY (document_id) REFERENCES docs.document(document_id);
