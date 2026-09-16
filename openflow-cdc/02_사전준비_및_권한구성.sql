/*
title: 사전 준비 및 권한 구성
step: 02
type: sql
summary: Openflow Gen 2 사용 가능 여부 게이트 확인 후, Role 3종(admin/DE/execute-as), 인프라 DB/스키마, Warehouse, 대상 DB, Event Table을 생성한다.
requires: 없음
next: 03_openflow_배포_및_런타임_생성.sql
*/

-- =============================================================
-- 02. 사전 준비 및 권한 구성
-- =============================================================
-- 실행 위치 : Snowflake (Snowsight 워크시트)
-- 필요 권한 : ACCOUNTADMIN
-- 검증 상태 : STEP 0 조회문은 실제 실행 검증 완료.
--             CREATE/GRANT 문은 공식 문서 대조 확인 (실행 미검증).
-- =============================================================


-- -------------------------------------------------------------
-- ⚙️ 설정값 — 실습 전에 이 블록만 확인/수정하세요
-- -------------------------------------------------------------
-- 아래 이름을 바꾸려면 03~11번 문서에서도 동일하게 바꿔야 합니다.
--
--   ADMIN_ROLE       = OPENFLOW_EDU_ADMIN_RL
--   DE_ROLE          = OPENFLOW_EDU_DE_RL
--   EXECUTE_AS_ROLE  = OPENFLOW_EDU_EXECUTE_AS_RL
--   INFRA_DB         = OPENFLOW_EDU_DB
--   INFRA_SCHEMA     = OPENFLOW_EDU_SCH
--   WAREHOUSE        = OPENFLOW_EDU_WH
--   DEST_DB          = CDC_LAB_PG_DB
--   EVENT_TABLE      = OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.EVENTS
-- -------------------------------------------------------------


-- =============================================================
-- STEP 0. 게이트 확인 — 여기서 통과하지 못하면 진행하지 마세요
-- =============================================================

-- 0-1. 현재 세션 컨텍스트 확인
SELECT CURRENT_ACCOUNT()  AS account
     , CURRENT_REGION()   AS region
     , CURRENT_ROLE()     AS role
     , CURRENT_USER()     AS user
     , CURRENT_VERSION()  AS version;
-- 기대: role = ACCOUNTADMIN (또는 동등 권한)

-- 0-2. Openflow Gen 2 활성화 여부 (가장 중요한 게이트)
SHOW OPENFLOW CONNECTOR DEFINITIONS;
-- ✅ 행이 반환되고 OPENFLOW_POSTGRES_CDC 가 보이면 통과.
-- ❌ "unexpected token" 등 SQL 컴파일 오류가 나면 이 계정은 Gen 2 미지원입니다.
--    → 실습 중단. Snowflake 계정 팀에 Gen 2 활성화를 요청하세요.

-- 0-3. Deployment 한도 확인 (계정당 Snowflake Deployment 최대 3개)
SHOW OPENFLOW DEPLOYMENTS;
-- 3개 미만이어야 신규 생성 가능합니다.

-- 0-5. ⚠️ 수동 확인 항목 (SQL로 확인 불가)
--   (a) Snowsight → Admin » Terms 에서 아래 약관에 동의했는지 확인
--         - Openflow Terms
--         - Snowflake Connector Terms
--   (b) Trial 계정인 경우: 공식 문서는 Openflow가 Trial 계정에서 자동
--       활성화되지 않는다고 명시합니다. STEP 0-2가 통과했더라도
--       03번 문서의 CREATE OPENFLOW DEPLOYMENT 가 권한 오류로 실패할 수
--       있습니다. 그 경우 계정 팀 문의가 필요합니다.


-- =============================================================
-- STEP 0-6. 사전 스냅샷 — 실습 전 상태 기록 (⚠️ 건너뛰지 마세요)
-- =============================================================
-- 이 실습의 목표 중 하나는 **실습 전후로 계정 상태가 동일한 것**입니다.
-- 정리(98번 문서) 후에 아래 결과와 대조해 원상복구를 증명합니다.
-- 모두 조회 전용이므로 계정을 변경하지 않습니다.
--
-- 👉 각 쿼리 결과를 캡처하거나 텍스트로 저장해 두세요.

