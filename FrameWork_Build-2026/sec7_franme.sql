-- ============================================================
-- 05_FRAME
-- ============================================================

CREATE TABLE frame.framework (
  framework_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_code TEXT NOT NULL UNIQUE,   -- GRC-A, ICAEF, REG-C, TRM, TRUSTFABRIC
  framework_name TEXT NOT NULL,
  version        TEXT NOT NULL DEFAULT '1.0',
  purpose        TEXT,
  core_question  TEXT,   -- "Can this organization govern itself effectively?"
  is_proprietary BOOLEAN NOT NULL DEFAULT true,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

CREATE TABLE frame.domain (
  domain_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_id UUID NOT NULL REFERENCES frame.framework(framework_id) ON DELETE CASCADE,
  domain_code  TEXT NOT NULL,
  domain_name  TEXT NOT NULL,
  description  TEXT,
  sort_order   INT NOT NULL DEFAULT 0,
  CONSTRAINT uq_domain UNIQUE (framework_id, domain_code)
);

CREATE TABLE frame.control_objective (
  objective_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  domain_id    UUID NOT NULL REFERENCES frame.domain(domain_id) ON DELETE CASCADE,
  objective_code TEXT NOT NULL,
  statement    TEXT NOT NULL,
  exam_points  TEXT[],
  sort_order   INT NOT NULL DEFAULT 0,
  CONSTRAINT uq_objective UNIQUE (domain_id, objective_code)
);

CREATE TABLE frame.test_procedure (
  procedure_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  objective_id  UUID NOT NULL REFERENCES frame.control_objective(objective_id) ON DELETE CASCADE,
  procedure_code TEXT NOT NULL,
  procedure_text TEXT NOT NULL,
  test_type     TEXT NOT NULL CHECK (test_type IN
                ('inquiry','observation','inspection','reperformance','analytical')),
  assessment_level TEXT NOT NULL CHECK (assessment_level IN
                ('design_effectiveness','operational_effectiveness','governance_effectiveness')),
  min_evidence_tier frame.evidence_tier NOT NULL DEFAULT 'tier_ii',
  sample_guidance TEXT,
  CONSTRAINT uq_procedure UNIQUE (objective_id, procedure_code)
);

-- External standard crosswalk (NIST, ISO, SOC2, PCI, GLBA, FFIEC...)
CREATE TABLE frame.external_standard (
  standard_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  standard_code TEXT NOT NULL UNIQUE,   -- NIST-CSF-2.0, ISO-27001-2022, SOC2-TSC
  standard_name TEXT NOT NULL,
  authority     TEXT,
  version       TEXT
);

CREATE TABLE frame.external_control (
  ext_control_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  standard_id   UUID NOT NULL REFERENCES frame.external_standard(standard_id) ON DELETE CASCADE,
  control_ref   TEXT NOT NULL,        -- 'A.5.1', 'PR.AC-1', 'CC6.1'
  control_text  TEXT,
  CONSTRAINT uq_ext_control UNIQUE (standard_id, control_ref)
);

-- M:N crosswalk — the compliance traceability matrix
CREATE TABLE frame.crosswalk (
  crosswalk_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  objective_id   UUID NOT NULL REFERENCES frame.control_objective(objective_id) ON DELETE CASCADE,
  ext_control_id UUID NOT NULL REFERENCES frame.external_control(ext_control_id) ON DELETE CASCADE,
  mapping_strength TEXT NOT NULL DEFAULT 'full'
                 CHECK (mapping_strength IN ('full','partial','informative')),
  rationale      TEXT,
  CONSTRAINT uq_crosswalk UNIQUE (objective_id, ext_control_id)
);

-- ---------- ENGAGEMENT EXECUTION OF A FRAMEWORK ----------
CREATE TABLE frame.assessment (
  assessment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES core.tenant(tenant_id),
  engagement_id UUID NOT NULL REFERENCES engage.engagement(engagement_id),
  framework_id  UUID NOT NULL REFERENCES frame.framework(framework_id),
  assessment_number TEXT NOT NULL UNIQUE,
  period_start  DATE NOT NULL,
  period_end    DATE NOT NULL,
  as_of_date    DATE NOT NULL DEFAULT CURRENT_DATE,
  status        TEXT NOT NULL DEFAULT 'planning'
                CHECK (status IN ('planning','fieldwork','review','draft_report',
                                  'client_review','final','archived')),
  overall_rating frame.exam_rating,
  maturity_score NUMERIC(3,2) CHECK (maturity_score BETWEEN 0 AND 5),
  lead_assessor UUID REFERENCES core.app_user(user_id),
  qa_reviewer   UUID REFERENCES core.app_user(user_id),
  issued_at     TIMESTAMPTZ,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  CONSTRAINT ck_period CHECK (period_end >= period_start),
  CONSTRAINT ck_qa_independent CHECK (qa_reviewer IS NULL OR qa_reviewer <> lead_assessor)
);

CREATE TABLE frame.workpaper (
  workpaper_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assessment_id UUID NOT NULL REFERENCES frame.assessment(assessment_id) ON DELETE CASCADE,
  procedure_id  UUID NOT NULL REFERENCES frame.test_procedure(procedure_id),
  wp_reference  TEXT NOT NULL,     -- 'GRC-A.GO.01.WP1'
  population_size INT,
  sample_size   INT,
  sample_method TEXT CHECK (sample_method IN ('random','judgmental','systematic','full_population')),
  work_performed TEXT,
  result        frame.exam_rating,
  exceptions_noted INT NOT NULL DEFAULT 0,
  conclusion    TEXT,
  prepared_by   UUID REFERENCES core.app_user(user_id),
  prepared_at   TIMESTAMPTZ,
  reviewed_by   UUID REFERENCES core.app_user(user_id),
  reviewed_at   TIMESTAMPTZ,
  is_locked     BOOLEAN NOT NULL DEFAULT false,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  CONSTRAINT uq_wp_ref UNIQUE (assessment_id, wp_reference),
  CONSTRAINT ck_wp_review CHECK (reviewed_by IS NULL OR reviewed_by <> prepared_by),
  CONSTRAINT ck_sample CHECK (sample_size IS NULL OR population_size IS NULL
                              OR sample_size <= population_size)
);

-- ICAEF™ "Evidence Before Conclusion" — evidence is a first-class object
CREATE TABLE frame.evidence (
  evidence_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workpaper_id  UUID NOT NULL REFERENCES frame.workpaper(workpaper_id) ON DELETE CASCADE,
  document_id   UUID,              -- FK added after docs schema
  evidence_ref  TEXT NOT NULL,
  description   TEXT NOT NULL,
  tier          frame.evidence_tier NOT NULL,
  source        TEXT NOT NULL CHECK (source IN
                ('client_provided','independently_obtained','system_generated',
                 'third_party_confirmed','observed')),
  obtained_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  obtained_by   UUID REFERENCES core.app_user(user_id),
  sha256_hash   TEXT,
  is_sufficient BOOLEAN,
  reliability_notes TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_evidence_wp ON frame.evidence (workpaper_id, tier);

-- Enforce: cannot conclude without evidence
CREATE OR REPLACE FUNCTION frame.fn_require_evidence()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_count INT; v_min frame.evidence_tier;
BEGIN
  IF NEW.result IS NOT NULL AND (OLD.result IS NULL OR OLD.result <> NEW.result) THEN
    SELECT tp.min_evidence_tier INTO v_min
      FROM frame.test_procedure tp WHERE tp.procedure_id = NEW.procedure_id;

    SELECT count(*) INTO v_count FROM frame.evidence e
     WHERE e.workpaper_id = NEW.workpaper_id
       AND e.is_sufficient IS TRUE
       AND e.tier <= v_min;   -- enum ordinal: tier_i strongest

    IF v_count = 0 THEN
      RAISE EXCEPTION
        'ICAEF violation: workpaper % cannot record a conclusion without at least one sufficient % or stronger evidence item',
        NEW.wp_reference, v_min;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_require_evidence
  BEFORE UPDATE ON frame.workpaper
  FOR EACH ROW EXECUTE FUNCTION frame.fn_require_evidence();

CREATE TABLE frame.finding (
  finding_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assessment_id UUID NOT NULL REFERENCES frame.assessment(assessment_id) ON DELETE CASCADE,
  workpaper_id  UUID REFERENCES frame.workpaper(workpaper_id),
  objective_id  UUID REFERENCES frame.control_objective(objective_id),
  finding_number TEXT NOT NULL,
  title         TEXT NOT NULL,
  condition     TEXT NOT NULL,   -- what is
  criteria      TEXT NOT NULL,   -- what should be
  cause         TEXT,
  effect        TEXT,
  recommendation TEXT NOT NULL,
  severity      core.risk_rating NOT NULL,
  rating        frame.exam_rating NOT NULL,
  mgmt_response TEXT,
  mgmt_owner    TEXT,
  target_remediation_date DATE,
  status        TEXT NOT NULL DEFAULT 'open'
                CHECK (status IN ('draft','open','in_remediation','remediated',
                                  'validated','accepted_risk','closed')),
  validated_by  UUID REFERENCES core.app_user(user_id),
  validated_at  TIMESTAMPTZ,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  CONSTRAINT uq_finding_num UNIQUE (assessment_id, finding_number)
);
CREATE INDEX ix_finding_open ON frame.finding (status, target_remediation_date)
  WHERE status IN ('open','in_remediation');

CREATE TABLE frame.remediation_action (
  action_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  finding_id    UUID NOT NULL REFERENCES frame.finding(finding_id) ON DELETE CASCADE,
  action_text   TEXT NOT NULL,
  action_type   TEXT CHECK (action_type IN ('quick_win','strategic','policy','technical','training')),
  owner_name    TEXT,
  owner_user_id UUID REFERENCES core.app_user(user_id),
  due_date      DATE,
  completed_at  TIMESTAMPTZ,
  evidence_of_completion TEXT,
  status        TEXT NOT NULL DEFAULT 'planned'
                CHECK (status IN ('planned','in_progress','complete','overdue','cancelled')),
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

-- Maturity scoring per domain
CREATE TABLE frame.maturity_score (
  score_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assessment_id UUID NOT NULL REFERENCES frame.assessment(assessment_id) ON DELETE CASCADE,
  domain_id     UUID NOT NULL REFERENCES frame.domain(domain_id),
  current_level NUMERIC(3,2) NOT NULL CHECK (current_level BETWEEN 0 AND 5),
  target_level  NUMERIC(3,2) CHECK (target_level BETWEEN 0 AND 5),
  rationale     TEXT,
  scored_by     UUID REFERENCES core.app_user(user_id),
  scored_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_maturity UNIQUE (assessment_id, domain_id)
);

-- ---------- TRM™ TREASURY ----------
CREATE TABLE frame.treasury_control_register (
  tcr_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID NOT NULL REFERENCES crm.client(client_id) ON DELETE CASCADE,
  control_area  TEXT NOT NULL CHECK (control_area IN
                ('treasury_governance','liquidity_governance','transaction_governance',
                 'banking_relationship','fraud_prevention')),
  control_name  TEXT NOT NULL,
  control_description TEXT,
  control_owner TEXT,
  frequency     TEXT CHECK (frequency IN ('continuous','daily','weekly','monthly','quarterly','annual')),
  is_automated  BOOLEAN NOT NULL DEFAULT false,
  last_tested_at DATE,
  last_result   frame.exam_rating,
  next_test_due DATE,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
CREATE INDEX ix_tcr_due ON frame.treasury_control_register (next_test_due)
  WHERE record_status = 'active';

CREATE TABLE frame.banking_relationship (
  relationship_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID NOT NULL REFERENCES crm.client(client_id) ON DELETE CASCADE,
  institution_name TEXT NOT NULL,
  relationship_type TEXT CHECK (relationship_type IN
                    ('operating','credit','investment','custody','merchant')),
  primary_contact TEXT,
  services      TEXT[],
  annual_fees   NUMERIC(12,2),
  review_frequency_months INT DEFAULT 12,
  last_review_date DATE,
  next_review_due DATE,
  concentration_pct NUMERIC(5,2),
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

-- ---------- TRUSTFABRIC™ — "No Proof, No Payment" ----------
CREATE TABLE frame.trust_identity (
  trust_identity_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID REFERENCES crm.client(client_id),
  subject_name  TEXT NOT NULL,
  subject_email CITEXT,
  identity_assurance_level TEXT NOT NULL CHECK (identity_assurance_level IN
                ('IAL1','IAL2','IAL3')),
  authenticator_level TEXT CHECK (authenticator_level IN ('AAL1','AAL2','AAL3')),
  verified_at   TIMESTAMPTZ,
  verified_by   UUID REFERENCES core.app_user(user_id),
  verification_method TEXT,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

CREATE TABLE frame.certificate (
  certificate_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trust_identity_id UUID REFERENCES frame.trust_identity(trust_identity_id),
  client_id     UUID REFERENCES crm.client(client_id),
  ca_provider   TEXT NOT NULL DEFAULT 'GlobalSign',
  cert_type     TEXT NOT NULL CHECK (cert_type IN ('AATL','EV','OV','DV','MSSL','SMIME','CODE_SIGN')),
  serial_number TEXT NOT NULL,
  subject_dn    TEXT NOT NULL,
  issuer_dn     TEXT,
  thumbprint_sha256 TEXT NOT NULL UNIQUE,
  issued_at     TIMESTAMPTZ NOT NULL,
  expires_at    TIMESTAMPTZ NOT NULL,
  revoked_at    TIMESTAMPTZ,
  revocation_reason TEXT,
  status        TEXT GENERATED ALWAYS AS (
                  CASE WHEN revoked_at IS NOT NULL THEN 'revoked'
                       WHEN expires_at < now() THEN 'expired'
                       ELSE 'valid' END) STORED,
  ra_operator   UUID REFERENCES core.app_user(user_id),
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  CONSTRAINT ck_cert_dates CHECK (expires_at > issued_at)
);
CREATE INDEX ix_cert_expiry ON frame.certificate (expires_at)
  WHERE revoked_at IS NULL;

CREATE TABLE frame.authority_grant (
  grant_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID NOT NULL REFERENCES crm.client(client_id),
  trust_identity_id UUID NOT NULL REFERENCES frame.trust_identity(trust_identity_id),
  authority_type TEXT NOT NULL CHECK (authority_type IN
                ('payment_initiate','payment_approve','account_open','contract_sign',
                 'wire_release','vendor_add','user_admin')),
  limit_amount  NUMERIC(14,2),
  currency_code CHAR(3) DEFAULT 'USD',
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to   DATE,
  granted_by_document_id UUID,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

CREATE TABLE frame.transaction_attestation (
  attestation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID NOT NULL REFERENCES crm.client(client_id),
  grant_id      UUID REFERENCES frame.authority_grant(grant_id),
  certificate_id UUID REFERENCES frame.certificate(certificate_id),
  transaction_ref TEXT NOT NULL,
  transaction_type TEXT NOT NULL,
  amount        NUMERIC(14,2),
  currency_code CHAR(3) DEFAULT 'USD',
  counterparty  TEXT,
  payload_hash  TEXT NOT NULL,
  signature_b64 TEXT NOT NULL,
  signed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  verification_status TEXT NOT NULL DEFAULT 'pending'
                CHECK (verification_status IN ('pending','verified','failed','revoked_signer')),
  verified_at   TIMESTAMPTZ,
  device_attestation JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_attest_tx ON frame.transaction_attestation (transaction_ref);

-- "No Proof, No Payment" enforcement
CREATE OR REPLACE FUNCTION frame.fn_no_proof_no_payment()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_valid BOOLEAN; v_limit NUMERIC;
BEGIN
  SELECT (c.status = 'valid'), g.limit_amount
    INTO v_valid, v_limit
    FROM frame.authority_grant g
    LEFT JOIN frame.certificate c ON c.certificate_id = NEW.certificate_id
   WHERE g.grant_id = NEW.grant_id
     AND CURRENT_DATE BETWEEN g.effective_from AND COALESCE(g.effective_to, '9999-12-31');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TrustFabric: no active authority grant for transaction %', NEW.transaction_ref;
  END IF;
  IF v_valid IS NOT TRUE THEN
    RAISE EXCEPTION 'TrustFabric: signing certificate is not valid for transaction %', NEW.transaction_ref;
  END IF;
  IF v_limit IS NOT NULL AND NEW.amount > v_limit THEN
    RAISE EXCEPTION 'TrustFabric: amount % exceeds authority limit % for transaction %',
      NEW.amount, v_limit, NEW.transaction_ref;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_no_proof_no_payment
  BEFORE INSERT ON frame.transaction_attestation
  FOR EACH ROW EXECUTE FUNCTION frame.fn_no_proof_no_payment();
