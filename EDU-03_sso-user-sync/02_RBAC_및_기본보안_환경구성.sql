/*
title: RBAC 및 기본 보안 환경 구성
step: 02
type: sql
summary: 사무직/현장직 이원화 계정 체계를 수용하는 웨어하우스, 데이터베이스, 표준 6대 스키마, 역할 계층과 권한 체계를 구성한다. 계정 레벨 권한 위임이 포함된다.
requires: 없음
next: 03_EntraID_SSO_SAML_인티그레이션.sql
*/

-- ==============================================================================
-- [Step 02] RBAC 및 기본 보안 환경 구성 (RBAC & Foundation Setup)
-- 목적: 사무직/현장직 이원화 계정 체계를 수용하기 위한 데이터베이스, 웨어하우스, 
--       표준 6대 스키마(BRONZE~SECURITY), 역할(Role) 계층 및 권한 체계를 구성합니다.
-- ==============================================================================
-- ==============================================================================
-- 검증 상태 (2026-09-16, 계정 LJ20513 / AWS_AP_NORTHEAST_1 / Enterprise 에서 실제 실행):
--   ✅ CREATE WAREHOUSE / DATABASE / SCHEMA 6종 / ROLE 4종 — 실제 실행 검증 완료
--   ✅ 역할 계층 GRANT 및 리소스 권한 GRANT 전체 — 실제 실행 검증 완료
--   ✅ 계정 레벨 GRANT (CREATE USER / MANAGE GRANTS / EXECUTE TASK / EXECUTE MANAGED TASK) — 실제 실행 검증 완료
--   ✅ KSM_HR_SYNC_ADMIN 역할로 05_ 의 테이블·스트림 생성 가능함 — 실제 실행 검증 완료
--      (위임 권한이 충분한지 확인된 것)
--   ✅ 전체 DROP 후 기준선 복귀 — 실제 실행 검증 완료 (역할 7개 / 사용자 1명 / 통합 2개)
--
-- ⚠️ 소유권 주의: 이 스크립트는 ACCOUNTADMIN 으로 실행되므로 DB·스키마 소유자는
--    ACCOUNTADMIN 입니다. KSM_HR_SYNC_ADMIN 은 GRANT 로 권한만 받습니다.
--
-- 🔴 계정 레벨 권한 위임 경고 — 비용과 무관한 변경입니다
--    GRANT CREATE USER / MANAGE GRANTS ON ACCOUNT 은 사실상 계정 사용자·권한을
--    임의로 조작할 수 있는 권한입니다. 실습 후 반드시 역할을 DROP 하십시오.
-- ==============================================================================

USE ROLE ACCOUNTADMIN;

-- 02.1 전용 가상 웨어하우스 생성
CREATE WAREHOUSE IF NOT EXISTS KSM_AUTH_WH
    WITH WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = '인사 DB 동기화 및 챗봇 인증 전용 웨어하우스. 실습용. [sso-user-sync]';

USE WAREHOUSE KSM_AUTH_WH;

-- 02.2 통합 데이터베이스 및 표준 6대 스키마 생성
CREATE DATABASE IF NOT EXISTS KSM_ENTERPRISE_DB
    COMMENT = '사내 엔터프라이즈 통합 데이터베이스 (인사, 거버넌스, AI 서비스). 실습용. [sso-user-sync]';

-- BRONZE: 원본 인사 원장 데이터 적재 및 CDC 변경 감지 스트림
CREATE SCHEMA IF NOT EXISTS KSM_ENTERPRISE_DB.BRONZE
    COMMENT = '사내 인사 DB 원장 적재 및 CDC Stream 스키마 (Raw Layer). 실습용. [sso-user-sync]';

-- SILVER: 정제된 인사 상태 및 동기화 감사(Audit) 로그
CREATE SCHEMA IF NOT EXISTS KSM_ENTERPRISE_DB.SILVER
    COMMENT = '정제된 인사 상태 및 동기화 감사 로그 스키마 (Refined/Audit Layer). 실습용. [sso-user-sync]';