-- (a) 접두사 충돌 검사 — 기존 객체를 덮어쓰지 않기 위해 반드시 확인
--     ⚠️ 결과가 하나라도 있으면 그 객체는 실습 대상이 아닙니다.
--        접두사를 바꾸거나(예: OPENFLOW_EDU2_) 기존 객체를 먼저 확인하세요.
--        기존 객체를 재사용하면 정리로 되돌릴 수 없습니다.
SHOW DATABASES  LIKE 'OPENFLOW_EDU_%';
SHOW DATABASES  LIKE 'CDC_LAB_%';
SHOW WAREHOUSES LIKE 'OPENFLOW_EDU_%';
SHOW ROLES      LIKE 'OPENFLOW_EDU_%';
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'PG_SOURCE_%';
-- 기대: 모두 0행

-- (b) Openflow 객체 사전 상태
SHOW OPENFLOW DEPLOYMENTS;              -- 기존 Deployment 수 (3개 한도)
SHOW OPENFLOW RUNTIMES   IN ACCOUNT;    -- 기존 Runtime (크레딧 소비 중인 것)
SHOW OPENFLOW CONNECTORS IN ACCOUNT;    -- 기존 커넥터

-- (c) 계정 레벨 객체 전체 목록 (정리 후 대조용)
SHOW DATABASES;
SHOW WAREHOUSES;
SHOW ROLES;
SHOW INTEGRATIONS;
SHOW COMPUTE POOLS;

-- (d) 🔴 사용자 속성 사전 값 — 가장 중요합니다
--     STEP 1-5 에서 이 사용자의 DEFAULT_SECONDARY_ROLES 를 변경합니다.
--     신규 객체가 아니므로 DROP 으로 되돌아가지 않습니다.
--     아래 출력의 DEFAULT_SECONDARY_ROLES / DEFAULT_ROLE 값을
--     반드시 기록해 두세요. 98번 문서 PART C-7 에서 이 값으로 원복합니다.
SET my_user = CURRENT_USER();
DESCRIBE USER IDENTIFIER($my_user);

SELECT PARSE_JSON(CURRENT_SECONDARY_ROLES()):value::string AS secondary_roles_before;

-- 기록 서식 (복사해서 값을 채워 두세요)
--   실습 전 DEFAULT_SECONDARY_ROLES = ______________
--   실습 전 DEFAULT_ROLE            = ______________
--   실습 전 Deployment 수            = ______________


-- =============================================================
-- STEP 0-7. 보조 Role 활성화 (세션 레벨 — 원복 불필요)
-- =============================================================
-- Openflow는 인증된 사용자의 모든 Role로 권한을 평가하므로 권장됩니다.
-- 세션 종료 시 자동으로 사라지므로 정리 대상이 아닙니다.
USE SECONDARY ROLES ALL;



-- =============================================================
-- STEP 1. Role 생성 — 최소 권한 원칙에 따라 3종 분리
-- =============================================================
USE ROLE ACCOUNTADMIN;

-- 1-1. Openflow 관리자 Role: Deployment / Runtime / 인프라 소유
CREATE ROLE IF NOT EXISTS OPENFLOW_EDU_ADMIN_RL
  COMMENT = 'Openflow 관리자 - Deployment/Runtime/인프라 소유. [openflow-edu]';

-- 1-2. 데이터 엔지니어 Role: 커넥터 생성 및 관리
CREATE ROLE IF NOT EXISTS OPENFLOW_EDU_DE_RL
  COMMENT = 'Openflow DE - 커넥터 생성/관리. [openflow-edu]';

-- 1-3. execute-as Role: 커넥터가 런타임에 실제로 사용하는 Role
CREATE ROLE IF NOT EXISTS OPENFLOW_EDU_EXECUTE_AS_RL
  COMMENT = 'Openflow execute-as - 커넥터 실행 컨텍스트. [openflow-edu]';

