-- ==============================================================================
-- [Step 3] Entra ID SCIM 2.0 자동 프로비저닝 (User & Role Provisioning)
-- 목적: Azure AD(Entra ID)에서 사무직 입사/퇴사/조직 이동 발생 시 
--       Snowflake 사용자와 역할(Role)이 실시간으로 자동 생성/수정/비활성화되도록 연동합니다.
-- ==============================================================================

-- ==============================================================================
-- 검증 상태 (2026-09-16, 계정 LJ20513 에서 실제 실행):
--   ✅ CREATE ROLE AAD_PROVISIONING_ROLE + 계정 레벨 GRANT 3종 — 실제 실행 검증 완료
--   ✅ CREATE SECURITY INTEGRATION ... TYPE = SCIM, SCIM_CLIENT='AZURE' — 실제 실행 검증 완료
--   ✅ SYSTEM$GENERATE_SCIM_ACCESS_TOKEN — 실제 실행 검증 완료 (400자 토큰 반환)
--      🔒 검증 시 토큰 값은 출력하지 않고 LENGTH() 만 확인했습니다
--   ✅ DROP SECURITY INTEGRATION 으로 원복 — 실제 실행 검증 완료
--   ⚠️ Azure Portal 측 프로비저닝 연결 및 실제 사용자 동기화 왕복은 미검증
--      (Entra ID 테넌트가 필요하며 Snowflake 외부 작업이다)
--
-- 🔴 자격증명 취급 경고 — 비용과 무관한 위험입니다
--   3.3 의 SYSTEM$GENERATE_SCIM_ACCESS_TOKEN 은 이 계정에 대해
--   CREATE USER / CREATE ROLE / MANAGE GRANTS 권한으로 동작하는 **실제 베어러 토큰**을
--   발급합니다. 아래 사항을 지키십시오.
--     · 결과 그리드로 SELECT 하면 **쿼리 이력(Query History)에 남습니다.**
--       공유 환경·화면 공유·스크린샷 시 노출 위험이 있습니다
--     · 토큰을 문서·채팅·티켓에 붙여넣지 마십시오
--     · 무효화 방법: AAD_SCIM_INTEGRATION 을 DROP 하면 토큰도 무효화됩니다
--     · 유효기간 기본 6개월. 만료 전 재발급이 필요합니다
-- ==============================================================================

USE ROLE ACCOUNTADMIN;

-- 3.1 SCIM 관리자 전용 역할 생성 (보안 모범 사례: 최소 권한 원칙)
CREATE ROLE IF NOT EXISTS AAD_PROVISIONING_ROLE
    COMMENT = 'Azure AD SCIM 프로비저닝 클라이언트 전용 역할';

GRANT CREATE USER ON ACCOUNT TO ROLE AAD_PROVISIONING_ROLE;
GRANT CREATE ROLE ON ACCOUNT TO ROLE AAD_PROVISIONING_ROLE;
GRANT MANAGE GRANTS ON ACCOUNT TO ROLE AAD_PROVISIONING_ROLE;
GRANT ROLE AAD_PROVISIONING_ROLE TO ROLE ACCOUNTADMIN;

-- 3.2 Azure AD SCIM 2.0 Security Integration 생성
CREATE OR REPLACE SECURITY INTEGRATION AAD_SCIM_INTEGRATION
    TYPE = SCIM
    SCIM_CLIENT = 'AZURE'
    RUN_AS_ROLE = 'AAD_PROVISIONING_ROLE'
    ENABLED = TRUE
    COMMENT = '사무직군 Entra ID 사용자 및 보안그룹 자동 동기화 SCIM 연동';

-- 3.3 Azure Portal 등록용 SCIM Access Token(비밀 토큰) 발급
-- * 주의: 반환된 토큰 문자열을 복사하여 Azure Portal의 [프로비전] -> [관리자 자격 증명] -> [비밀 토큰]에 입력합니다.
--   토큰 유효기간(기본 6개월) 만료 전 재발급하여 갱신합니다.
SELECT SYSTEM$GENERATE_SCIM_ACCESS_TOKEN('AAD_SCIM_INTEGRATION') AS SCIM_BEARER_TOKEN;

-- 3.4 SCIM 엔드포인트 URL 확인 방법
-- Azure Portal의 테넌트 URL 형식:
-- https://<계정식별자>.snowflakecomputing.com/scim/v2/
-- 예: https://lj20513.snowflakecomputing.com/scim/v2/

-- 3.5 생성된 SCIM Integration 상태 확인
DESCRIBE SECURITY INTEGRATION AAD_SCIM_INTEGRATION;

SELECT 'Step 3 Completed: Entra ID SCIM 2.0 Integration Configured and Access Token Generated' AS STATUS;
