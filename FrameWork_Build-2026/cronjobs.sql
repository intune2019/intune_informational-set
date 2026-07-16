-- ============================================================
-- 12_CRON  (pg_cron)
-- ============================================================

-- ---------- JOB FUNCTIONS ----------

-- 1. KYC periodic review scheduler (risk-based cadence)
CREATE OR REPLACE FUNCTION core.job_kyc_review_scheduler()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT := 0; r RECORD;
BEGIN
  FOR r IN
    SELECT k.kyc_case_id, k.client_id, k.tenant_id, k.risk_rating, k.assigned_to
      FROM intake.kyc_case k
     WHERE k.record_status = 'active'
       AND k.status = 'approved'
       AND k.next_review_due <= CURRENT_DATE + 30
       AND NOT EXISTS (SELECT 1 FROM intake.kyc_case k2
                        WHERE k2.client_id = k.client_id
                          AND k2.case_type = 'periodic_review'
                          AND k2.status IN ('not_started','in_progress','pending_review'))
  LOOP
    INSERT INTO intake.kyc_case (
      tenant_id, client_id, case_number, case_type, status,
      risk_rating, assigned_to, next_review_due)
    VALUES (r.tenant_id, r.client_id,
      'KYC-' || to_char(now(),'YYYY') || '-' || lpad(nextval('intake.seq_kyc')::text,6,'0'),
      'periodic_review', 'not_started', r.risk_rating, r.assigned_to,
      CURRENT_DATE + CASE r.risk_rating
        WHEN 'critical' THEN 90 WHEN 'high' THEN 180
        WHEN 'elevated' THEN 365 ELSE 1095 END);

    INSERT INTO core.notification (tenant_id, user_id, channel, subject, body, payload)
    VALUES (r.tenant_id, r.assigned_to, 'email',
      'KYC periodic review due',
      'A periodic review has been opened for client ' || r.client_id,
      jsonb_build_object('kyc_case_id', r.kyc_case_id, 'client_id', r.client_id));

    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

CREATE SEQUENCE IF NOT EXISTS intake.seq_kyc;
CREATE SEQUENCE IF NOT EXISTS engage.seq_case;
CREATE SEQUENCE IF NOT EXISTS docs.seq_doc;

-- 2. Certificate expiry warnings (90/60/30/14/7/1 day)
CREATE OR REPLACE FUNCTION core.job_certificate_expiry_watch()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT := 0; r RECORD;
BEGIN
  FOR r IN
    SELECT c.certificate_id, c.subject_dn, c.expires_at, c.ra_operator, c.cert_type,
           (c.expires_at::date - CURRENT_DATE) AS days_left,
           cl.tenant_id
      FROM frame.certificate c
      LEFT JOIN crm.client cl ON cl.client_id = c.client_id
     WHERE c.revoked_at IS NULL
       AND (c.expires_at::date - CURRENT_DATE) IN (90,60,30,14,7,1)
  LOOP
    INSERT INTO core.notification (tenant_id, user_id, channel, subject, body, payload)
    VALUES (r.tenant_id, r.ra_operator, 'email',
      format('[%s days] Certificate expiring: %s', r.days_left, r.cert_type),
      format('Certificate %s expires on %s.', r.subject_dn, r.expires_at::date),
      jsonb_build_object('certificate_id', r.certificate_id, 'days_left', r.days_left));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- 3. Sanctions rescreening (risk-based)
CREATE OR REPLACE FUNCTION core.job_queue_rescreening()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT := 0;
BEGIN
  INSERT INTO intake.screening_run
    (client_id, provider, list_type, search_term, is_automated, request_payload)
  SELECT c.client_id, 'ofac', 'sanctions', c.legal_name, true,
         jsonb_build_object('queued_at', now(), 'reason', 'periodic_rescreen')
    FROM crm.client c
   WHERE c.record_status = 'active'
     AND NOT EXISTS (
       SELECT 1 FROM intake.screening_run s
        WHERE s.client_id = c.client_id
          AND s.list_type = 'sanctions'
          AND s.run_at > now() - CASE c.risk_rating
                WHEN 'critical' THEN INTERVAL '1 day'
                WHEN 'high'     THEN INTERVAL '7 days'
                WHEN 'elevated' THEN INTERVAL '30 days'
                ELSE INTERVAL '90 days' END);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- 4. SLA breach / overdue escalation