-- 1-4. Role 계층 구성 및 사용자 부여
GRANT ROLE OPENFLOW_EDU_ADMIN_RL      TO ROLE ACCOUNTADMIN;
GRANT ROLE OPENFLOW_EDU_DE_RL         TO ROLE OPENFLOW_EDU_ADMIN_RL;
GRANT ROLE OPENFLOW_EDU_EXECUTE_AS_RL TO ROLE OPENFLOW_EDU_ADMIN_RL;

-- 현재 사용자에게 부여 (CURRENT_USER() 값으로 치환하세요)
SET my_user = CURRENT_USER();
GRANT ROLE OPENFLOW_EDU_ADMIN_RL TO USER IDENTIFIER($my_user);
GRANT ROLE OPENFLOW_EDU_DE_RL    TO USER IDENTIFIER($my_user);

-- 1-5. 보조 Role 기본값을 ALL로 설정 (Openflow 권장/필수)
--      Openflow는 기본 Role만이 아니라 모든 Role로 작업을 인가합니다.
--
-- 🔴 이 구문은 신규 객체를 만드는 것이 아니라 **기존 사용자 객체의 속성을
--    영구히 변경**합니다. DROP 으로 되돌아가지 않는 유일한 항목입니다.
--    STEP 0-6 (d) 에서 실습 전 값을 기록했는지 확인하세요.
--    원복은 98번 문서 PART C-7 에서 수행합니다.
--
-- 💡 Snowflake 9.7 (BCR-1692) 이후 DEFAULT_SECONDARY_ROLES 의 기본값이
--    이미 ('ALL') 입니다. STEP 0-6 (d) 결과가 이미 ALL 이면 이 구문은
--    실질적으로 아무것도 바꾸지 않으므로 **건너뛰어도 됩니다** (권장).
--    그 경우 원복할 것도 없습니다.
ALTER USER IDENTIFIER($my_user) SET DEFAULT_SECONDARY_ROLES = ('ALL');

-- ⚠️ 참고: 기본 Role이 ACCOUNTADMIN인 사용자는 Openflow Runtime UI에
--    로그인할 수 없습니다. Runtime UI를 사용할 계획이라면 아래를 실행하세요.
--    이것도 사용자 속성 변경이므로 실습 전 DEFAULT_ROLE 값을 기록해 두고
--    98번 문서 PART C-7 에서 원복해야 합니다.
-- ALTER USER IDENTIFIER($my_user) SET DEFAULT_ROLE = OPENFLOW_EDU_ADMIN_RL;


-- =============================================================
-- STEP 2. 계정 레벨 권한 부여
-- =============================================================
USE ROLE ACCOUNTADMIN;

GRANT CREATE OPENFLOW DEPLOYMENT ON ACCOUNT TO ROLE OPENFLOW_EDU_ADMIN_RL;
GRANT CREATE DATABASE            ON ACCOUNT TO ROLE OPENFLOW_EDU_ADMIN_RL;
GRANT CREATE INTEGRATION         ON ACCOUNT TO ROLE OPENFLOW_EDU_ADMIN_RL;
-- Snowflake 배포(SPCS) 전용
GRANT CREATE COMPUTE POOL        ON ACCOUNT TO ROLE OPENFLOW_EDU_ADMIN_RL;

-- 검증
SHOW GRANTS TO ROLE OPENFLOW_EDU_ADMIN_RL;


-- =============================================================
-- STEP 3. 인프라(Control) DB / 스키마 생성
-- =============================================================
-- Runtime, Connector, Secret, Network Rule 이 여기 저장됩니다.
-- ⚠️ 데이터가 적재되는 대상 DB와는 반드시 분리합니다 (STEP 5 참고).
USE ROLE OPENFLOW_EDU_ADMIN_RL;

CREATE DATABASE IF NOT EXISTS OPENFLOW_EDU_DB
  COMMENT = 'Openflow 인프라(Control) DB. [openflow-edu]';

CREATE SCHEMA IF NOT EXISTS OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH
  COMMENT = 'Openflow 인프라 스키마 - Runtime/Connector/Secret/NetworkRule. [openflow-edu]';

