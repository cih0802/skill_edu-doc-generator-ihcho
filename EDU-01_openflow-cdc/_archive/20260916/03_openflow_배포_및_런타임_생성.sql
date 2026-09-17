/*
title: Openflow 배포 및 런타임 생성
step: 03
type: sql
summary: Gen 2 OPENFLOW DEPLOYMENT 와 OPENFLOW RUNTIME 을 SQL로 생성하고, 비동기 프로비저닝을 WAIT 함수로 대기한 뒤 Event Table 을 연결한다.
requires: 02_사전준비_및_권한구성.sql
next: 04_소스DB_준비_및_CDC설정_postgresql.md
*/

-- =============================================================
-- 03. Openflow 배포(Deployment) 및 런타임(Runtime) 생성
-- =============================================================
-- 실행 위치 : Snowflake (Snowsight 워크시트)
-- 필요 권한 : OPENFLOW_EDU_ADMIN_RL (CREATE OPENFLOW DEPLOYMENT 보유)
-- 소요 시간 : 15~20분 (Deployment 5~10분 + Runtime 3~5분)
--
-- 검증 상태 :
--   ✅ CREATE OPENFLOW DEPLOYMENT ... DEPLOYMENT_TYPE = SNOWFLAKE — 컴파일 검증 완료
--   ⚠️ CREATE OPENFLOW RUNTIME — Deployment 가 존재해야 컴파일이 통과하므로
--      현재 계정에서 사전 검증되지 않았습니다. 문법은 공식 문서
--      (CREATE OPENFLOW RUNTIME) 로 대조 확인했습니다.
--   ⚠️ 실제 실행은 크레딧이 발생하고 되돌리기에 시간이 걸리므로
--      사전 검증하지 않았습니다.
-- =============================================================


-- -------------------------------------------------------------
-- ⚙️ 설정값
-- -------------------------------------------------------------
--   DEPLOYMENT   = OPENFLOW_EDU_DEPLOYMENT
--   RUNTIME      = OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME
--   NODE_TYPE    = SMALL      (변경 불가 — 아래 주의사항 참고)
--   NODE_TYPE_TIER = 'S1'     (생성 후 S2/S3 로 변경 가능)
--   MIN/MAX_NODES = 1         (CDC 커넥터는 멀티노드 미지원)
-- -------------------------------------------------------------
--
-- ⚠️ 사이즈 관련 중요 사항
--   - NODE_TYPE (SMALL/MEDIUM/LARGE) 은 생성 후 변경할 수 없습니다.
--     바꾸려면 새 Runtime 을 만들고 커넥터를 재설치해야 합니다.
--   - NODE_TYPE_TIER 는 같은 NODE_TYPE 안에서 변경 가능합니다.
--       ALTER OPENFLOW RUNTIME <name> SET NODE_TYPE_TIER = 'S2';
--   - 티어별 리소스:
--       S1=1CPU/4GB   S2=2CPU/8GB   S3=3CPU/12GB
--       M4=4CPU/16GB  M6=6CPU/24GB  L8=8CPU/33GB
--   - 이 실습은 저볼륨 단일 커넥터이므로 SMALL / S1 로 충분합니다.


-- =============================================================
-- STEP 1. 사전 확인
-- =============================================================
USE ROLE OPENFLOW_EDU_ADMIN_RL;

-- 1-1. Deployment 한도 확인 (계정당 Snowflake Deployment 최대 3개)
SHOW OPENFLOW DEPLOYMENTS;

-- 1-2. CREATE OPENFLOW DEPLOYMENT 권한 보유 확인
SHOW GRANTS TO ROLE OPENFLOW_EDU_ADMIN_RL;
-- 확인: privilege = 'CREATE OPENFLOW DEPLOYMENT', granted_on = 'ACCOUNT'


-- =============================================================
-- STEP 2. Deployment 생성
-- =============================================================
-- Deployment 는 계정 레벨 객체입니다.
-- ⚠️ CREATE 전에 USE DATABASE / USE SCHEMA 를 실행하지 마세요.
USE ROLE OPENFLOW_EDU_ADMIN_RL;

