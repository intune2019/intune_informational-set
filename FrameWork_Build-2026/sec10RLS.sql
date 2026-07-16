-- ============================================================
-- 10_RLS
-- ============================================================

CREATE OR REPLACE FUNCTION core.fn_has_perm(p_perm TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM core.user_role ur
    JOIN core.role_permission rp ON rp.role_id = ur.role_id
    JOIN core.permission p ON p.permission_id = rp.permission_id
    WHERE ur.user_id = core.current_actor()
      AND (ur.expires_at IS NULL OR ur.expires_at > now())
      AND p.perm_code = p_perm);
$$;

CREATE OR REPLACE FUNCTION core.fn_is_staff()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT is_staff FROM core.app_user
                    WHERE user_id = core.current_actor()), false);
$$;

-- Clients a portal user may see
CREATE OR REPLACE FUNCTION core.fn_visible_clients()
RETURNS SETOF UUID LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT c.client_id FROM crm.contact c
   WHERE c.portal_user_id = core.current_actor()
     AND c.record_status = 'active';
$$;

ALTER TABLE crm.client ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_client_staff ON crm.client
  USING (core.fn_is_staff() AND tenant_id = core.current_tenant());
CREATE POLICY p_client_portal ON crm.client FOR SELECT
  USING (client_id IN (SELECT core.fn_visible_clients()));

ALTER TABLE docs.document ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_doc_staff ON docs.document
  USING (core.fn_is_staff() AND tenant_id = core.current_tenant());
CREATE POLICY p_doc_portal ON docs.document FOR SELECT
  USING (client_id IN (SELECT core.fn_visible_clients())
         AND classification NOT IN ('internal','restricted','privileged'));

ALTER TABLE engage.case ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_case_staff ON engage.case
  USING (core.fn_is_staff()
         AND tenant_id = core.current_tenant()
         AND (NOT is_confidential OR core.fn_has_perm('engage.case.confidential')));

ALTER TABLE engage.case_note ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_note_staff ON engage.case_note
  USING (core.fn_is_staff()
         AND (NOT is_privileged OR core.fn_has_perm('engage.note.privileged')));

ALTER TABLE intake.kyc_case ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_kyc_staff ON intake.kyc_case
  USING (core.fn_is_staff() AND tenant_id = core.current_tenant()
         AND core.fn_has_perm('intake.kyc.read'));

ALTER TABLE intake.sar_case ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_sar_restricted ON intake.sar_case
  USING (core.fn_has_perm('intake.sar.read'));   -- SAR confidentiality: 31 CFR 1020.320(e)

ALTER TABLE portal.request ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_req_staff ON portal.request
  USING (core.fn_is_staff() AND tenant_id = core.current_tenant());
CREATE POLICY p_req_portal ON portal.request
  USING (client_id IN (SELECT core.fn_visible_clients()));