-- 스키마 레벨 Openflow 객체 생성 권한
USE ROLE ACCOUNTADMIN;
GRANT CREATE OPENFLOW RUNTIME   ON SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH TO ROLE OPENFLOW_EDU_ADMIN_RL;
GRANT CREATE OPENFLOW CONNECTOR ON SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH TO ROLE OPENFLOW_EDU_ADMIN_RL;

-- DE Role: 커넥터와 Secret, (Snowsight config 편집용) Stage 생성 권한
GRANT USAGE                     ON DATABASE OPENFLOW_EDU_DB                TO ROLE OPENFLOW_EDU_DE_RL;
GRANT USAGE                     ON SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH TO ROLE OPENFLOW_EDU_DE_RL;
GRANT CREATE OPENFLOW CONNECTOR ON SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH TO ROLE OPENFLOW_EDU_DE_RL;
GRANT CREATE SECRET             ON SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH TO ROLE OPENFLOW_EDU_DE_RL;
GRANT CREATE STAGE              ON SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH TO ROLE OPENFLOW_EDU_DE_RL;

-- execute-as Role: 인프라 스키마 접근 (Secret 참조에 필요)
GRANT USAGE ON DATABASE OPENFLOW_EDU_DB                TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;
GRANT USAGE ON SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;

-- 검증
SHOW DATABASES LIKE 'OPENFLOW_EDU_DB';
SHOW SCHEMAS LIKE 'OPENFLOW_EDU_SCH' IN DATABASE OPENFLOW_EDU_DB;


-- =============================================================
-- STEP 4. Warehouse 생성
-- =============================================================
-- 커넥터가 대상 테이블에 MERGE 를 수행할 때 사용합니다.
USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS OPENFLOW_EDU_WH
  WITH WAREHOUSE_SIZE = 'XSMALL'
       AUTO_SUSPEND   = 60
       AUTO_RESUME    = TRUE
       INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Openflow CDC 실습용 Warehouse. [openflow-edu]';

-- ⚠️ OPERATE 필수: 커넥터가 suspend된 Warehouse를 스스로 재개해야 합니다.
--    USAGE 만 부여하면 자동 재개에 실패하고 MERGE 가 멈춥니다.
GRANT USAGE, OPERATE ON WAREHOUSE OPENFLOW_EDU_WH TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;
GRANT USAGE, OPERATE ON WAREHOUSE OPENFLOW_EDU_WH TO ROLE OPENFLOW_EDU_DE_RL;
GRANT USAGE, OPERATE ON WAREHOUSE OPENFLOW_EDU_WH TO ROLE OPENFLOW_EDU_ADMIN_RL;


-- =============================================================
-- STEP 5. 대상(Destination) DB 생성
-- =============================================================
-- 커넥터가 소스 스키마/테이블 이름으로 대상 스키마·테이블을 자동 생성합니다.
-- 그래서 반드시 전용 DB를 쓰고, 인프라 DB와 분리합니다.
USE ROLE OPENFLOW_EDU_ADMIN_RL;

CREATE DATABASE IF NOT EXISTS CDC_LAB_PG_DB
  COMMENT = 'PostgreSQL CDC 적재 대상 DB. [openflow-edu]';

USE ROLE ACCOUNTADMIN;

-- execute-as Role 이 스키마와 테이블을 만들 수 있어야 합니다.
GRANT USAGE         ON DATABASE CDC_LAB_PG_DB TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;
GRANT CREATE SCHEMA ON DATABASE CDC_LAB_PG_DB TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;

-- 검증용으로 DE / admin Role 에도 조회 권한 부여
GRANT USAGE                    ON DATABASE CDC_LAB_PG_DB           TO ROLE OPENFLOW_EDU_DE_RL;
GRANT USAGE                    ON ALL SCHEMAS IN DATABASE CDC_LAB_PG_DB    TO ROLE OPENFLOW_EDU_DE_RL;
GRANT USAGE                    ON FUTURE SCHEMAS IN DATABASE CDC_LAB_PG_DB TO ROLE OPENFLOW_EDU_DE_RL;
GRANT SELECT ON FUTURE TABLES  IN DATABASE CDC_LAB_PG_DB           TO ROLE OPENFLOW_EDU_DE_RL;
GRANT SELECT ON ALL TABLES     IN DATABASE CDC_LAB_PG_DB           TO ROLE OPENFLOW_EDU_DE_RL;