-- GOLD: 조직/부서별 분석 및 지식 베이스(설비 매뉴얼)
CREATE SCHEMA IF NOT EXISTS KSM_ENTERPRISE_DB.GOLD
    COMMENT = '조직 분석 및 공장 설비 지식 베이스 스키마 (Business Layer). 실습용. [sso-user-sync]';

-- SERVING: 모바일 챗봇 및 사용자 권한 서빙 인터페이스
CREATE SCHEMA IF NOT EXISTS KSM_ENTERPRISE_DB.SERVING
    COMMENT = '사내 AI 챗봇 서빙 및 사용자 권한 서빙 스키마 (Serving Layer). 실습용. [sso-user-sync]';

-- OPS: 인사 동기화/자정 감사 프로시저 및 Serverless Task 자동화
CREATE SCHEMA IF NOT EXISTS KSM_ENTERPRISE_DB.OPS
    COMMENT = '인사 동기화 프로시저 및 Serverless Task 스케줄러 스키마 (Operations Layer). 실습용. [sso-user-sync]';

-- SECURITY: SSO, SCIM, OAuth 및 보안 정책 관리
CREATE SCHEMA IF NOT EXISTS KSM_ENTERPRISE_DB.SECURITY
    COMMENT = 'SSO, SCIM, OAuth 및 접근 제어 정책 스키마 (Security/Governance Layer). 실습용. [sso-user-sync]';

-- 02.3 직군별 역할(Role) 계층 구조 생성
-- A. 시스템/인사 동기화 관리자 역할
CREATE ROLE IF NOT EXISTS KSM_HR_SYNC_ADMIN
    COMMENT = '인사 DB 변경사항을 감지하여 Snowflake 사용자를 자동 관리하는 관리자 역할. 실습용. [sso-user-sync]';

-- B. 사무직군 전용 역할 (Entra ID SSO 및 SCIM 동기화 대상)
CREATE ROLE IF NOT EXISTS KSM_OFFICE_USER_ROLE
    COMMENT = '사무직 임직원 기본 역할 (경영/기획/인사/재무 챗봇 및 업무 데이터 접근). 실습용. [sso-user-sync]';

-- C. 공장 현장직군 전용 역할 (사내 인사 DB 동기화 대상)
CREATE ROLE IF NOT EXISTS KSM_FACTORY_WORKER_ROLE
    COMMENT = '공장 현장 생산/설비 작업자 기본 역할 (모바일 설비/공정/안전 챗봇 접근). 실습용. [sso-user-sync]';

-- D. 모바일 챗봇 백엔드 서비스 역할 (BFF / API Gateway 연동용)
CREATE ROLE IF NOT EXISTS KSM_MOBILE_CHATBOT_SERVICE_ROLE
    COMMENT = '모바일 앱 백엔드가 Cortex Search/Agent API를 호출할 때 사용하는 서비스 역할. 실습용. [sso-user-sync]';

-- 02.4 역할 계층(Role Hierarchy) 구성
GRANT ROLE KSM_HR_SYNC_ADMIN TO ROLE ACCOUNTADMIN;
GRANT ROLE KSM_OFFICE_USER_ROLE TO ROLE SYSADMIN;
GRANT ROLE KSM_FACTORY_WORKER_ROLE TO ROLE SYSADMIN;
GRANT ROLE KSM_MOBILE_CHATBOT_SERVICE_ROLE TO ROLE SYSADMIN;

-- 02.5 기본 리소스 사용 권한 부여
-- 웨어하우스 사용 권한
GRANT USAGE ON WAREHOUSE KSM_AUTH_WH TO ROLE KSM_HR_SYNC_ADMIN;
GRANT USAGE ON WAREHOUSE KSM_AUTH_WH TO ROLE KSM_OFFICE_USER_ROLE;
GRANT USAGE ON WAREHOUSE KSM_AUTH_WH TO ROLE KSM_FACTORY_WORKER_ROLE;
GRANT USAGE ON WAREHOUSE KSM_AUTH_WH TO ROLE KSM_MOBILE_CHATBOT_SERVICE_ROLE;

