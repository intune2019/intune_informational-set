-- ============================================================
-- 13_SEED
-- ============================================================

INSERT INTO core.tenant (tenant_code, legal_name, is_internal)
VALUES ('INTUNE', 'In.Tune & Associates Inc.', true);

INSERT INTO frame.framework (framework_code, framework_name, purpose, core_question) VALUES
('GRC-A','Governance & Control Assurance Framework',
 'Executive and governance layer. Evaluates if governance structure, accountability, risk processes, and controls function as intended.',
 'Can this organization govern itself effectively?'),
('ICAEF','Integrated Control Assurance & Examination Framework',
 'Examination and evidentiary layer. Establishes methodology for examinations.',
 'Can the conclusion be defended through evidence?'),
('REG-C','Regulated Environment Governance Framework',
 'Evaluates ability to operate in environments requiring heightened accountability, oversight, and compliance.',
 'Is the organization governable under scrutiny?'),
('TRM','Treasury & Relationship Management Framework',
 'Governs stewardship of financial resources, banking relationships, liquidity management, and transaction accountability.',
 'Are financial resources properly governed?'),
('TRUSTFABRIC','Identity, Authority & Transaction Assurance Framework',
 'Digital trust layer. No Proof, No Payment. Integrates identity, authority, policy, transaction approval, cryptographic trust.',
 'Can identity, authority, and transactions be trusted?');

-- GRC-A domains
INSERT INTO frame.domain (framework_id, domain_code, domain_name, sort_order)
SELECT framework_id, d.code, d.name, d.ord
  FROM frame.framework f,
  (VALUES ('GO','Governance & Oversight',1),
          ('RC','Risk & Compliance',2),
          ('FTC','Financial & Treasury Controls',3),
          ('OA','Operational Accountability',4),
          ('FIM','Fraud & Integrity Management',5)) AS d(code,name,ord)
 WHERE f.framework_code = 'GRC-A';

-- REG-C domains
INSERT INTO frame.domain (framework_id, domain_code, domain_name, sort_order)
SELECT framework_id, d.code, d.name, d.ord
  FROM frame.framework f,
  (VALUES ('GR','Governance Readiness',1),
          ('DR','Documentation Readiness',2),
          ('CT','Compliance Traceability',3),
          ('OR','Oversight Readiness',4),
          ('RR','Response Readiness',5)) AS d(code,name,ord)
 WHERE f.framework_code = 'REG-C';

-- TRM domains
INSERT INTO frame.domain (framework_id, domain_code, domain_name, sort_order)
SELECT framework_id, d.code, d.name, d.ord
  FROM frame.framework f,
  (VALUES ('TG','Treasury Governance',1),
          ('LG','Liquidity Governance',2),
          ('TXG','Transaction Governance',3),
          ('BRG','Banking Relationship Governance',4),
          ('FPC','Fraud Prevention Controls',5)) AS d(code,name,ord)
 WHERE f.framework_code = 'TRM';

-- ICAEF domains
INSERT INTO frame.domain (framework_id, domain_code, domain_name, sort_order)
SELECT framework_id, d.code, d.name, d.ord
  FROM frame.framework f,
  (VALUES ('CV','Control Validation',1),
          ('FE','Financial Examination',2),
          ('TE','Technical Examination',3),
          ('IE','Investigative Examination',4)) AS d(code,name,ord)
 WHERE f.framework_code = 'ICAEF';

-- TrustFabric domains
INSERT INTO frame.domain (framework_id, domain_code, domain_name, sort_order)
SELECT framework_id, d.code, d.name, d.ord
  FROM frame.framework f,
  (VALUES ('IA','Identity Assurance',1),
          ('AV','Authority Validation',2),
          ('DA','Device Attestation',3),
          ('CE','Cryptographic Evidence',4),
          ('TV','Transaction Verification',5),
          ('PE','Policy Enforcement',6)) AS d(code,name,ord)
 WHERE f.framework_code = 'TRUSTFABRIC';

-- External standards
INSERT INTO frame.external_standard (standard_code, standard_name, authority, version) VALUES
('NIST-CSF','NIST Cybersecurity Framework','NIST','2.0'),
('NIST-800-53','Security and Privacy Controls','NIST','Rev 5'),
('ISO-27001','Information Security Management','ISO','2022'),
('SOC2','Trust Services Criteria','AICPA','2017'),
('PCI-DSS','Payment Card Industry DSS','PCI SSC','4.0'),
('GLBA','Gramm-Leach-Bliley Act Safeguards','FTC','2023'),
('FFIEC','FFIEC IT Examination Handbook','FFIEC','Current'),
('BSA-AML','Bank Secrecy Act / AML','FinCEN','Current'),
('SOX-404','Sarbanes-Oxley Section 404','SEC/PCAOB','Current'),
('CIS','CIS Critical Security Controls','CIS','v8.1'),
('HIPAA','HIPAA Security Rule','HHS','Current');

-- Retention policies
INSERT INTO docs.retention_policy
  (policy_code, policy_name, retention_years, trigger_event, disposition, legal_basis) VALUES
