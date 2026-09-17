/*
title: 커넥터 생성
step: 06
type: sql
summary: OPENFLOW_POSTGRES_CDC 정의로 커넥터 객체를 생성하고 STOPPED 상태까지 대기한 뒤, config.json 편집에 필요한 live 버전 스테이지 URI 를 확보한다.
requires: 05_네트워크_규칙_및_EAI_구성.sql
next: 07_커넥터_설정_config_json.md
*/

-- =============================================================
-- 06. 커넥터 생성
-- =============================================================
-- 실행 위치 : Snowflake (Snowsight 워크시트)
-- 필요 권한 : OPENFLOW_EDU_DE_RL
--             (스키마 CREATE OPENFLOW CONNECTOR + Runtime USAGE)
--
-- 검증 상태 (2026-09-16, 계정 LJ20513 / Enterprise 트라이얼 에서 실제 실행):
--   ✅ SHOW OPENFLOW CONNECTOR DEFINITIONS — 실제 실행 검증 완료
--      (OPENFLOW_POSTGRES_CDC / OPENFLOW_MYSQL_CDC 2행)
--   ✅ CREATE OPENFLOW CONNECTOR ... FROM DEFINITION OPENFLOW_POSTGRES_CDC
--      — 실제 실행 검증 완료. status: CREATING → STOPPED (약 1분)
--      STOPPED 가 기동 전 정상 상태입니다.
--   ✅ ALTER OPENFLOW CONNECTOR ... TERMINATE → DROP — 실제 실행 검증 완료
--      TERMINATING 상태를 거치며 완료까지 2~3분 걸립니다.
--
--   ⚠️ 실측 주의 — Runtime 이 전이 상태이면 커넥터 조작이 거부됩니다
--      Runtime 의 NODE_TYPE_TIER 를 변경한 직후 커넥터를 TERMINATE 하려 하면:
--        Cannot execute ALTER TERMINATE on connector <name> because runtime
--        '<runtime>' is in status UPDATING. Runtime must be ACTIVE for this
--        operation.
--      → SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES 로 ACTIVE 를 기다린 뒤
--        커넥터를 조작하십시오.
--
--   ⚠️ 미검증: 커넥터 설정(07번)과 기동(08번)·적재(09번).
--      트라이얼 계정에서 EAI 가 차단되어 소스에 연결할 수 없습니다(05번 참고).
-- =============================================================


-- -------------------------------------------------------------
-- ⚙️ 설정값
-- -------------------------------------------------------------
--   CONNECTOR  = OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR
--   RUNTIME    = OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME
--   DEFINITION = OPENFLOW_POSTGRES_CDC
-- -------------------------------------------------------------


-- =============================================================
-- STEP 1. 사전조건 최종 확인
-- =============================================================
USE ROLE OPENFLOW_EDU_DE_RL;
USE DATABASE OPENFLOW_EDU_DB;
USE SCHEMA OPENFLOW_EDU_SCH;

-- 1-1. 커넥터 정의 확인
SHOW OPENFLOW CONNECTOR DEFINITIONS;
-- 확인: name = OPENFLOW_POSTGRES_CDC
--       max_node_count = 1  (멀티노드 미지원 — Runtime 도 1노드여야 함)

-- 1-2. Runtime 이 ACTIVE 인지 확인
DESCRIBE OPENFLOW RUNTIME OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME;
-- 확인: status = ACTIVE
--       version >= 2026.8.25.11  (PostgreSQL CDC Gen 2 최소 요구 버전)
--       server_url 이 채워져 있음

-- ACTIVE 가 아니면 대기:
-- SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES(600,
--   'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME');

-- 1-3. Secret 타입 확인
DESCRIBE SECRET OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET;
-- 확인: secret_type = GENERIC_STRING

-- 1-4. EAI 연결 확인
SHOW PARAMETERS LIKE 'EXTERNAL_ACCESS_INTEGRATIONS'
  IN OPENFLOW RUNTIME OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME;