CREATE OR REPLACE FUNCTION core.job_sla_escalation()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT := 0;
BEGIN
  -- Overdue remediation actions
  UPDATE frame.remediation_action
     SET status = 'overdue', updated_at = now()
   WHERE status IN ('planned','in_progress')
     AND due_date < CURRENT_DATE;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- SAR filing clock alerts
  INSERT INTO core.notification (tenant_id, user_id, channel, subject, body, payload)
  SELECT s.tenant_id, s.investigator, 'email',
         'SAR filing deadline approaching: ' || s.sar_number,
         format('SAR %s must be filed by %s.', s.sar_number, s.filing_due_at::date),
         jsonb_build_object('sar_id', s.sar_id)
    FROM intake.sar_case s
   WHERE s.status IN ('open','investigating')
     AND s.filing_due_at BETWEEN now() AND now() + INTERVAL '5 days';

  -- Case SLA breach
  INSERT INTO core.notification (tenant_id, user_id, channel, subject, body, payload)
  SELECT c.tenant_id, c.owner_id, 'in_app',
         'Case SLA breached: ' || c.case_number,
         c.title, jsonb_build_object('case_id', c.case_id)
    FROM engage.case c
   WHERE c.status NOT IN ('resolved','closed')
     AND c.sla_due_at < now();

  RETURN v_count;
END $$;

-- 5. Retention / disposition sweep
CREATE OR REPLACE FUNCTION core.job_retention_sweep()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT := 0;
BEGIN
  -- Compute disposition dates where missing
  UPDATE docs.document d
     SET eligible_for_disposition_on =
         (d.created_at::date + (rp.retention_years || ' years')::interval)::date,
         updated_at = now()
    FROM docs.retention_policy rp
   WHERE rp.policy_id = d.retention_policy_id
     AND d.eligible_for_disposition_on IS NULL
     AND rp.trigger_event = 'creation';

  -- Flag for review; NEVER auto-delete under legal hold
  INSERT INTO core.notification (tenant_id, user_id, channel, subject, body, payload)
  SELECT d.tenant_id, d.owner_id, 'in_app',
         'Documents eligible for disposition',
         format('%s is past its retention period.', d.title),
         jsonb_build_object('document_id', d.document_id)
    FROM docs.document d
   WHERE d.legal_hold = false
     AND d.record_status = 'active'
     AND d.eligible_for_disposition_on <= CURRENT_DATE;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- 6. Policy & control review scheduler
CREATE OR REPLACE FUNCTION core.job_governance_review()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT := 0;
BEGIN
  UPDATE gov.policy
     SET next_review_due = COALESCE(effective_date, CURRENT_DATE)
                           + (review_frequency_months || ' months')::interval
   WHERE status = 'published' AND next_review_due IS NULL;

  INSERT INTO core.notification (tenant_id, user_id, channel, subject, body, payload)
  SELECT t.tenant_id, p.owner_id, 'email',
         'Policy review due: ' || p.title,
         format('Policy %s is due for review on %s.', p.policy_code, p.next_review_due),
         jsonb_build_object('policy_id', p.policy_id)
    FROM gov.policy p
    CROSS JOIN LATERAL (SELECT tenant_id FROM core.tenant WHERE is_internal LIMIT 1) t
   WHERE p.status = 'published'
     AND p.next_review_due BETWEEN CURRENT_DATE AND CURRENT_DATE + 30;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- 7. Portal request reminders (escalating)
CREATE OR REPLACE FUNCTION core.job_portal_reminders()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT := 0;
BEGIN
  INSERT INTO core.notification (tenant_id, user_id, channel, subject, body, payload)
  SELECT r.tenant_id, ct.portal_user_id, 'email',
         'Reminder: ' || r.title,
         format('Item %s is due %s.', r.request_number, r.due_date),
         jsonb_build_object('request_id', r.request_id)
    FROM portal.request r
    JOIN crm.contact ct ON ct.contact_id = r.requested_from
   WHERE r.status = 'open'
     AND r.due_date IS NOT NULL
     AND (r.last_reminder_at IS NULL OR r.last_reminder_at < now() - INTERVAL '3 days')
     AND r.due_date <= CURRENT_DATE + 7;

  UPDATE portal.request
     SET reminder_count = reminder_count + 1, last_reminder_at = now()
   WHERE status = 'open' AND due_date <= CURRENT_DATE + 7
     AND (last_reminder_at IS NULL OR last_reminder_at < now() - INTERVAL '3 days');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- 8. Expired share link revocation
