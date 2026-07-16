-- ============================================================
-- IN.TUNE ERP :: 00_FOUNDATION
-- PostgreSQL 16+
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gist";
CREATE EXTENSION IF NOT EXISTS "pg_cron";
CREATE EXTENSION IF NOT EXISTS "vector";        -- RAG / KB embeddings

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS crm;
CREATE SCHEMA IF NOT EXISTS intake;
CREATE SCHEMA IF NOT EXISTS engage;
CREATE SCHEMA IF NOT EXISTS frame;
CREATE SCHEMA IF NOT EXISTS docs;
CREATE SCHEMA IF NOT EXISTS portal;
CREATE SCHEMA IF NOT EXISTS kb;
CREATE SCHEMA IF NOT EXISTS gov;
CREATE SCHEMA IF NOT EXISTS rpt;

-- ---------- ENUMS ----------
CREATE TYPE core.record_status AS ENUM
  ('draft','active','inactive','archived','deleted');

CREATE TYPE core.risk_rating AS ENUM
  ('low','moderate','elevated','high','critical');

CREATE TYPE frame.exam_rating AS ENUM
  ('effective','partially_effective','deficient','critical_exposure');

CREATE TYPE frame.evidence_tier AS ENUM
  ('tier_i','tier_ii','tier_iii','tier_iv');

CREATE TYPE intake.kyc_status AS ENUM
  ('not_started','in_progress','pending_review','info_requested',
   'approved','rejected','expired','remediation');

CREATE TYPE engage.engagement_status AS ENUM
  ('prospect','proposed','contracted','active','on_hold',
   'closing','closed','terminated');

-- ---------- AUDIT CONTRACT (mixin applied to every table) ----------
-- created_by, created_at, updated_by, updated_at, record_status

-- ---------- SESSION CONTEXT ----------
CREATE OR REPLACE FUNCTION core.current_actor()
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.actor_id', true),'')::uuid;
$$;

CREATE OR REPLACE FUNCTION core.current_tenant()
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true),'')::uuid;
$$;

-- ---------- AUDIT TRIGGER ----------
CREATE OR REPLACE FUNCTION core.fn_audit_stamp()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at := COALESCE(NEW.created_at, now());
    NEW.created_by := COALESCE(NEW.created_by, core.current_actor());
  END IF;
  NEW.updated_at := now();
  NEW.updated_by := COALESCE(core.current_actor(), NEW.updated_by);
  RETURN NEW;
END $$;

-- ---------- IMMUTABLE AUDIT LOG ----------
CREATE TABLE core.audit_log (
  audit_id        BIGSERIAL PRIMARY KEY,
  tenant_id       UUID,
  actor_id        UUID,
  action          TEXT NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  schema_name     TEXT NOT NULL,
  table_name      TEXT NOT NULL,
  record_pk       TEXT NOT NULL,
  old_data        JSONB,
  new_data        JSONB,
  changed_fields  TEXT[],
  client_ip       INET,
  occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  row_hash        TEXT,          -- SHA-256 chain
  prev_hash       TEXT
) PARTITION BY RANGE (occurred_at);

CREATE INDEX ix_audit_tenant_time ON core.audit_log (tenant_id, occurred_at DESC);
CREATE INDEX ix_audit_table       ON core.audit_log (schema_name, table_name, record_pk);
CREATE INDEX ix_audit_actor       ON core.audit_log (actor_id, occurred_at DESC);

REVOKE UPDATE, DELETE ON core.audit_log FROM PUBLIC;

CREATE OR REPLACE FUNCTION core.fn_audit_capture()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_old JSONB; v_new JSONB; v_pk TEXT; v_changed TEXT[];
  v_prev TEXT; v_hash TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN v_old := to_jsonb(OLD);
  ELSIF TG_OP = 'INSERT' THEN v_new := to_jsonb(NEW);
  ELSE v_old := to_jsonb(OLD); v_new := to_jsonb(NEW);
  END IF;

  v_pk := COALESCE(v_new, v_old) ->> (TG_ARGV[0]);

  IF TG_OP = 'UPDATE' THEN
    SELECT array_agg(key) INTO v_changed
    FROM jsonb_each(v_new)
    WHERE v_new -> key IS DISTINCT FROM v_old -> key
      AND key NOT IN ('updated_at','updated_by');
    IF v_changed IS NULL THEN RETURN NEW; END IF;
  END IF;

  SELECT row_hash INTO v_prev FROM core.audit_log
   ORDER BY audit_id DESC LIMIT 1;

  v_hash := encode(digest(
      COALESCE(v_prev,'') || TG_OP || TG_TABLE_NAME ||
      COALESCE(v_pk,'') || COALESCE(v_new::text,'') || now()::text,
      'sha256'), 'hex');

  INSERT INTO core.audit_log (
    tenant_id, actor_id, action, schema_name, table_name, record_pk,
    old_data, new_data, changed_fields, client_ip, row_hash, prev_hash)
  VALUES (
    core.current_tenant(), core.current_actor(), TG_OP,
    TG_TABLE_SCHEMA, TG_TABLE_NAME, v_pk,
    v_old, v_new, v_changed, inet_client_addr(), v_hash, v_prev);

  RETURN COALESCE(NEW, OLD);
END $$;

-- Partition helper (called by cron)
CREATE OR REPLACE FUNCTION core.fn_ensure_audit_partitions(p_months INT DEFAULT 3)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE d DATE; nm TEXT;
BEGIN
  FOR i IN 0..p_months LOOP
    d := date_trunc('month', now())::date + (i || ' month')::interval;
    nm := 'audit_log_' || to_char(d,'YYYY_MM');
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = nm) THEN
      EXECUTE format(
        'CREATE TABLE core.%I PARTITION OF core.audit_log
         FOR VALUES FROM (%L) TO (%L)',
        nm, d, (d + interval '1 month')::date);
    END IF;
  END LOOP;
END $$;

SELECT core.fn_ensure_audit_partitions(6);

-- ---------- BULK TRIGGER ATTACHER ----------
CREATE OR REPLACE FUNCTION core.fn_attach_standard_triggers(
  p_schema TEXT, p_table TEXT, p_pk TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format(
    'DROP TRIGGER IF EXISTS trg_stamp ON %I.%I;
     CREATE TRIGGER trg_stamp BEFORE INSERT OR UPDATE ON %I.%I
     FOR EACH ROW EXECUTE FUNCTION core.fn_audit_stamp();',
     p_schema,p_table,p_schema,p_table);
  EXECUTE format(
    'DROP TRIGGER IF EXISTS trg_audit ON %I.%I;
     CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I
     FOR EACH ROW EXECUTE FUNCTION core.fn_audit_capture(%L);',
     p_schema,p_table,p_schema,p_table,p_pk);
END $$;