-- 확인: PG_SOURCE_EAI 포함

-- 1-5. Network Rule 확인
DESCRIBE NETWORK RULE OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_NETWORK_RULE;
-- 확인: value_list 에 소스 host:port 포함

-- ⚠️ 위 5개 중 하나라도 통과하지 못하면 진행하지 마세요.
--    커넥터를 만들어 놓고 사전조건을 고치는 것보다,
--    사전조건을 먼저 맞추는 것이 훨씬 빠릅니다.


-- =============================================================
-- STEP 2. 커넥터 생성
-- =============================================================
USE ROLE OPENFLOW_EDU_DE_RL;

-- ⚠️ CREATE OPENFLOW CONNECTOR 는 IF NOT EXISTS 를 지원하지 않을 수
--    있습니다. 재실행 전에 STEP 2-0 으로 존재 여부를 먼저 확인하세요.

-- 2-0. 기존 커넥터 확인 (재실행 안전성)
SHOW OPENFLOW CONNECTORS IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;
-- 이미 PG_CDC_CONNECTOR 가 있으면 STEP 2-1 을 건너뛰고 STEP 3 으로 갑니다.

-- 2-1. 생성
CREATE OPENFLOW CONNECTOR OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR
  IN RUNTIME   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME
  FROM DEFINITION OPENFLOW_POSTGRES_CDC
  DISPLAY_NAME = 'PostgreSQL CDC (실습)'
  COMMENT      = 'PostgreSQL CDC 실습 커넥터. [openflow-edu]';

-- 2-2. STOPPED 상태까지 대기
SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'STOPPED',
  'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');

-- 상태 머신 참고:
--   CREATING → STOPPED → STARTING → RUNNING
-- 신규 생성 커넥터는 STOPPED 에서 멈추며, **live 버전이 자동으로
-- 생성됩니다.** 따라서 최초에는 ADD LIVE VERSION FROM LAST 가 필요 없습니다.


-- =============================================================
-- STEP 3. live 버전 스테이지 URI 확보 (07번 문서의 입력값)
-- =============================================================
-- config.json 을 읽고 쓸 스테이지 위치입니다.
SHOW OPENFLOW CONNECTORS IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;
-- SHOW 를 쓰는 이유: status, runtime, 버전 URI 를 한 번에 얻을 수 있어
--                    DESCRIBE 보다 호출 수가 적습니다.

DESCRIBE OPENFLOW CONNECTOR OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR;
-- 📌 기록할 값:
--   status                       = STOPPED 이어야 함
--   live_version_location_uri    = snow://... 로 시작하는 경로
--
-- 이 URI 를 07번 문서에 그대로 사용합니다. 아래에 적어 두세요.
--
--   LIVE_VERSION_URI = ________________________________________________


-- =============================================================
-- ✅ 완료 체크리스트
-- =============================================================
-- [ ] STEP 1 의 5개 사전조건 확인을 모두 통과했다
-- [ ] PG_CDC_CONNECTOR 가 생성되었다
-- [ ] status = STOPPED 다
-- [ ] live_version_location_uri 를 기록했다
--
-- 다음 문서: 07_커넥터_설정_config_json.md
--            (⚠️ 혼합 — 로컬 파일 다운로드/편집 + Snowflake 업로드)


-- =============================================================
-- 🧹 리소스 정리 (실습 종료 후에만 — 주석 해제 필요)
-- =============================================================
-- ⚠️ 순서 중요: STOP → TERMINATE → DROP
--    RUNNING 상태에서 바로 DROP 하면 실패합니다.
--
-- USE ROLE OPENFLOW_EDU_DE_RL;
-- ALTER OPENFLOW CONNECTOR OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR STOP;
-- SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'STOPPED',
--   'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');
-- ALTER OPENFLOW CONNECTOR OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR TERMINATE;
-- SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'DELETED',
--   'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');
-- DROP OPENFLOW CONNECTOR IF EXISTS
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR;
