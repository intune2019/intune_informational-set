-- ============================================================
-- 03_INTAKE
-- ============================================================

CREATE TABLE intake.form_template (
  template_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  template_code TEXT NOT NULL,
  version       INT NOT NULL DEFAULT 1,
  title         TEXT NOT NULL,
  form_type     TEXT NOT NULL CHECK (form_type IN
                ('kyc_individual','kyb_entity','aml_questionnaire',
                 'risk_assessment','engagement_intake','vendor_due_diligence',
                 'w9','conflict_check','custom')),
  json_schema   JSONB NOT NULL,     -- field definitions
  ui_schema     JSONB,
  is_published  BOOLEAN NOT NULL DEFAULT false,
  effective_from DATE,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'draft',
  CONSTRAINT uq_template_version UNIQUE (template_code, version)
);

CREATE TABLE intake.form_submission (
  submission_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES core.tenant(tenant_id),
  template_id   UUID NOT NULL REFERENCES intake.form_template(template_id),
  client_id     UUID REFERENCES crm.client(client_id),
  contact_id    UUID REFERENCES crm.contact(contact_id),
  submitted_by  UUID REFERENCES core.app_user(user_id),
  payload       JSONB NOT NULL,
  payload_hash  TEXT NOT NULL,       -- integrity seal
  status        intake.kyc_status NOT NULL DEFAULT 'in_progress',
  submitted_at  TIMESTAMPTZ,
  ip_address    INET,
  user_agent    TEXT,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
CREATE INDEX ix_sub_client ON intake.form_submission (client_id, status);
CREATE INDEX ix_sub_payload ON intake.form_submission USING gin (payload jsonb_path_ops);

CREATE TABLE intake.kyc_case (
  kyc_case_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES core.tenant(tenant_id),
  client_id     UUID NOT NULL REFERENCES crm.client(client_id),
  case_number   TEXT NOT NULL UNIQUE,
  case_type     TEXT NOT NULL CHECK (case_type IN
                ('initial_onboarding','periodic_review','event_driven',
                 'enhanced_due_diligence','remediation')),
  status        intake.kyc_status NOT NULL DEFAULT 'not_started',
  risk_rating   core.risk_rating,
  risk_score    NUMERIC(5,2),
  cdd_level     TEXT CHECK (cdd_level IN ('simplified','standard','enhanced')),
  assigned_to   UUID REFERENCES core.app_user(user_id),
  reviewed_by   UUID REFERENCES core.app_user(user_id),
  approved_by   UUID REFERENCES core.app_user(user_id),
  opened_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at    TIMESTAMPTZ,
  next_review_due DATE,
  decision_rationale TEXT,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  -- Four-eyes: approver cannot be reviewer
  CONSTRAINT ck_four_eyes CHECK (approved_by IS NULL OR approved_by <> reviewed_by)
);
CREATE INDEX ix_kyc_due ON intake.kyc_case (next_review_due)
  WHERE record_status = 'active';
CREATE INDEX ix_kyc_status ON intake.kyc_case (status, risk_rating);

CREATE TABLE intake.risk_factor (
  factor_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factor_code  TEXT NOT NULL UNIQUE,
  category     TEXT NOT NULL CHECK (category IN
               ('geographic','product','channel','customer','transaction')),
  factor_name  TEXT NOT NULL,
  weight       NUMERIC(5,2) NOT NULL DEFAULT 1.0,
  scoring_rule JSONB NOT NULL,
  is_active    BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE intake.risk_assessment (
  assessment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kyc_case_id   UUID NOT NULL REFERENCES intake.kyc_case(kyc_case_id) ON DELETE CASCADE,
  factor_id     UUID NOT NULL REFERENCES intake.risk_factor(factor_id),
  raw_value     TEXT,
  score         NUMERIC(5,2) NOT NULL,
  weighted_score NUMERIC(6,2) GENERATED ALWAYS AS (score) STORED,
  notes         TEXT,
  assessed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  assessed_by   UUID REFERENCES core.app_user(user_id),
  CONSTRAINT uq_case_factor UNIQUE (kyc_case_id, factor_id)
);

CREATE TABLE intake.screening_run (
  screening_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kyc_case_id   UUID REFERENCES intake.kyc_case(kyc_case_id) ON DELETE CASCADE,
  client_id     UUID REFERENCES crm.client(client_id),
  bo_id         UUID REFERENCES crm.beneficial_owner(bo_id),
  provider      TEXT NOT NULL,       -- ofac, un, eu, dowjones, worldcheck...
  list_type     TEXT NOT NULL CHECK (list_type IN
                ('sanctions','pep','adverse_media','watchlist','internal')),
  search_term   TEXT NOT NULL,
  request_payload JSONB,
  response_payload JSONB,
  hit_count     INT NOT NULL DEFAULT 0,
  run_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  run_by        UUID REFERENCES core.app_user(user_id),
  is_automated  BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX ix_screen_case ON intake.screening_run (kyc_case_id, run_at DESC);

CREATE TABLE intake.screening_hit (
  hit_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  screening_id  UUID NOT NULL REFERENCES intake.screening_run(screening_id) ON DELETE CASCADE,
  matched_name  TEXT NOT NULL,
  match_score   NUMERIC(5,2),
  list_source   TEXT,
  match_details JSONB,
  disposition   TEXT NOT NULL DEFAULT 'pending'
                CHECK (disposition IN ('pending','true_match','false_positive','escalated')),
  disposition_notes TEXT,
  dispositioned_by UUID REFERENCES core.app_user(user_id),
  dispositioned_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_hit_pending ON intake.screening_hit (disposition)
  WHERE disposition = 'pending';

-- SAR / suspicious activity
CREATE TABLE intake.sar_case (
  sar_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES core.tenant(tenant_id),
  client_id     UUID REFERENCES crm.client(client_id),
  sar_number    TEXT NOT NULL UNIQUE,
  detected_at   TIMESTAMPTZ NOT NULL,
  activity_summary TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'open'
                CHECK (status IN ('open','investigating','filed','closed_no_file')),
  filed_at      TIMESTAMPTZ,
  fincen_bsa_id TEXT,
  investigator  UUID REFERENCES core.app_user(user_id),
  -- 30-day filing clock
  filing_due_at TIMESTAMPTZ GENERATED ALWAYS AS (detected_at + INTERVAL '30 days') STORED,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