CREATE OPENFLOW DEPLOYMENT IF NOT EXISTS OPENFLOW_EDU_DEPLOYMENT
  DEPLOYMENT_TYPE = SNOWFLAKE
  DISPLAY_NAME    = 'OPENFLOW_EDU_DEPLOYMENT'
  COMMENT         = 'Openflow CDC 실습용 Snowflake 배포. [openflow-edu]';

-- ⚠️ Trial 계정에서 여기서 권한 오류가 발생하면 Openflow가 계정에
--    활성화되지 않은 것입니다. Snowflake 계정 팀에 문의하세요.
--
-- 참고 옵션 (필요 시 CREATE 시점에만 지정 가능, 이후 변경 불가):
--   USE_PRIVATE_LINK = TRUE   -- Openflow UI/Snowflake 접근에 PrivateLink 사용


-- STEP 2-1. 프로비저닝 대기 (5~10분)
-- CREATE 문은 즉시 반환되고 프로비저닝은 비동기로 진행됩니다.
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_DEPLOYMENTS(900, 'OPENFLOW_EDU_DEPLOYMENT');
-- 이 함수는 값을 반환하지 않고 실패/타임아웃 시 예외를 발생시킵니다.
--
--   • 타임아웃(900초): 아직 프로비저닝 중일 수 있습니다.
--     → 몇 분 후 이 SELECT 만 재실행하세요.
--     → ❌ CREATE OPENFLOW DEPLOYMENT 를 다시 실행하지 마세요.
--   • 실패 상태: Openflow UI 에서 오류 메시지를 확인한 뒤 재시도하세요.

-- STEP 2-2. 상태 확인
SHOW OPENFLOW DEPLOYMENTS LIKE 'OPENFLOW_EDU_DEPLOYMENT';
DESCRIBE OPENFLOW DEPLOYMENT OPENFLOW_EDU_DEPLOYMENT;

-- STEP 2-3. DE Role 에 Deployment 사용 권한 부여
GRANT USAGE ON OPENFLOW DEPLOYMENT OPENFLOW_EDU_DEPLOYMENT TO ROLE OPENFLOW_EDU_DE_RL;


-- =============================================================
-- STEP 3. Runtime 생성
-- =============================================================
-- Runtime 은 스키마 레벨 객체입니다. 세션 컨텍스트를 먼저 설정합니다.
USE ROLE OPENFLOW_EDU_ADMIN_RL;
USE DATABASE OPENFLOW_EDU_DB;
USE SCHEMA OPENFLOW_EDU_SCH;

CREATE OPENFLOW RUNTIME IF NOT EXISTS OPENFLOW_EDU_RUNTIME
  IN DEPLOYMENT OPENFLOW_EDU_DEPLOYMENT
  NODE_TYPE       = SMALL
  NODE_TYPE_TIER  = 'S1'
  MIN_NODES       = 1
  MAX_NODES       = 1
  EXECUTE_AS_ROLE = OPENFLOW_EDU_EXECUTE_AS_RL
  DISPLAY_NAME    = 'OPENFLOW_EDU_RUNTIME'
  COMMENT         = 'CDC 실습용 Openflow 런타임. [openflow-edu]';

-- ⚠️ EXTERNAL_ACCESS_INTEGRATIONS 는 여기서 지정하지 않습니다.
--    EAI 는 소스 호스트명이 확정된 뒤(04번 문서 완료 후) 05번 문서에서
--    생성하고 ALTER 로 연결합니다.
--    MODE = EGRESS 네트워크 규칙은 생성 시점에 호스트를 DNS 검증하므로
--    실재하지 않는 호스트로 미리 만들 수 없습니다.


-- STEP 3-1. 프로비저닝 대기 (3~5분)
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES(600,
  'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME');

-- STEP 3-2. ACTIVE 확인
SHOW OPENFLOW RUNTIMES IN ACCOUNT;
-- 확인: status = ACTIVE

