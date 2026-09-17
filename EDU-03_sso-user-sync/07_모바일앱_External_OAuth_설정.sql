/*
title: 모바일앱 연동 External OAuth 설정
step: 07
type: sql
summary: 모바일 백엔드가 사용할 External OAuth 인티그레이션과 서비스 사용자를 만들고 설비 매뉴얼 샘플 테이블을 적재한다.
requires: 02_RBAC_및_기본보안_환경구성.sql
next: 08_동기화_시나리오_검증.sql
*/

-- ==============================================================================
-- [Step 07] 모바일 앱 연동 External OAuth 및 챗봇 API 보안 설정 (검증 완료)
-- 목적: 공장 현장 직원이 모바일 앱에서 사번/간편인증 후 Snowflake Cortex Search 및 
--       AI 챗봇 API를 안전하게 호출할 수 있도록 인증 인티그레이션을 구성합니다.
-- ==============================================================================
-- ==============================================================================
-- 검증 상태 (2026-09-16, 계정 LJ20513 에서 실제 실행):
--   ✅ CREATE SECURITY INTEGRATION ... TYPE = EXTERNAL_OAUTH — 실제 실행 검증 완료
--      ("Integration MOBILE_APP_OAUTH_INTEGRATION successfully created")
--   ✅ CREATE USER ... TYPE = SERVICE + GRANT ROLE — 실제 실행 검증 완료
--   ✅ GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER 3건 — 실제 실행 검증 완료
--   ✅ FACTORY_EQUIPMENT_MANUALS 생성 및 2행 INSERT, SELECT 권한 부여 — 실제 실행 검증 완료
--   ✅ DROP SECURITY INTEGRATION / DROP USER 로 원복 — 실제 실행 검증 완료
--   ⚠️ 실제 JWT 토큰으로 Snowflake 에 인증하는 왕복은 미검증. 위 RSA 공개키는 더미이며
--      대응하는 개인키가 없으므로 이 인티그레이션으로 실제 로그인은 성공하지 않는다.
--      문법과 생성 가능성만 확인된 것이다.
--   ⚠️ 이 문서는 Cortex Search 서비스를 만들지 않는다. "Cortex Search API 호출" 은
--      권한 준비까지이며 실제 검색 서비스는 이 실습 범위에 없다.
--
-- 🔴 EXTERNAL_OAUTH_ANY_ROLE_MODE = 'ENABLE' 은 토큰이 임의 역할로 전환하는 것을
--    허용합니다. 최소 권한 원칙과 상충하므로 운영에서는 'DISABLE' 또는
--    'ENABLE_FOR_PRIVILEGE' 를 검토하십시오.
-- ==============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE KSM_AUTH_WH;
USE DATABASE KSM_ENTERPRISE_DB;
USE SCHEMA SECURITY;

-- 07.1 모바일 백엔드 API 서버 (BFF) 연계용 External OAuth Security Integration 생성
-- * 사내 인증 서버(Keycloak, Okta, 사내 OAuth Gateway 등)가 발급한 JWT 토큰을 Snowflake가 직접 검증합니다.
-- * 아래 공개키는 실제 Snowflake 컴파일 검증을 통과한 유효한 RSA 2048bit DER 공개키 포맷입니다.
-- 🔴 계정 레벨 객체이므로 CREATE OR REPLACE 를 쓰지 않습니다.
--    OR REPLACE 는 **동명의 기존 객체를 통째로 덮어씁니다.** 계정에 이미 같은 이름의
--    시큐리티 인티그레이션이나 사용자가 있으면 사용자 자산을 파괴하고, DROP 으로
--    되돌아가지 않습니다. 재실행 안전성은 IF NOT EXISTS + 사전 충돌 검사로 확보합니다.
--    (사전 충돌 검사는 95_실습전_기준선.md 를 먼저 수행하십시오)
CREATE SECURITY INTEGRATION IF NOT EXISTS MOBILE_APP_OAUTH_INTEGRATION
    TYPE = EXTERNAL_OAUTH
    ENABLED = TRUE
    EXTERNAL_OAUTH_TYPE = CUSTOM
    EXTERNAL_OAUTH_ISSUER = 'https://auth.ksm.co.kr/auth/realms/ksm-mobile'
    EXTERNAL_OAUTH_RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4xUDdKCmBBu8PleVJtOxtjxXPVsxz0c6Pn8FM7xm5VM6sgg5AxMNWUF8nDAjHkJxVwZKRl+FKCdw21CkxfTqTcVrDlEHAg8IdPxrlW1e3DMeJZJPybl+D6RNV/zkA46tI1SG3cRMLjqKmh8OkUhaF1oNpSrcu72zBrDhvRgSZffV1QZj+SApDspyJpggUn9ollzj8q0Wfvb7TVQpbhmtfM3RkULuxeKrrn4/OmeRz9GRpSqh/o4C7r7DSFZ9mreH4eeOq5k0CTI7CwHB4OvdX9ZNvkZYyztwYbhKPthKvrzMMAfJ8Vy4ckJUH6hzU2vL6ru3Vl1Bpye+76BI/KxyEwIDAQAB'
    EXTERNAL_OAUTH_AUDIENCE_LIST = ('https://lj20513.snowflakecomputing.com')
    EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM = 'sub' -- JWT 토큰 내 사번 Claim 매핑
    EXTERNAL_OAUTH_SNOWFLAKE_USER_MAPPING_ATTRIBUTE = 'LOGIN_NAME'
    EXTERNAL_OAUTH_ANY_ROLE_MODE = 'ENABLE'
    COMMENT = '사내 모바일 앱 백엔드 및 현장직 사용자용 External OAuth 연동. 실습용. [sso-user-sync]';

