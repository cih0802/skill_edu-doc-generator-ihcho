/*
title: 네트워크 규칙, EAI, Secret 구성
step: 05
type: sql
summary: 소스 호스트 egress 를 허용하는 Network Rule 과 External Access Integration 을 만들고 Runtime 에 연결한 뒤, 소스 비밀번호를 담을 GENERIC_STRING Secret 을 준비한다.
requires: 04_소스DB_준비_및_CDC설정_postgresql.md
next: 06_커넥터_생성.sql
*/

-- =============================================================
-- 05. 네트워크 규칙 / EAI / Secret 구성
-- =============================================================
-- 실행 위치 : Snowflake (Snowsight 워크시트)
-- 필요 권한 : OPENFLOW_EDU_ADMIN_RL (CREATE INTEGRATION 보유) + ACCOUNTADMIN
-- 선행 조건 : 04번 문서 완료 — 소스 HOSTNAME / PORT 확보
--
-- 검증 상태 :
--   ⚠️ 실재하는 소스 호스트가 없어 CREATE NETWORK RULE 을 실제 실행 검증
--      하지 못했습니다. EGRESS 규칙은 생성 시점에 DNS 검증을 수행하므로
--      가짜 호스트로는 검증 자체가 불가능합니다.
--      문법은 공식 문서(CREATE NETWORK RULE / CREATE EXTERNAL ACCESS
--      INTEGRATION / ALTER OPENFLOW RUNTIME)로 대조 확인했습니다.
-- =============================================================


-- -------------------------------------------------------------
-- ⚙️ 설정값 — 04번 문서에서 확보한 값으로 반드시 교체하세요
-- -------------------------------------------------------------
-- 아래 SET 문을 먼저 실행한 뒤 이후 블록을 진행합니다.
-- (세션 변수이므로 같은 워크시트 세션에서만 유효합니다.)

SET pg_host        = 'CHANGE_ME.rds.amazonaws.com';   -- 04번 HOSTNAME
SET pg_port        = '5432';                          -- 04번 PORT
SET pg_host_port   = $pg_host || ':' || $pg_port;

SELECT $pg_host_port AS "검증할 host:port";
-- 이 값이 04번에서 nslookup / nc 로 확인한 것과 동일해야 합니다.


-- =============================================================
-- STEP 1. Network Rule 생성
-- =============================================================
-- Network Rule 은 스키마 레벨 객체입니다. 컨텍스트를 먼저 설정합니다.
USE ROLE OPENFLOW_EDU_ADMIN_RL;
USE DATABASE OPENFLOW_EDU_DB;
USE SCHEMA OPENFLOW_EDU_SCH;

-- 1-1. 기존 규칙 확인 (중복 생성 방지)
SHOW NETWORK RULES IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;

-- 1-2. 생성
-- ⚠️ VALUE_LIST 는 세션 변수로 치환할 수 없습니다.
--    위 SELECT 결과를 복사해 아래 문자열을 직접 교체하세요.
CREATE NETWORK RULE IF NOT EXISTS PG_SOURCE_NETWORK_RULE
  TYPE       = HOST_PORT
  MODE       = EGRESS
  VALUE_LIST = ('CHANGE_ME.rds.amazonaws.com:5432')
  COMMENT    = 'PostgreSQL CDC 소스 egress 허용. [openflow-edu]';

-- ❌ 실패 시 대응
--   invalid value for property 'VALUE_LIST'
--     → 호스트가 공개 DNS 로 해석되지 않습니다.
--       원인: placeholder 값을 그대로 둠 / 오타 / 소스 DB 중지
--       조치: 04번 문서 1장의 nslookup 확인을 다시 수행하세요.
--       ⚠️ 존재하지 않는 호스트로 규칙을 만들어 두고 나중에 고치는 것은
--          불가능합니다. EGRESS 규칙은 CREATE/ALTER 시점에 검증됩니다.
--
--   사설망 / 온프레미스 소스라면 MODE = EGRESS 로는 도달할 수 없습니다.
--   → MODE = DATA_CONNECTIVITY_PROXY_EGRESS (DCP) 또는
--     TYPE = PRIVATE_HOST_PORT (outbound PrivateLink, Business Critical 이상)

-- 1-3. 검증
DESCRIBE NETWORK RULE OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_NETWORK_RULE;
-- 확인: value_list 에 소스 host:port 가 포함되어 있어야 합니다.


-- =============================================================
-- STEP 2. External Access Integration 생성
-- =============================================================
-- EAI 는 계정 레벨 객체입니다.
-- ⚠️ CREATE OR REPLACE 를 쓰지 마세요. 다른 Runtime 이 참조 중이면
--    연결이 끊깁니다. IF NOT EXISTS 를 사용합니다.
USE ROLE OPENFLOW_EDU_ADMIN_RL;

CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS PG_SOURCE_EAI
  ALLOWED_NETWORK_RULES = (OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_NETWORK_RULE)
  ENABLED = TRUE
  COMMENT = 'Openflow PostgreSQL CDC 외부 접근 통합. [openflow-edu]';

-- 2-1. execute-as Role 에 사용 권한 부여
GRANT USAGE ON INTEGRATION PG_SOURCE_EAI TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;

-- 2-2. 검증
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'PG_SOURCE_EAI';
DESCRIBE EXTERNAL ACCESS INTEGRATION PG_SOURCE_EAI;
-- 확인: ENABLED = true, ALLOWED_NETWORK_RULES 에 위 규칙이 포함


-- =============================================================
-- STEP 3. Runtime 에 EAI 연결
-- =============================================================
USE ROLE OPENFLOW_EDU_ADMIN_RL;