-- 데이터베이스 및 스키마 사용 권한
GRANT ALL PRIVILEGES ON DATABASE KSM_ENTERPRISE_DB TO ROLE KSM_HR_SYNC_ADMIN;
GRANT ALL PRIVILEGES ON ALL SCHEMAS IN DATABASE KSM_ENTERPRISE_DB TO ROLE KSM_HR_SYNC_ADMIN;
GRANT ALL PRIVILEGES ON FUTURE SCHEMAS IN DATABASE KSM_ENTERPRISE_DB TO ROLE KSM_HR_SYNC_ADMIN;

GRANT USAGE ON DATABASE KSM_ENTERPRISE_DB TO ROLE KSM_OFFICE_USER_ROLE;
GRANT USAGE ON SCHEMA KSM_ENTERPRISE_DB.SERVING TO ROLE KSM_OFFICE_USER_ROLE;
GRANT USAGE ON SCHEMA KSM_ENTERPRISE_DB.GOLD TO ROLE KSM_OFFICE_USER_ROLE;

GRANT USAGE ON DATABASE KSM_ENTERPRISE_DB TO ROLE KSM_FACTORY_WORKER_ROLE;
GRANT USAGE ON SCHEMA KSM_ENTERPRISE_DB.SERVING TO ROLE KSM_FACTORY_WORKER_ROLE;
GRANT USAGE ON SCHEMA KSM_ENTERPRISE_DB.GOLD TO ROLE KSM_FACTORY_WORKER_ROLE;

GRANT USAGE ON DATABASE KSM_ENTERPRISE_DB TO ROLE KSM_MOBILE_CHATBOT_SERVICE_ROLE;
GRANT USAGE ON SCHEMA KSM_ENTERPRISE_DB.SERVING TO ROLE KSM_MOBILE_CHATBOT_SERVICE_ROLE;
GRANT USAGE ON SCHEMA KSM_ENTERPRISE_DB.GOLD TO ROLE KSM_MOBILE_CHATBOT_SERVICE_ROLE;

-- 사용자 생성 및 관리 권한을 인사 동기화 역할에 부여 (ACCOUNTADMIN 권한 위임)
GRANT CREATE USER ON ACCOUNT TO ROLE KSM_HR_SYNC_ADMIN;
GRANT MANAGE GRANTS ON ACCOUNT TO ROLE KSM_HR_SYNC_ADMIN;
GRANT EXECUTE TASK, EXECUTE MANAGED TASK ON ACCOUNT TO ROLE KSM_HR_SYNC_ADMIN;

SELECT 'Step 02 Completed: RBAC and 6-Schema Environment Successfully Initialized' AS STATUS;


-- ==============================================================================
-- 🧹 리소스 정리 (이 문서가 만든 것)
-- ==============================================================================
-- 정본은 `98_리소스정리.sql` 입니다. 아래는 목록 확인용이며 주석 처리되어 있습니다.
--   · WAREHOUSE  KSM_AUTH_WH                        (컴퓨트 비용)
--   · DATABASE   KSM_ENTERPRISE_DB (스키마 6종 포함)  (스토리지)
--   · ROLE       KSM_HR_SYNC_ADMIN / KSM_OFFICE_USER_ROLE /
--                KSM_FACTORY_WORKER_ROLE / KSM_MOBILE_CHATBOT_SERVICE_ROLE
--
-- 🔴 계정 레벨 권한 위임이 함께 사라져야 합니다.
--    GRANT CREATE USER / MANAGE GRANTS ON ACCOUNT 은 역할 DROP 시 소멸합니다.
--    역할을 남기면 권한 위임이 계정에 영구히 남습니다.
--
-- DROP WAREHOUSE IF EXISTS KSM_AUTH_WH;
-- DROP DATABASE  IF EXISTS KSM_ENTERPRISE_DB;
-- DROP ROLE      IF EXISTS KSM_HR_SYNC_ADMIN;
-- DROP ROLE      IF EXISTS KSM_OFFICE_USER_ROLE;
-- DROP ROLE      IF EXISTS KSM_FACTORY_WORKER_ROLE;
-- DROP ROLE      IF EXISTS KSM_MOBILE_CHATBOT_SERVICE_ROLE;
