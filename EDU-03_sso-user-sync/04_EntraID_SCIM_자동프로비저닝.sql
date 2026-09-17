/*
title: Entra ID SCIM 자동 프로비저닝 인티그레이션
step: 04
type: sql
summary: SCIM 인티그레이션과 전용 프로비저닝 역할을 만들고 SCIM 액세스 토큰을 발급한다. 실제 베어러 자격증명이 생성되는 단계다.
requires: 03_EntraID_SSO_SAML_인티그레이션.sql
next: 05_현장직_인사DB_테이블_및_스트림.sql
*/

-- ==============================================================================
-- [Step 04] Entra ID SCIM 2.0 자동 프로비저닝 (User & Role Provisioning)
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

-- 04.1 SCIM 관리자 전용 역할 생성 (보안 모범 사례: 최소 권한 원칙)
CREATE ROLE IF NOT EXISTS AAD_PROVISIONING_ROLE
    COMMENT = 'Azure AD SCIM 프로비저닝 클라이언트 전용 역할. 실습용. [sso-user-sync]';

GRANT CREATE USER ON ACCOUNT TO ROLE AAD_PROVISIONING_ROLE;
GRANT CREATE ROLE ON ACCOUNT TO ROLE AAD_PROVISIONING_ROLE;
GRANT MANAGE GRANTS ON ACCOUNT TO ROLE AAD_PROVISIONING_ROLE;
GRANT ROLE AAD_PROVISIONING_ROLE TO ROLE ACCOUNTADMIN;

-- 04.2 Azure AD SCIM 2.0 Security Integration 생성
-- 🔴 계정 레벨 객체이므로 CREATE OR REPLACE 를 쓰지 않습니다.
--    OR REPLACE 는 **동명의 기존 객체를 통째로 덮어씁니다.** 계정에 이미 같은 이름의
--    시큐리티 인티그레이션이나 사용자가 있으면 사용자 자산을 파괴하고, DROP 으로
--    되돌아가지 않습니다. 재실행 안전성은 IF NOT EXISTS + 사전 충돌 검사로 확보합니다.
--    (사전 충돌 검사는 95_실습전_기준선.md 를 먼저 수행하십시오)
CREATE SECURITY INTEGRATION IF NOT EXISTS AAD_SCIM_INTEGRATION
    TYPE = SCIM
    SCIM_CLIENT = 'AZURE'
    RUN_AS_ROLE = 'AAD_PROVISIONING_ROLE'
    ENABLED = TRUE
    COMMENT = '사무직군 Entra ID 사용자 및 보안그룹 자동 동기화 SCIM 연동. 실습용. [sso-user-sync]';

-- 04.3 Azure Portal 등록용 SCIM Access Token(비밀 토큰) 발급
-- * 주의: 반환된 토큰 문자열을 복사하여 Azure Portal의 [프로비전] -> [관리자 자격 증명] -> [비밀 토큰]에 입력합니다.
--   토큰 유효기간(기본 6개월) 만료 전 재발급하여 갱신합니다.
SELECT SYSTEM$GENERATE_SCIM_ACCESS_TOKEN('AAD_SCIM_INTEGRATION') AS SCIM_BEARER_TOKEN;

-- 04.4 SCIM 엔드포인트 URL 확인 방법
-- Azure Portal의 테넌트 URL 형식:
-- https://<계정식별자>.snowflakecomputing.com/scim/v2/
-- 예: https://lj20513.snowflakecomputing.com/scim/v2/

-- 04.5 생성된 SCIM Integration 상태 확인
DESCRIBE SECURITY INTEGRATION AAD_SCIM_INTEGRATION;

SELECT 'Step 04 Completed: Entra ID SCIM 2.0 Integration Configured and Access Token Generated' AS STATUS;


-- ==============================================================================
-- 🧹 리소스 정리 (이 문서가 만든 것)
-- ==============================================================================
-- 정본은 `98_리소스정리.sql` 입니다.
--   · SECURITY INTEGRATION  AAD_SCIM_INTEGRATION   ← **계정 레벨**
--   · ROLE                  AAD_PROVISIONING_ROLE  ← **계정 레벨**
--
-- 🔴 이 문서는 **실제 베어러 토큰**을 발급했습니다.
--    토큰은 AAD_SCIM_INTEGRATION 을 DROP 하면 무효화됩니다.
--    AAD_PROVISIONING_ROLE 은 CREATE USER / CREATE ROLE / MANAGE GRANTS 를
--    보유하므로 역할도 반드시 DROP 하십시오.
--    토큰 값을 어딘가에 복사해 두었다면 그 사본도 폐기하십시오.
--
-- DROP SECURITY INTEGRATION IF EXISTS AAD_SCIM_INTEGRATION;
-- DROP ROLE IF EXISTS AAD_PROVISIONING_ROLE;