-- 07.2 모바일 BFF 백엔드 서비스 계정 생성 (Key-Pair / Service Account)
-- 🔴 계정 레벨 객체이므로 CREATE OR REPLACE 를 쓰지 않습니다.
--    OR REPLACE 는 **동명의 기존 객체를 통째로 덮어씁니다.** 계정에 이미 같은 이름의
--    시큐리티 인티그레이션이나 사용자가 있으면 사용자 자산을 파괴하고, DROP 으로
--    되돌아가지 않습니다. 재실행 안전성은 IF NOT EXISTS + 사전 충돌 검사로 확보합니다.
--    (사전 충돌 검사는 95_실습전_기준선.md 를 먼저 수행하십시오)
CREATE USER IF NOT EXISTS KSM_MOBILE_CHATBOT_SVC_USER
    LOGIN_NAME = 'ksm_mobile_chatbot_svc'
    DISPLAY_NAME = 'KSM Mobile Chatbot Backend Service'
    DEFAULT_ROLE = KSM_MOBILE_CHATBOT_SERVICE_ROLE
    DEFAULT_WAREHOUSE = KSM_AUTH_WH
    TYPE = SERVICE
    COMMENT = '모바일 챗봇 백엔드 게이트웨이 API 전용 서비스 계정. 실습용. [sso-user-sync]';

GRANT ROLE KSM_MOBILE_CHATBOT_SERVICE_ROLE TO USER KSM_MOBILE_CHATBOT_SVC_USER;

-- 07.3 현장직 및 사무직 전용 AI 서비스(Cortex / Search) 사용 권한 부여
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE KSM_OFFICE_USER_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE KSM_FACTORY_WORKER_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE KSM_MOBILE_CHATBOT_SERVICE_ROLE;

-- 07.4 현장직 전용 지식 베이스 매뉴얼 테이블 생성 (GOLD 스키마)
CREATE OR REPLACE TABLE KSM_ENTERPRISE_DB.GOLD.FACTORY_EQUIPMENT_MANUALS (
    MANUAL_ID VARCHAR(50),
    EQUIPMENT_NAME VARCHAR(100),
    MANUAL_TEXT VARCHAR(5000),
    ALLOWED_ROLE VARCHAR(100) DEFAULT 'KSM_FACTORY_WORKER_ROLE'
)
COMMENT = '현장 생산/설비 작업자 전용 지식 베이스 매뉴얼. 실습용. [sso-user-sync]';

INSERT INTO KSM_ENTERPRISE_DB.GOLD.FACTORY_EQUIPMENT_MANUALS VALUES
('MAN-001', '반도체 식각장비 A-100', '비상 정지 시 메인 전원 스위치(#3)를 차단하고 1공장 방재실로 연락하십시오.', 'KSM_FACTORY_WORKER_ROLE'),
('MAN-002', '진공 펌프 VP-20', '압력 게이지가 0.05MPa 이하로 떨어지면 윤활유 밸브를 점검하십시오.', 'KSM_FACTORY_WORKER_ROLE');

GRANT SELECT ON TABLE KSM_ENTERPRISE_DB.GOLD.FACTORY_EQUIPMENT_MANUALS TO ROLE KSM_FACTORY_WORKER_ROLE;
GRANT SELECT ON TABLE KSM_ENTERPRISE_DB.GOLD.FACTORY_EQUIPMENT_MANUALS TO ROLE KSM_MOBILE_CHATBOT_SERVICE_ROLE;

DESCRIBE SECURITY INTEGRATION MOBILE_APP_OAUTH_INTEGRATION;

SELECT 'Step 07 Completed: Mobile App External OAuth & Chatbot Security Configured and Verified' AS STATUS;


-- ==============================================================================
-- 🧹 리소스 정리 (이 문서가 만든 것)
-- ==============================================================================
-- 정본은 `98_리소스정리.sql` 입니다.
--   · SECURITY INTEGRATION  MOBILE_APP_OAUTH_INTEGRATION  ← **계정 레벨**
--   · USER                  KSM_MOBILE_CHATBOT_SVC_USER   ← **계정 레벨**
--   · TABLE                 KSM_ENTERPRISE_DB.GOLD.FACTORY_EQUIPMENT_MANUALS
--
-- 🔴 EXTERNAL_OAUTH_ANY_ROLE_MODE = 'ENABLE' 은 토큰이 임의 역할로 전환할 수
--    있게 합니다. 최소 권한 원칙과 상충하므로 실습 후 반드시 제거하십시오.
--
-- DROP SECURITY INTEGRATION IF EXISTS MOBILE_APP_OAUTH_INTEGRATION;
-- DROP USER IF EXISTS KSM_MOBILE_CHATBOT_SVC_USER;
-- DROP TABLE IF EXISTS KSM_ENTERPRISE_DB.GOLD.FACTORY_EQUIPMENT_MANUALS;
