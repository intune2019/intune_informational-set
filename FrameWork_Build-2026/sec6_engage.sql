-- ============================================================
-- 04_ENGAGE
-- ============================================================

CREATE TABLE engage.service_line (
  service_line_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,      -- GOV, TREAS, COMP, TRUST, TECH
  name TEXT NOT NULL,
  description TEXT,
  default_framework_code TEXT     -- links to frame.framework
);

CREATE TABLE engage.engagement (
  engagement_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      UUID NOT NULL REFERENCES core.tenant(tenant_id),
  client_id      UUID NOT NULL REFERENCES crm.client(client_id),
  engagement_number TEXT NOT NULL UNIQUE,
  title          TEXT NOT NULL,
  service_line_id UUID REFERENCES engage.service_line(service_line_id),
  status         engage.engagement_status NOT NULL DEFAULT 'prospect',
  engagement_partner UUID REFERENCES core.app_user(user_id),
  engagement_manager UUID REFERENCES core.app_user(user_id),
  scope_summary  TEXT,
  independence_confirmed BOOLEAN NOT NULL DEFAULT false,
  conflict_check_at TIMESTAMPTZ,
  contract_signed_at TIMESTAMPTZ,
  start_date DATE, end_date DATE,
  fee_type TEXT CHECK (fee_type IN ('fixed','hourly','retainer','milestone')),
  contract_value NUMERIC(14,2),
  currency_code CHAR(3) NOT NULL DEFAULT 'USD',
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  CONSTRAINT ck_dates CHECK (end_date IS NULL OR end_date >= start_date),
  CONSTRAINT ck_partner_manager CHECK (engagement_partner <> engagement_manager)
);
CREATE INDEX ix_eng_client ON engage.engagement (client_id, status);

CREATE TABLE engage.project (
  project_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  engagement_id UUID NOT NULL REFERENCES engage.engagement(engagement_id) ON DELETE CASCADE,
  project_code  TEXT NOT NULL,
  name          TEXT NOT NULL,
  project_type  TEXT CHECK (project_type IN
                ('assessment','examination','implementation','advisory',
                 'remediation','monitoring','investigation')),
  status        TEXT NOT NULL DEFAULT 'planned'
                CHECK (status IN ('planned','in_progress','blocked','review','complete','cancelled')),
  lead_id       UUID REFERENCES core.app_user(user_id),
  planned_start DATE, planned_end DATE,
  actual_start  DATE, actual_end DATE,
  budget_hours  NUMERIC(8,2),
  percent_complete NUMERIC(5,2) NOT NULL DEFAULT 0
                CHECK (percent_complete BETWEEN 0 AND 100),
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  CONSTRAINT uq_project_code UNIQUE (engagement_id, project_code)
);

CREATE TABLE engage.task (
  task_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   UUID NOT NULL REFERENCES engage.project(project_id) ON DELETE CASCADE,
  parent_task_id UUID REFERENCES engage.task(task_id) ON DELETE CASCADE,
  wbs_code     TEXT,
  title        TEXT NOT NULL,
  description  TEXT,
  status       TEXT NOT NULL DEFAULT 'open'
               CHECK (status IN ('open','in_progress','blocked','review','done','cancelled')),
  priority     TEXT NOT NULL DEFAULT 'medium'
               CHECK (priority IN ('low','medium','high','urgent')),
  assignee_id  UUID REFERENCES core.app_user(user_id),
  due_date     DATE,
  estimate_hours NUMERIC(6,2),
  completed_at TIMESTAMPTZ,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
CREATE INDEX ix_task_assignee ON engage.task (assignee_id, status, due_date);

-- Generic case management (investigations, complaints, incidents)
CREATE TABLE engage.case (
  case_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    UUID NOT NULL REFERENCES core.tenant(tenant_id),
  case_number  TEXT NOT NULL UNIQUE,
  case_type    TEXT NOT NULL CHECK (case_type IN
               ('investigation','complaint','incident','whistleblower',
                'regulatory_inquiry','dispute','fraud')),
  client_id    UUID REFERENCES crm.client(client_id),
  engagement_id UUID REFERENCES engage.engagement(engagement_id),
  title        TEXT NOT NULL,
  summary      TEXT,
  severity     core.risk_rating NOT NULL DEFAULT 'moderate',
  status       TEXT NOT NULL DEFAULT 'open'
               CHECK (status IN ('open','triage','investigating','pending_review','resolved','closed')),
  is_confidential BOOLEAN NOT NULL DEFAULT false,
  opened_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  sla_due_at   TIMESTAMPTZ,
  closed_at    TIMESTAMPTZ,
  owner_id     UUID REFERENCES core.app_user(user_id),
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);
CREATE INDEX ix_case_sla ON engage.case (sla_due_at) WHERE status NOT IN ('resolved','closed');

CREATE TABLE engage.case_note (
  note_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id     UUID NOT NULL REFERENCES engage.case(case_id) ON DELETE CASCADE,
  note_type   TEXT NOT NULL DEFAULT 'general'
              CHECK (note_type IN ('general','interview','finding','decision','escalation')),
  body        TEXT NOT NULL,
  is_privileged BOOLEAN NOT NULL DEFAULT false,
  author_id   UUID NOT NULL REFERENCES core.app_user(user_id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE engage.time_entry (
  time_entry_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES core.app_user(user_id),
  project_id    UUID REFERENCES engage.project(project_id),
  task_id       UUID REFERENCES engage.task(task_id),
  case_id       UUID REFERENCES engage.case(case_id),
  work_date     DATE NOT NULL,
  hours         NUMERIC(5,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
  billable      BOOLEAN NOT NULL DEFAULT true,
  rate          NUMERIC(10,2),
  narrative     TEXT NOT NULL,
  approved_by   UUID REFERENCES core.app_user(user_id),
  approved_at   TIMESTAMPTZ,
  locked        BOOLEAN NOT NULL DEFAULT false,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  CONSTRAINT ck_time_target CHECK (num_nonnulls(project_id, case_id) >= 1)
);
CREATE INDEX ix_time_user_date ON engage.time_entry (user_id, work_date DESC);
