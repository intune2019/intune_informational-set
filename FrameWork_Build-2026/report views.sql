-- ============================================================
-- 11_RPT
-- ============================================================

CREATE MATERIALIZED VIEW rpt.mv_client_360 AS
SELECT
  c.client_id, c.client_number, c.legal_name, c.risk_rating, c.is_regulated,
  k.status            AS kyc_status,
  k.next_review_due   AS kyc_next_review,
  count(DISTINCT e.engagement_id) FILTER (WHERE e.status = 'active') AS active_engagements,
  count(DISTINCT f.finding_id)   FILTER (WHERE f.status IN ('open','in_remediation')) AS open_findings,
  count(DISTINCT f.finding_id)   FILTER (WHERE f.severity IN ('high','critical')
                                          AND f.status IN ('open','in_remediation')) AS high_findings,
  count(DISTINCT d.document_id)  AS document_count,
  max(a.as_of_date)   AS last_assessment_date,
  sum(e.contract_value) FILTER (WHERE e.status = 'active') AS active_contract_value
FROM crm.client c
LEFT JOIN LATERAL (
  SELECT * FROM intake.kyc_case kk
   WHERE kk.client_id = c.client_id AND kk.record_status = 'active'
   ORDER BY kk.opened_at DESC LIMIT 1) k ON true
LEFT JOIN engage.engagement e ON e.client_id = c.client_id
LEFT JOIN frame.assessment a  ON a.engagement_id = e.engagement_id
LEFT JOIN frame.finding f     ON f.assessment_id = a.assessment_id
LEFT JOIN docs.document d     ON d.client_id = c.client_id
WHERE c.record_status = 'active'
GROUP BY c.client_id, c.client_number, c.legal_name, c.risk_rating,
         c.is_regulated, k.status, k.next_review_due;

CREATE UNIQUE INDEX ix_mv_client360 ON rpt.mv_client_360 (client_id);

CREATE MATERIALIZED VIEW rpt.mv_compliance_calendar AS
SELECT 'kyc_review' AS obligation_type, kyc_case_id AS source_id,
       client_id, next_review_due AS due_date,
       'KYC periodic review: ' || case_number AS description,
       CASE WHEN risk_rating IN ('high','critical') THEN 'high' ELSE 'normal' END AS urgency
  FROM intake.kyc_case
 WHERE record_status = 'active' AND next_review_due IS NOT NULL
UNION ALL
SELECT 'policy_review', policy_id, NULL, next_review_due,
       'Policy review: ' || title, 'normal'
  FROM gov.policy WHERE status = 'published' AND next_review_due IS NOT NULL
UNION ALL
SELECT 'control_test', control_id, NULL, next_test_due,
       'Control test: ' || control_name,
       CASE WHEN is_key_control THEN 'high' ELSE 'normal' END
  FROM gov.control WHERE record_status = 'active' AND next_test_due IS NOT NULL
UNION ALL
SELECT 'cert_expiry', certificate_id, client_id, expires_at::date,
       'Certificate expiring: ' || subject_dn, 'high'
  FROM frame.certificate WHERE revoked_at IS NULL
UNION ALL
SELECT 'finding_remediation', finding_id, NULL, target_remediation_date,
       'Finding remediation: ' || title,
       CASE WHEN severity IN ('high','critical') THEN 'high' ELSE 'normal' END
  FROM frame.finding WHERE status IN ('open','in_remediation')
UNION ALL
SELECT 'sar_filing', sar_id, client_id, filing_due_at::date,
       'SAR filing deadline: ' || sar_number, 'high'
  FROM intake.sar_case WHERE status IN ('open','investigating')
UNION ALL
SELECT 'doc_disposition', document_id, client_id, eligible_for_disposition_on,
       'Retention disposition: ' || title, 'normal'
  FROM docs.document
 WHERE legal_hold = false AND record_status = 'active'
   AND eligible_for_disposition_on IS NOT NULL;

CREATE INDEX ix_mv_cal_due ON rpt.mv_compliance_calendar (due_date, urgency);

CREATE MATERIALIZED VIEW rpt.mv_engagement_economics AS
SELECT e.engagement_id, e.engagement_number, e.title, c.legal_name,
       e.contract_value, e.fee_type, e.status,
       COALESCE(sum(t.hours) FILTER (WHERE t.billable), 0)     AS billable_hours,
       COALESCE(sum(t.hours) FILTER (WHERE NOT t.billable), 0) AS nonbillable_hours,
       COALESCE(sum(t.hours * t.rate) FILTER (WHERE t.billable), 0) AS wip_value,
       CASE WHEN e.contract_value > 0
            THEN round(COALESCE(sum(t.hours * t.rate) FILTER (WHERE t.billable),0)
                       / e.contract_value * 100, 2) END        AS pct_budget_consumed
FROM engage.engagement e
JOIN crm.client c ON c.client_id = e.client_id
LEFT JOIN engage.project p ON p.engagement_id = e.engagement_id
LEFT JOIN engage.time_entry t ON t.project_id = p.project_id AND t.record_status = 'active'
WHERE e.record_status = 'active'
GROUP BY e.engagement_id, e.engagement_number, e.title, c.legal_name,
         e.contract_value, e.fee_type, e.status;

CREATE UNIQUE INDEX ix_mv_econ ON rpt.mv_engagement_economics (engagement_id);

-- Compliance traceability matrix (REG-C™ output)
CREATE VIEW rpt.v_traceability_matrix AS
SELECT fw.framework_code, d.domain_name, co.objective_code, co.statement,
       s.standard_code, ec.control_ref, cw.mapping_strength,
       count(DISTINCT wp.workpaper_id) AS times_tested,
       max(wp.reviewed_at)             AS last_tested
FROM frame.framework fw
JOIN frame.domain d            ON d.framework_id = fw.framework_id
JOIN frame.control_objective co ON co.domain_id = d.domain_id
LEFT JOIN frame.crosswalk cw   ON cw.objective_id = co.objective_id
LEFT JOIN frame.external_control ec ON ec.ext_control_id = cw.ext_control_id
LEFT JOIN frame.external_standard s ON s.standard_id = ec.standard_id
LEFT JOIN frame.test_procedure tp ON tp.objective_id = co.objective_id
LEFT JOIN frame.workpaper wp   ON wp.procedure_id = tp.procedure_id
GROUP BY fw.framework_code, d.domain_name, co.objective_code, co.statement,
         s.standard_code, ec.control_ref, cw.mapping_strength;