-- 3-1. 현재 연결 상태 확인
SHOW PARAMETERS LIKE 'EXTERNAL_ACCESS_INTEGRATIONS'
  IN OPENFLOW RUNTIME OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME;

-- 3-2. 연결
-- ⚠️ SET 은 전체 목록을 대체합니다. 기존에 연결된 EAI 가 있다면
--    모두 나열해야 합니다. 추가만 하려면 ADD 를 사용하세요.
ALTER OPENFLOW RUNTIME OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME
  SET EXTERNAL_ACCESS_INTEGRATIONS = (PG_SOURCE_EAI);

-- 기존 EAI 를 유지하면서 추가하는 경우:
-- ALTER OPENFLOW RUNTIME OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME
--   ADD EXTERNAL_ACCESS_INTEGRATIONS = (PG_SOURCE_EAI);

-- 3-3. 검증
SHOW PARAMETERS LIKE 'EXTERNAL_ACCESS_INTEGRATIONS'
  IN OPENFLOW RUNTIME OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME;
-- 확인: PG_SOURCE_EAI 가 목록에 있어야 합니다.
--
-- 참고: EAI 변경은 즉시 적용되며 Runtime 재시작이 필요하지 않습니다.


-- =============================================================
-- STEP 4. Secret 생성 — ⚠️ 별도 워크시트에서 실행하세요
-- =============================================================
-- 소스 DB 비밀번호를 담습니다.
--
-- ⚠️ 보안 지침 (중요)
--   (1) 이 문서에 실제 비밀번호를 적어 저장하지 마세요.
--   (2) 아래 CREATE SECRET 문은 이 파일에서 실행하지 말고,
--       **새 워크시트에 복사해 비밀번호를 직접 입력한 뒤 실행**하고,
--       실행 후 해당 워크시트 내용을 지우세요.
--   (3) TYPE 은 반드시 GENERIC_STRING 입니다. PASSWORD 로 만들면
--       Openflow 커넥터의 SECRET_REFERENCE 및 설정 위저드의
--       Secret 선택 목록에 나타나지 않습니다.
--
-- ---------- 여기부터 별도 워크시트에 복사 ----------
--
-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
--
-- CREATE SECRET IF NOT EXISTS
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET
--   TYPE          = GENERIC_STRING
--   SECRET_STRING = '<04번에서 만든 openflow_repl 의 비밀번호>'
--   COMMENT       = 'PostgreSQL CDC 복제 사용자 비밀번호. [openflow-edu]';
--
-- ---------- 여기까지 ----------


-- STEP 4-1. Secret 검증 (이 파일에서 실행 가능 — 값은 노출되지 않음)
DESCRIBE SECRET OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET;
-- 확인: secret_type = GENERIC_STRING
--
-- ❌ PASSWORD 로 만들어졌다면 삭제 후 GENERIC_STRING 으로 재생성하세요.
--    DROP SECRET OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET;

-- STEP 4-2. execute-as Role 에 READ 권한 부여 (필수)
USE ROLE OPENFLOW_EDU_ADMIN_RL;
GRANT READ ON SECRET OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET
  TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;

-- 검증
SHOW GRANTS ON SECRET OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET;
-- 확인: READ 가 OPENFLOW_EDU_EXECUTE_AS_RL 에 부여되어 있어야 합니다.


-- =============================================================
-- ✅ 완료 체크리스트 (커넥터 생성 전 최종 확인)
-- =============================================================
-- [ ] PG_SOURCE_NETWORK_RULE 의 value_list 에 실제 소스 host:port 가 있다
-- [ ] PG_SOURCE_EAI 가 ENABLED = true 이고 위 규칙을 참조한다
-- [ ] execute-as Role 에 EAI USAGE 가 부여되었다
-- [ ] Runtime 의 EXTERNAL_ACCESS_INTEGRATIONS 에 PG_SOURCE_EAI 가 있다
-- [ ] PG_SOURCE_SECRET 이 secret_type = GENERIC_STRING 이다
-- [ ] execute-as Role 에 Secret READ 가 부여되었다
-- [ ] Runtime status = ACTIVE (03번에서 확인)
--
-- 전체 사전조건 일괄 검증:
SHOW GRANTS TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;
-- 아래 6개가 모두 보여야 합니다.
--   USAGE           on DATABASE  OPENFLOW_EDU_DB
--   USAGE           on SCHEMA    OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH
--   USAGE           on DATABASE  CDC_LAB_PG_DB
--   CREATE SCHEMA   on DATABASE  CDC_LAB_PG_DB
--   USAGE, OPERATE  on WAREHOUSE OPENFLOW_EDU_WH
--   USAGE           on INTEGRATION PG_SOURCE_EAI
--   READ            on SECRET    PG_SOURCE_SECRET
--
-- 다음 문서: 06_커넥터_생성.sql


-- =============================================================
-- 🧹 리소스 정리 (실습 종료 후에만 — 주석 해제 필요)
-- =============================================================
-- ⚠️ Runtime 에서 EAI 연결을 먼저 해제해야 EAI 를 삭제할 수 있습니다.
--
-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
-- ALTER OPENFLOW RUNTIME OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME
--   UNSET EXTERNAL_ACCESS_INTEGRATIONS;
-- DROP INTEGRATION  IF EXISTS PG_SOURCE_EAI;
-- DROP NETWORK RULE IF EXISTS OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_NETWORK_RULE;
-- DROP SECRET       IF EXISTS OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET;