CREATE OR REPLACE FUNCTION core.job_revoke_expired_shares()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT;
BEGIN
  UPDATE portal.share_link
     SET revoked_at = now()
   WHERE revoked_at IS NULL
     AND (expires_at < now()
          OR (max_downloads IS NOT NULL AND download_count >= max_downloads));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- 9. Audit chain integrity verification
CREATE TABLE core.integrity_check (
  check_id    BIGSERIAL PRIMARY KEY,
  checked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  rows_checked BIGINT,
  breaks_found INT,
  first_break_id BIGINT,
  status TEXT NOT NULL CHECK (status IN ('pass','fail'))
);

CREATE OR REPLACE FUNCTION core.job_verify_audit_chain(p_window INTERVAL DEFAULT '24 hours')
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE v_breaks INT := 0; v_rows BIGINT := 0; v_first BIGINT;
BEGIN
  WITH chain AS (
    SELECT audit_id, row_hash, prev_hash,
           lag(row_hash) OVER (ORDER BY audit_id) AS expected_prev
      FROM core.audit_log
     WHERE occurred_at > now() - p_window)
  SELECT count(*), count(*) FILTER (WHERE prev_hash IS DISTINCT FROM expected_prev
                                      AND expected_prev IS NOT NULL),
         min(audit_id) FILTER (WHERE prev_hash IS DISTINCT FROM expected_prev
                                 AND expected_prev IS NOT NULL)
    INTO v_rows, v_breaks, v_first
    FROM chain;

  INSERT INTO core.integrity_check (rows_checked, breaks_found, first_break_id, status)
  VALUES (v_rows, v_breaks, v_first, CASE WHEN v_breaks = 0 THEN 'pass' ELSE 'fail' END);

  IF v_breaks > 0 THEN
    INSERT INTO core.notification (tenant_id, channel, subject, body)
    SELECT tenant_id, 'email', 'CRITICAL: audit chain integrity failure',
           format('%s hash breaks detected starting at audit_id %s', v_breaks, v_first)
      FROM core.tenant WHERE is_internal LIMIT 1;
  END IF;

  RETURN format('rows=%s breaks=%s', v_rows, v_breaks);
END $$;

-- 10. Notification dispatcher (marks for external worker pickup)
CREATE OR REPLACE FUNCTION core.job_expire_stale_notifications()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT;
BEGIN
  UPDATE core.notification
     SET status = 'failed', error_text = 'max attempts exceeded'
   WHERE status = 'queued' AND attempts >= 5;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- 11. Refresh reporting layer
CREATE OR REPLACE FUNCTION core.job_refresh_reporting()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY rpt.mv_client_360;
  REFRESH MATERIALIZED VIEW CONCURRENTLY rpt.mv_engagement_economics;
  REFRESH MATERIALIZED VIEW rpt.mv_compliance_calendar;
END $$;

-- ---------- SCHEDULE ----------
SELECT cron.schedule('kyc-review-scheduler', '0 6 * * *',
       $$SELECT core.job_kyc_review_scheduler()$$);

SELECT cron.schedule('cert-expiry-watch', '0 7 * * *',
       $$SELECT core.job_certificate_expiry_watch()$$);

SELECT cron.schedule('sanctions-rescreen', '0 2 * * *',
       $$SELECT core.job_queue_rescreening()$$);

SELECT cron.schedule('sla-escalation', '0 * * * *',
       $$SELECT core.job_sla_escalation()$$);

SELECT cron.schedule('retention-sweep', '0 3 * * 0',
       $$SELECT core.job_retention_sweep()$$);

SELECT cron.schedule('governance-review', '0 8 * * 1',
       $$SELECT core.job_governance_review()$$);

SELECT cron.schedule('portal-reminders', '0 9 * * 1-5',
       $$SELECT core.job_portal_reminders()$$);

SELECT cron.schedule('revoke-expired-shares', '*/15 * * * *',
       $$SELECT core.job_revoke_expired_shares()$$);

SELECT cron.schedule('audit-chain-verify', '30 4 * * *',
       $$SELECT core.job_verify_audit_chain('26 hours')$$);

SELECT cron.schedule('expire-notifications', '*/10 * * * *',
       $$SELECT core.job_expire_stale_notifications()$$);

SELECT cron.schedule('refresh-reporting', '*/30 * * * *',
       $$SELECT core.job_refresh_reporting()$$);

SELECT cron.schedule('audit-partitions', '0 1 1 * *',
       $$SELECT core.fn_ensure_audit_partitions(6)$$);

SELECT cron.schedule('vacuum-analyze', '0 4 * * 0',
       $$VACUUM ANALYZE$$);