('RET-BSA-5','BSA/AML Records', 5, 'relationship_end','review','31 CFR 1010.430'),
('RET-ENG-7','Engagement Workpapers', 7, 'engagement_close','review','AICPA / SOX 103(a)'),
('RET-SOX-7','SOX Audit Records', 7, 'fiscal_year_end','review','SOX Section 802'),
('RET-CORP-P','Corporate Records', 99,'creation','archive','Permanent retention'),
('RET-GEN-3','General Correspondence', 3, 'creation','destroy','Internal policy'),
('RET-CERT-10','Certificate & PKI Records', 10,'creation','archive','CA/Browser Forum BR 5.4.3'),
('RET-TAX-7','Tax Records', 7, 'fiscal_year_end','review','IRC 6501');

-- Roles
INSERT INTO core.role (role_code, role_name, scope) VALUES
('SYS_ADMIN','System Administrator','system'),
('MANAGING_PRINCIPAL','Managing Principal','internal'),
('ENG_PARTNER','Engagement Partner','internal'),
('ENG_MANAGER','Engagement Manager','internal'),
('ASSESSOR','Assessor / Examiner','internal'),
('QA_REVIEWER','QA Reviewer','internal'),
('COMPLIANCE_OFFICER','Compliance Officer','internal'),
('BSA_OFFICER','BSA/AML Officer','internal'),
('RA_OPERATOR','Registration Authority Operator','internal'),
('TREASURY_ANALYST','Treasury Analyst','internal'),
('CLIENT_ADMIN','Client Administrator','client'),
('CLIENT_USER','Client User','client'),
('CLIENT_SIGNER','Client Signatory','client');

-- Permissions (representative)
INSERT INTO core.permission (perm_code, resource, action) VALUES
('intake.kyc.read','kyc_case','read'),
('intake.kyc.write','kyc_case','write'),
('intake.kyc.approve','kyc_case','approve'),
('intake.sar.read','sar_case','read'),
('intake.sar.file','sar_case','file'),
('intake.screening.disposition','screening_hit','disposition'),
('engage.case.confidential','case','read_confidential'),
('engage.note.privileged','case_note','read_privileged'),
('frame.workpaper.prepare','workpaper','prepare'),
('frame.workpaper.review','workpaper','review'),
('frame.assessment.issue','assessment','issue'),
('frame.certificate.issue','certificate','issue'),
('frame.certificate.revoke','certificate','revoke'),
('docs.legalhold.set','document','legal_hold'),
('docs.disposition.execute','document','dispose'),
('gov.policy.approve','policy','approve'),
('core.user.admin','app_user','admin');

-- SoD conflicts
INSERT INTO core.sod_conflict (role_a_id, role_b_id, severity, rationale)
SELECT a.role_id, b.role_id, 'high',
       'Preparer of workpapers may not perform independent QA review of the same engagement.'
  FROM core.role a, core.role b
 WHERE a.role_code = 'ASSESSOR' AND b.role_code = 'QA_REVIEWER';

INSERT INTO core.sod_conflict (role_a_id, role_b_id, severity, rationale)
SELECT a.role_id, b.role_id, 'critical',
       'RA certificate issuance authority must be segregated from system administration.'
  FROM core.role a, core.role b
 WHERE a.role_code = 'RA_OPERATOR' AND b.role_code = 'SYS_ADMIN';

-- Risk factors
INSERT INTO intake.risk_factor (factor_code, category, factor_name, weight, scoring_rule) VALUES
('GEO-HIGH','geographic','High-risk jurisdiction', 3.0,
 '{"type":"list_match","source":"fatf_grey_black","score_on_match":5}'::jsonb),
('CUST-PEP','customer','Politically exposed person', 3.0,
 '{"type":"boolean","field":"is_pep","score_if_true":5}'::jsonb),
('CUST-CASH','customer','Cash-intensive business', 2.0,
 '{"type":"naics_match","score_on_match":4}'::jsonb),
('CUST-STRUCT','customer','Complex ownership structure', 2.0,
 '{"type":"threshold","field":"ownership_layers","gt":3,"score":4}'::jsonb),
('PROD-WIRE','product','International wire activity', 2.0,
 '{"type":"boolean","score_if_true":3}'::jsonb),
('CHAN-NONFACE','channel','Non-face-to-face onboarding', 1.5,
 '{"type":"boolean","score_if_true":3}'::jsonb),
('CUST-REG','customer','Regulated financial institution', -1.0,
 '{"type":"boolean","field":"is_regulated","score_if_true":-2}'::jsonb);

-- KB spaces
INSERT INTO kb.space (space_code, name, visibility) VALUES
('METHOD','Methodology & Frameworks','internal'),
('REG','Regulatory Library','internal'),
('PLAY','Engagement Playbooks','internal'),
('CLIENT','Client Resource Center','client'),
('RND','Research & Development','restricted');

-- Attach triggers to every audited table
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT c.table_schema, c.table_name,
           (SELECT a.column_name FROM information_schema.columns a
             WHERE a.table_schema = c.table_schema AND a.table_name = c.table_name
             ORDER BY a.ordinal_position LIMIT 1) AS pk_col
      FROM information_schema.tables c
     WHERE c.table_schema IN ('core','crm','intake','engage','frame','docs','portal','kb','gov')
       AND c.table_type = 'BASE TABLE'
       AND c.table_name NOT IN ('audit_log','integrity_check','document_access_log','notification')
  LOOP
    PERFORM core.fn_attach_standard_triggers(r.table_schema, r.table_name, r.pk_col);
  END LOOP;
END $$;