DESCRIBE OPENFLOW RUNTIME OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME;
-- 확인 항목:
--   status           = ACTIVE
--   server_url       = 값이 채워져 있어야 함
--                      (예: https://of--<account>.snowflakecomputing.app:443/<key>/nifi/)
--                      비어 있으면 프로비저닝은 됐지만 정상 기동하지 않은 것입니다.
--                      → Openflow UI 에서 상태를 확인하세요.
--   execute_as_role  = OPENFLOW_EDU_EXECUTE_AS_RL
--   version          = 커넥터 요구 버전 확인용 (아래 참고)

-- ⚠️ 런타임 버전 요구사항
--    PostgreSQL / MySQL CDC Gen 2 커넥터는 런타임 버전
--    2026.8.25.11 이상을 요구합니다.
--    위 DESCRIBE 결과의 version 이 이보다 낮으면 먼저 업그레이드하세요.

-- STEP 3-3. DE Role 에 Runtime 사용 권한 부여 (커넥터 생성에 필요)
GRANT USAGE ON OPENFLOW RUNTIME
  OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME
  TO ROLE OPENFLOW_EDU_DE_RL;


-- =============================================================
-- STEP 4. Event Table 연결 (권장)
-- =============================================================
-- 02번 문서에서 만든 전용 Event Table 을 Deployment 에 연결합니다.
-- SET 은 기존 값을 대체합니다.
USE ROLE OPENFLOW_EDU_ADMIN_RL;

ALTER OPENFLOW DEPLOYMENT OPENFLOW_EDU_DEPLOYMENT
  SET EVENT_TABLE = 'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.EVENTS';

-- 검증
DESCRIBE OPENFLOW DEPLOYMENT OPENFLOW_EDU_DEPLOYMENT;
-- 확인: EVENT_TABLE = OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.EVENTS
--
-- ⚠️ 권한 부족으로 ALTER 가 실패하면 ACCOUNTADMIN 으로 재시도하세요.
--    이 단계는 선택 사항이므로 실패해도 실습은 계속 진행할 수 있습니다.
--    다만 이후 트러블슈팅 시 계정 Event Table
--    (SNOWFLAKE.TELEMETRY.EVENTS) 을 조회해야 합니다.


-- =============================================================
-- ✅ 완료 체크리스트
-- =============================================================
-- [ ] SHOW OPENFLOW DEPLOYMENTS 에서 OPENFLOW_EDU_DEPLOYMENT 가 안정 상태다
-- [ ] SHOW OPENFLOW RUNTIMES IN ACCOUNT 에서 status = ACTIVE 다
-- [ ] DESCRIBE OPENFLOW RUNTIME 의 server_url 이 비어 있지 않다
-- [ ] 런타임 version 이 2026.8.25.11 이상이다
-- [ ] DE Role 에 Deployment USAGE + Runtime USAGE 가 부여되었다
-- [ ] (선택) Event Table 이 Deployment 에 연결되었다
--
-- ⚠️ 여기서부터 Runtime 이 크레딧을 소비합니다.
--    실습을 중단할 경우 98번 문서의 정리 절차를 수행하세요.
--
-- 다음 문서: 04_소스DB_준비_및_CDC설정_postgresql.md
--            (⚠️ Snowflake 외부 작업 — 소스 PostgreSQL 에서 진행)


-- =============================================================
-- 🧹 리소스 정리 (실습 종료 후에만 — 주석 해제 필요)
-- =============================================================
-- ⚠️ DROP OPENFLOW RUNTIME 만으로는 삭제되지 않습니다.
--    Gen 2 Runtime 삭제 워크플로: SUSPEND → TERMINATE → DROP
--    전체 절차와 순서는 98번 문서(98_리소스정리.sql) 를 따르세요.
--
-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
--
-- -- 커넥터까지 한 번에 정리하는 단축 경로
-- ALTER OPENFLOW RUNTIME
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME SUSPEND;
-- ALTER OPENFLOW RUNTIME
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME TERMINATE CASCADE;
-- DROP OPENFLOW RUNTIME IF EXISTS
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME;
--
-- DROP OPENFLOW DEPLOYMENT IF EXISTS OPENFLOW_EDU_DEPLOYMENT;
--
-- 💡 실습을 이어서 할 예정이라면 삭제하지 않고 SUSPEND 만 해도
--    크레딧 소비가 멈춥니다 (11번 문서 B-1 선택 1).