-- 검증
SHOW GRANTS TO ROLE OPENFLOW_EDU_EXECUTE_AS_RL;
-- 확인 항목:
--   USAGE  on DATABASE OPENFLOW_EDU_DB
--   USAGE  on SCHEMA   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH
--   USAGE  on DATABASE CDC_LAB_PG_DB
--   CREATE SCHEMA on DATABASE CDC_LAB_PG_DB
--   USAGE, OPERATE on WAREHOUSE OPENFLOW_EDU_WH


-- =============================================================
-- STEP 6. Event Table 생성 (권장)
-- =============================================================
-- Openflow 로그/메트릭 저장소. 기본값은 계정 Event Table
-- (SNOWFLAKE.TELEMETRY.EVENTS) 이지만, 전용 테이블을 두면 조회 성능과
-- 권한 관리가 유리하고 트러블슈팅이 쉬워집니다.
USE ROLE OPENFLOW_EDU_ADMIN_RL;

CREATE EVENT TABLE IF NOT EXISTS OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.EVENTS
  COMMENT = 'Openflow 런타임 로그/메트릭. [openflow-edu]';

-- ⚠️ Deployment 에 이 Event Table 을 연결하는 작업은 Deployment 생성 후에
--    가능합니다. 03번 문서 STEP 4에서 수행합니다.

-- 검증
SHOW EVENT TABLES LIKE 'EVENTS' IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;


-- =============================================================
-- ✅ 완료 체크리스트
-- =============================================================
-- [ ] STEP 0-2 에서 OPENFLOW_POSTGRES_CDC 가 조회되었다
-- [ ] Snowsight Admin » Terms 에서 Openflow / Connector 약관에 동의했다
-- [ ] Role 3종이 생성되고 사용자에게 부여되었다
-- [ ] DEFAULT_SECONDARY_ROLES = ALL 로 설정되었다
-- [ ] OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH 가 존재한다
-- [ ] OPENFLOW_EDU_WH 에 USAGE + OPERATE 가 부여되었다
-- [ ] CDC_LAB_PG_DB 가 존재하고 execute-as Role 이 CREATE SCHEMA 권한을 가진다
-- [ ] Event Table 이 생성되었다
--
-- 다음 문서: 03_openflow_배포_및_런타임_생성.sql


-- =============================================================
-- 🧹 리소스 정리 (실습 종료 후에만 실행 — 주석 해제 필요)
-- =============================================================
-- ⚠️ 정본은 98_리소스정리.sql 입니다. 전체 정리는 그 문서를 따르세요.
--    아래는 **이 문서까지만 진행하고 중단한 경우** 되돌리기 위한 것입니다.
--    (03번 이후를 진행했다면 반드시 98번 문서의 순서를 따라야 합니다 —
--     커넥터 → Runtime → Deployment → 인프라)
--
-- USE ROLE ACCOUNTADMIN;
-- DROP DATABASE  IF EXISTS CDC_LAB_PG_DB;
-- DROP DATABASE  IF EXISTS OPENFLOW_EDU_DB;   -- Runtime/Connector 삭제 후에만 성공
-- DROP WAREHOUSE IF EXISTS OPENFLOW_EDU_WH;
-- DROP ROLE      IF EXISTS OPENFLOW_EDU_EXECUTE_AS_RL;
-- DROP ROLE      IF EXISTS OPENFLOW_EDU_DE_RL;
-- DROP ROLE      IF EXISTS OPENFLOW_EDU_ADMIN_RL;
--
-- 🔴 사용자 속성 원복도 잊지 마세요 (DROP 으로 되돌아가지 않습니다).
--    STEP 0-6 (d) 에 기록한 실습 전 값에 따라 분기합니다.
--    실습 전이 ('ALL') 이었다면 → 할 일 없음
--    실습 전이 비어 있었다면    → ALTER USER IDENTIFIER($my_user) UNSET DEFAULT_SECONDARY_ROLES;
--    자세한 절차는 98_리소스정리.sql PART C-7 참고.
