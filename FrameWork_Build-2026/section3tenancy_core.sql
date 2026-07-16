-- ============================================================
-- 01_CORE
-- ============================================================

CREATE TABLE core.tenant (
  tenant_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_code   TEXT NOT NULL UNIQUE,
  legal_name    TEXT NOT NULL,
  is_internal   BOOLEAN NOT NULL DEFAULT false,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

CREATE TABLE core.app_user (
  user_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES core.tenant(tenant_id),
  email         CITEXT NOT NULL,
  full_name     TEXT NOT NULL,
  phone         TEXT,
  is_staff      BOOLEAN NOT NULL DEFAULT false,
  mfa_enrolled  BOOLEAN NOT NULL DEFAULT false,
  entra_oid     TEXT UNIQUE,           -- Entra ID object id
  last_login_at TIMESTAMPTZ,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active',
  CONSTRAINT uq_user_email UNIQUE (tenant_id, email)
);

CREATE TABLE core.role (
  role_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_code   TEXT NOT NULL UNIQUE,
  role_name   TEXT NOT NULL,
  scope       TEXT NOT NULL CHECK (scope IN ('internal','client','system')),
  description TEXT,
  created_by UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  record_status core.record_status NOT NULL DEFAULT 'active'
);

CREATE TABLE core.permission (
  permission_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  perm_code     TEXT NOT NULL UNIQUE,    -- e.g. 'intake.kyc.approve'
  resource      TEXT NOT NULL,
  action        TEXT NOT NULL,
  description   TEXT
);

CREATE TABLE core.role_permission (
  role_id       UUID NOT NULL REFERENCES core.role(role_id) ON DELETE CASCADE,
  permission_id UUID NOT NULL REFERENCES core.permission(permission_id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE core.user_role (
  user_id    UUID NOT NULL REFERENCES core.app_user(user_id) ON DELETE CASCADE,
  role_id    UUID NOT NULL REFERENCES core.role(role_id) ON DELETE CASCADE,
  granted_by UUID,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  PRIMARY KEY (user_id, role_id)
);

-- Segregation of Duties conflicts
CREATE TABLE core.sod_conflict (
  sod_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_a_id    UUID NOT NULL REFERENCES core.role(role_id),
  role_b_id    UUID NOT NULL REFERENCES core.role(role_id),
  severity     core.risk_rating NOT NULL DEFAULT 'high',
  rationale    TEXT NOT NULL,
  CONSTRAINT ck_sod_distinct CHECK (role_a_id <> role_b_id)
);

-- Reference/lookup pattern
CREATE TABLE core.lookup_set (
  set_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  set_code TEXT NOT NULL UNIQUE,
  set_name TEXT NOT NULL
);

CREATE TABLE core.lookup_value (
  value_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  set_id     UUID NOT NULL REFERENCES core.lookup_set(set_id) ON DELETE CASCADE,
  value_code TEXT NOT NULL,
  label      TEXT NOT NULL,
  sort_order INT NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  meta       JSONB DEFAULT '{}'::jsonb,
  CONSTRAINT uq_lookup UNIQUE (set_id, value_code)
);

CREATE TABLE core.notification (
  notification_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL REFERENCES core.tenant(tenant_id),
  user_id     UUID REFERENCES core.app_user(user_id),
  channel     TEXT NOT NULL CHECK (channel IN ('email','in_app','sms','webhook')),
  subject     TEXT,
  body        TEXT,
  payload     JSONB,
  status      TEXT NOT NULL DEFAULT 'queued'
              CHECK (status IN ('queued','sent','failed','suppressed')),
  attempts    INT NOT NULL DEFAULT 0,
  send_after  TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at     TIMESTAMPTZ,
  error_text  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_notif_pending ON core.notification (status, send_after)
  WHERE status = 'queued';
