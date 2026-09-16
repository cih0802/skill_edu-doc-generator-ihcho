/*
title: 리소스 정리 (전체 원상복구)
step: 98
type: sql
summary: 실습에서 만든 모든 Snowflake 객체와 외부(소스 DB) 리소스를 역순으로 삭제해 실습 전 상태로 되돌린다. 비용 경고, 일시 중단 선택지, 상태 전이 절차, 원복 항목, 완료 검증 쿼리, 체크리스트를 포함한다.
requires: 09_적재결과_검증.sql
next: 없음 (마지막 문서)
*/

-- =============================================================
-- 98. 리소스 정리 — 실습 전 상태로 되돌리기
-- =============================================================
-- 실행 위치 : Snowflake (Snowsight 워크시트) + 소스 DB (PART D)
-- 필요 권한 : ACCOUNTADMIN (+ OPENFLOW_EDU_ADMIN_RL / OPENFLOW_EDU_DE_RL)
-- 대응 문서 : 01_교육자료_정리본.md 의 "객체 대장" 이 이 문서의 계약서입니다.
--             대장의 모든 행이 이 문서에서 삭제 또는 원복되어야 합니다.
--
-- 검증 상태 : ⚠️ 이 문서의 DROP/ALTER 구문은 대상 객체가 계정에 존재하지
--             않으므로 실제 실행 검증을 하지 못했습니다. 문법은 공식 문서
--             (DROP OPENFLOW RUNTIME / ALTER OPENFLOW RUNTIME /
--              ALTER OPENFLOW CONNECTOR / ALTER USER) 로 대조 확인했습니다.
--             ✅ ALTER USER ... UNSET DEFAULT_SECONDARY_ROLES — 공식 문서 확인 완료.
-- =============================================================


-- =============================================================
-- ⚠️⚠️ 0. 가장 먼저 읽으세요 — 비용 경고
-- =============================================================
--
--   지금 크레딧을 소비하고 있는 것은 다음 둘입니다.
--
--     ① OPENFLOW RUNTIME  — 자동 suspend 되지 않습니다. 계속 과금됩니다.
--     ② OPENFLOW_EDU_WH   — AUTO_SUSPEND=60 이므로 유휴 시 과금은 미미합니다.
--
--   OPENFLOW DEPLOYMENT 자체에는 별도 과금이 없습니다.
--   → 비용만 급히 멈추려면 PART A(일시 중단)만 수행하면 됩니다.
--
--   Snowflake 밖에서 계속 누적되는 것도 있습니다.
--
--     ③ 소스 PostgreSQL 의 복제 슬롯 — 비활성 상태로 방치하면 WAL 이
--        무한히 축적되어 소스 디스크를 채웁니다. PART D 를 반드시 수행하세요.
--
-- =============================================================
-- ⚠️ 이 문서의 모든 삭제 구문은 주석 처리되어 있습니다.
--    실행하려면 해당 블록의 주석을 해제하세요. 의도치 않은 삭제를 막기 위한
--    안전장치입니다.
-- =============================================================


-- =============================================================
-- PART A. 선택 1 — 일시 중단 (실습을 이어서 할 예정)
-- =============================================================
-- 삭제하지 않고 크레딧 소비만 멈춥니다. 커넥터 설정과 적재 데이터가
-- 그대로 남으므로 나중에 RESUME 해서 이어갈 수 있습니다.
--
-- ⚠️ 단, 소스 PostgreSQL 의 복제 슬롯은 살아 있습니다. 중단 기간이 길어지면
--    WAL 이 축적되어 소스 디스크를 채웁니다. 며칠 이상 중단할 예정이라면
--    PART B 이후의 완전 삭제를 택하는 편이 안전합니다.

-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
--
-- -- (a) 커넥터를 먼저 정지 (전이 상태에서는 다음 명령이 거부됩니다)
-- ALTER OPENFLOW CONNECTOR
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR STOP;
-- SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'STOPPED',
--   'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');
--
-- -- (b) Runtime 일시 중단 (OPERATE 권한 필요) — 여기서 크레딧이 멈춥니다
-- ALTER OPENFLOW RUNTIME
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME SUSPEND;
--
-- -- (c) 나중에 재개할 때
-- -- ALTER OPENFLOW RUNTIME
-- --   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME RESUME;

-- 여기까지만 하고 문서를 닫아도 됩니다. 완전 삭제는 PART B 부터입니다.


-- =============================================================
-- PART B. 선택 2 — 완전 삭제: 순서
-- =============================================================
--
--   ① 커넥터        STOP → TERMINATE → DROP
--   ② Runtime 에서 EAI 연결 해제
--   ③ Runtime       SUSPEND → TERMINATE → DROP   ← DROP 만으로는 안 됩니다
--   ④ Deployment    DROP
--   ⑤ 계정/스키마 레벨 부속 객체  EAI, Network Rule, Secret, Stage
--   ⑥ Database / Warehouse
--   ⑦ Role (가장 마지막 — 앞 단계 실행에 이 Role 들이 필요합니다)
--   ⑧ 사용자 속성 원복 (DEFAULT_SECONDARY_ROLES)
--   ⑨ 외부 리소스 (소스 DB) — PART D
--
-- 순서를 지키지 않으면 상위 객체 삭제가 실패합니다.
-- 예) 커넥터가 남아 있으면 Runtime TERMINATE 실패
--     Runtime 이 남아 있으면 Deployment DROP 및 OPENFLOW_EDU_DB DROP 실패
--
-- 💡 단축 경로: ALTER OPENFLOW RUNTIME <name> TERMINATE CASCADE 는 Runtime
--    안의 커넥터를 먼저 모두 terminate 한 뒤 Runtime 을 terminate 합니다.
--    ①을 건너뛸 수 있습니다. 단, 부모 Deployment 가 ACTIVE 가 아니거나
--    커넥터가 전이 상태(STARTING/STOPPING 등)이면 실패합니다.
--
-- ⚠️ 상태 전이 제약: OPENFLOW RUNTIME 이 CREATING / CREATE_FAILED /
--    TERMINATING / TERMINATED 상태이면 ALTER 가 거부됩니다.
--    SHOW OPENFLOW RUNTIMES IN ACCOUNT 로 상태를 먼저 확인하세요.


-- =============================================================
-- PART C-0. 삭제 전 — 무엇을 보존할지 결정
-- =============================================================
-- 적재된 CDC 결과를 남기고 싶다면 대상 DB 만 보존할 수 있습니다.
--
--   CDC_LAB_PG_DB   → 보존 가능. 스토리지 비용만 발생 (컴퓨트 없음)
--   OPENFLOW_EDU_DB → 보존 권장하지 않음. Runtime/Connector 의 컨테이너이며
--                     Event Table 이 계속 쌓입니다
--   OPENFLOW_EDU_WH → 보존해도 AUTO_SUSPEND=60 이므로 유휴 비용은 미미하나,
--                     실습 전 상태 복구를 원하면 삭제하세요
--
-- 보존하려면 아래 PART C-6 의 해당 DROP 문을 주석 처리된 채로 두세요.

-- 삭제 대상 확인 (광범위 삭제 전 필수) --------------------------
USE ROLE ACCOUNTADMIN;

SHOW OPENFLOW CONNECTORS IN ACCOUNT;
SHOW OPENFLOW RUNTIMES   IN ACCOUNT;
SHOW OPENFLOW DEPLOYMENTS;
SHOW DATABASES  LIKE 'OPENFLOW_EDU_%';
SHOW DATABASES  LIKE 'CDC_LAB_%';
SHOW WAREHOUSES LIKE 'OPENFLOW_EDU_%';
SHOW ROLES      LIKE 'OPENFLOW_EDU_%';
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'PG_SOURCE_%';
-- 위 결과에 실습 객체만 있는지 확인하세요.
-- ⚠️ 실습과 무관한 객체가 접두사에 걸리면 아래 구문을 실행하지 마세요.


-- =============================================================
-- PART C-1. ① 커넥터 정리
-- =============================================================
-- USE ROLE OPENFLOW_EDU_DE_RL;
--
-- ALTER OPENFLOW CONNECTOR
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR STOP;
-- SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'STOPPED',
--   'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');
--
-- ALTER OPENFLOW CONNECTOR
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR TERMINATE;
-- SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'DELETED',
--   'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');
--
-- DROP OPENFLOW CONNECTOR IF EXISTS
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR;
--
-- SHOW OPENFLOW CONNECTORS IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;

-- 💡 TERMINATE 는 DELETED 상태로 보내고, DROP 이 객체 자체를 제거합니다.
--    Openflow UI 의 Delete = TERMINATE, Drop = DROP 입니다.
-- ❗ 실패 시 확인: 커넥터가 STARTING/STOPPING 등 전이 상태이면 명령이
--    거부됩니다. WAIT 함수로 안정 상태를 확인한 뒤 재시도하세요.


-- =============================================================
-- PART C-2. ②③ Runtime 정리 — DROP 만으로는 삭제되지 않습니다
-- =============================================================
-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
--
-- -- (a) EAI 연결 해제 — EAI 를 삭제하려면 먼저 해야 합니다
-- ALTER OPENFLOW RUNTIME
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME
--   UNSET EXTERNAL_ACCESS_INTEGRATIONS;
--
-- -- (b) 일시 중단 (OPERATE 필요)
-- ALTER OPENFLOW RUNTIME
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME SUSPEND;
--
-- -- (c) terminate (OWNERSHIP 필요)
-- ALTER OPENFLOW RUNTIME
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME TERMINATE;
--
-- -- 커넥터를 함께 정리하는 단축 경로 (PART C-1 을 건너뛴 경우):
-- -- ALTER OPENFLOW RUNTIME
-- --   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME TERMINATE CASCADE;
--
-- -- (d) 객체 제거
-- DROP OPENFLOW RUNTIME IF EXISTS
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_EDU_RUNTIME;
--
-- -- 확인 — 여기서 크레딧 소비가 완전히 멈춥니다
-- SHOW OPENFLOW RUNTIMES IN ACCOUNT;

-- ❗ 실패 시 확인: (c) TERMINATE 가 실패하면 커넥터가 아직 남아 있습니다.
--    SHOW OPENFLOW CONNECTORS IN SCHEMA ... 로 확인하고 PART C-1 을
--    먼저 완료하거나 TERMINATE CASCADE 를 사용하세요.


-- =============================================================
-- PART C-3. ④ Deployment 정리
-- =============================================================
-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
--
-- DROP OPENFLOW DEPLOYMENT IF EXISTS OPENFLOW_EDU_DEPLOYMENT;
--
-- SHOW OPENFLOW DEPLOYMENTS;

-- ❗ 실패 시 확인: Runtime 이 아직 완전히 제거되지 않은 것입니다.
--    SHOW OPENFLOW RUNTIMES IN ACCOUNT 로 확인하세요.


-- =============================================================
-- PART C-4. ⑤ EAI / Network Rule / Secret / Stage 정리
-- =============================================================
-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
--
-- -- EAI 는 계정 레벨 객체입니다. 놓치면 계정에 영구히 남습니다.
-- DROP INTEGRATION  IF EXISTS PG_SOURCE_EAI;
-- DROP NETWORK RULE IF EXISTS OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_NETWORK_RULE;
-- DROP SECRET       IF EXISTS OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET;
--
-- -- config.json 편집용 스테이지 (07번 문서에서 생성)
-- DROP STAGE IF EXISTS
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_CONFIG_STAGE_OPENFLOW_EDU_DE_RL;

-- ❗ 실패 시 확인: DROP INTEGRATION 이 실패하면 Runtime 이 아직 EAI 를
--    참조하고 있습니다. PART C-2 (a) 를 먼저 수행하세요.
-- 💡 위 스키마 레벨 객체(Network Rule / Secret / Stage)는 PART C-5 에서
--    OPENFLOW_EDU_DB 를 DROP 하면 함께 사라집니다. 명시적으로 적어 둔 것은
--    DB 를 보존하기로 선택한 경우를 위한 것입니다.


-- =============================================================
-- PART C-5. ⑥ Database / Warehouse 정리
-- =============================================================
-- USE ROLE ACCOUNTADMIN;
--
-- -- 적재 결과를 보존하려면 아래 한 줄을 주석 처리된 채로 두세요.
-- DROP DATABASE  IF EXISTS CDC_LAB_PG_DB;
--
-- -- Runtime / Connector 가 모두 삭제된 뒤에만 성공합니다.
-- DROP DATABASE  IF EXISTS OPENFLOW_EDU_DB;
--
-- DROP WAREHOUSE IF EXISTS OPENFLOW_EDU_WH;

-- ⚠️ 계정 기본 객체(COMPUTE_WH, SNOWFLAKE DB, PUBLIC 등)는 절대
--    삭제하지 마세요. 위 구문에는 포함되어 있지 않습니다.


-- =============================================================
-- PART C-6. ⑦ Role 정리 (가장 마지막)
-- =============================================================
-- 앞 단계들이 이 Role 들의 권한으로 실행되므로 반드시 마지막에 삭제합니다.
--
-- USE ROLE ACCOUNTADMIN;
--
-- DROP ROLE IF EXISTS OPENFLOW_EDU_EXECUTE_AS_RL;
-- DROP ROLE IF EXISTS OPENFLOW_EDU_DE_RL;
-- DROP ROLE IF EXISTS OPENFLOW_EDU_ADMIN_RL;

-- 💡 Role 을 DROP 하면 그 Role 에 부여된 그랜트와, 그 Role 을 사용자·
--    상위 Role 에 부여한 그랜트도 함께 사라집니다. 별도 REVOKE 는 불필요합니다.


-- =============================================================
-- PART C-7. ⑧ 사용자 속성 원복 (삭제가 아니라 원복)
-- =============================================================
-- ⚠️ 02번 문서 STEP 1-5 는 신규 객체를 만든 것이 아니라
--    **기존 사용자 객체의 속성을 변경**했습니다. 삭제로는 되돌아가지 않으므로
--    이 절에서 명시적으로 원복합니다. 이것이 왕복 가능성의 마지막 조각입니다.
--
--   변경된 속성 : DEFAULT_SECONDARY_ROLES = ('ALL')
--   원복 방법   : 02번 STEP 0-6 에서 기록해 둔 실습 전 값에 따라 분기
--
-- 현재 값 확인:
SET my_user = CURRENT_USER();
DESCRIBE USER IDENTIFIER($my_user);
-- 출력에서 DEFAULT_SECONDARY_ROLES 행의 value 를 확인하세요.

-- ── 경우 1) 실습 전에도 ('ALL') 이었다 → 원복할 것이 없습니다.
--    Snowflake 9.7(BCR-1692) 이후 DEFAULT_SECONDARY_ROLES 의 기본값이
--    ('ALL') 이므로, 대부분의 계정에서 이 경우에 해당합니다.
--    아무것도 실행하지 마세요.

-- ── 경우 2) 실습 전이 비어 있었다 / NULL 이었다 → 기본값으로 되돌립니다.
-- ALTER USER IDENTIFIER($my_user) UNSET DEFAULT_SECONDARY_ROLES;

-- ── 경우 3) 실습 전이 명시적으로 빈 목록 () 이었다 → 그 값으로 복원합니다.
-- ALTER USER IDENTIFIER($my_user) SET DEFAULT_SECONDARY_ROLES = ();

-- 참고: 02번 STEP 1 의 아래 두 구문은 주석 처리된 채 제공되었으므로
--       실행했을 때만 원복이 필요합니다.
--   ALTER USER ... SET DEFAULT_ROLE = OPENFLOW_EDU_ADMIN_RL;
--     → 원복: ALTER USER IDENTIFIER($my_user) SET DEFAULT_ROLE = <실습 전 값>;
--       (실습 전 값은 02번 STEP 0-6 스냅샷의 DESCRIBE USER 결과에 있습니다)
--
-- 세션 레벨 변경(USE SECONDARY ROLES ALL)은 세션 종료 시 자동으로
-- 사라지므로 원복이 필요하지 않습니다.


-- =============================================================
-- PART D. ⑨ 외부 리소스 정리 — 소스 DB (매우 중요)
-- =============================================================
-- ⚠️ 아래는 Snowflake 가 아니라 **소스 DB 에서** 실행합니다 (psql / mysql).
--    Snowsight 워크시트에서 실행하면 문법 오류가 납니다.

/* ---------- D-1. PostgreSQL 소스 (04번 문서에서 설정한 것) ----------

-- (a) 복제 슬롯 — 가장 중요합니다. 비활성 슬롯은 WAL 을 무한 축적합니다.
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;

-- active = f 인 것만 삭제하세요 (active = t 이면 커넥터가 아직 살아 있습니다)
SELECT pg_drop_replication_slot('<slot_name>');

-- (b) PUBLICATION
DROP PUBLICATION IF EXISTS openflow_pub;

-- (c) 실습 테이블 (외래 참조 순서상 orders 를 먼저)
DROP TABLE IF EXISTS public.orders;
DROP TABLE IF EXISTS public.customers;

-- (d) 복제 사용자
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM openflow_repl;
REVOKE ALL ON SCHEMA public              FROM openflow_repl;
DROP USER IF EXISTS openflow_repl;

-- (e) 설정 변경 원복 — ⚠️ 인스턴스 재시작이 필요합니다
--     실습 전 값이 'replica' 였는지 04번 STEP 1 에서 확인한 값으로 되돌리세요.
ALTER SYSTEM SET wal_level = 'replica';
--   RDS      : 파라미터 그룹의 rds.logical_replication = 0 으로 되돌린 뒤 재부팅
--   Cloud SQL: cloudsql.logical_decoding = off 로 되돌린 뒤 재시작
--   pg_hba.conf 에 추가한 openflow_repl 항목과 listen_addresses 변경도
--   원복하세요.

-- (f) 확인 — 결과가 비어 있어야 합니다
SELECT * FROM pg_replication_slots;
SELECT * FROM pg_publication;
SELECT usename FROM pg_user WHERE usename = 'openflow_repl';

------------------------------------------------------------------- */

/* ---------- D-2. MySQL 소스 (10번 문서 경로를 택한 경우) ----------

-- (a) 복제 사용자
DROP USER IF EXISTS 'openflow_repl'@'%';

-- (b) 실습 스키마
DROP DATABASE IF EXISTS cdclab;

-- (c) 설정 변경 원복 — my.cnf / 파라미터 그룹에서 되돌린 뒤 재시작
--     log_bin, binlog_format, binlog_row_metadata, binlog_row_image,
--     binlog_row_value_options, binlog_expire_logs_seconds,
--     sort_buffer_size, log_replica_updates, server-id
--     (MariaDB) binlog_legacy_event_pos
--     실습 전 값은 10번 문서 2장의 확인 쿼리로 기록해 둔 값을 사용하세요.

-- (d) 확인
SELECT user, host FROM mysql.user WHERE user = 'openflow_repl';
SHOW DATABASES LIKE 'cdclab';

------------------------------------------------------------------- */


-- =============================================================
-- PART E. 정리 완료 검증 — "삭제했다" 가 아니라 "없음을 확인했다"
-- =============================================================
-- 02번 문서 STEP 0-6 의 사전 스냅샷과 대조해 차이가 없어야 합니다.

USE ROLE ACCOUNTADMIN;

SHOW OPENFLOW CONNECTORS IN ACCOUNT;      -- 실습 커넥터 없음
SHOW OPENFLOW RUNTIMES   IN ACCOUNT;      -- 실습 Runtime 없음 ← 크레딧 소비 중단
SHOW OPENFLOW DEPLOYMENTS;                -- 실습 Deployment 없음

SHOW DATABASES  LIKE 'OPENFLOW_EDU_%';    -- 결과 없음
SHOW DATABASES  LIKE 'CDC_LAB_%';         -- 결과 없음 (보존 선택 시 남아 있어도 정상)
SHOW WAREHOUSES LIKE 'OPENFLOW_EDU_%';    -- 결과 없음
SHOW ROLES      LIKE 'OPENFLOW_EDU_%';    -- 결과 없음

SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'PG_SOURCE_%';  -- 결과 없음
SHOW INTEGRATIONS;                        -- 실습 객체 없음

-- 스키마 레벨 잔여물 (OPENFLOW_EDU_DB 를 보존한 경우에만 의미가 있습니다)
-- SHOW SECRETS       IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;
-- SHOW NETWORK RULES IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;
-- SHOW STAGES        IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;

-- COMMENT 태그로 잔여물 일괄 검색 (모든 실습 객체에 [openflow-edu] 를 넣었습니다)
--
-- (i) Database / Role — ACCOUNT_USAGE 뷰 사용
--     ✅ 이 계정에서 실행 검증 완료 (0행 = 잔여물 없음)
SELECT 'DATABASE' AS kind, database_name AS name, comment
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES
WHERE deleted IS NULL AND comment ILIKE '%[openflow-edu]%'
UNION ALL
SELECT 'ROLE', name, comment
FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
WHERE deleted_on IS NULL AND comment ILIKE '%[openflow-edu]%';
-- 결과 없음이어야 합니다.
-- ⚠️ ACCOUNT_USAGE 뷰는 최대 2~3시간 지연됩니다. 즉시 확인은 위 SHOW 문으로 하세요.
--    (정리 직후에는 이미 삭제한 객체가 아직 보일 수 있습니다.)

-- (ii) Warehouse — SHOW + RESULT_SCAN 사용
--      ⚠️ SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSES 는 모든 계정/에디션에서
--         제공되지 않습니다(이 계정에서는 존재하지 않음을 확인했습니다).
--         그래서 SHOW 결과를 RESULT_SCAN 으로 필터링합니다.
--      ✅ 이 계정에서 실행 검증 완료
--      아래 두 문장은 반드시 연속 실행하세요 (LAST_QUERY_ID 의존).
SHOW WAREHOUSES;
SELECT "name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[openflow-edu]%';
-- 결과 없음이어야 합니다.

-- 사용자 속성 원복 확인
SET my_user = CURRENT_USER();
DESCRIBE USER IDENTIFIER($my_user);
-- DEFAULT_SECONDARY_ROLES / DEFAULT_ROLE 이 실습 전 값과 같은지 확인


-- =============================================================
-- PART F. 정리 체크리스트
-- =============================================================
-- Snowflake
-- [ ] 커넥터 PG_CDC_CONNECTOR — TERMINATE + DROP 완료
-- [ ] **Runtime OPENFLOW_EDU_RUNTIME — TERMINATE + DROP 완료 (크레딧 소비 중단)**
-- [ ] Deployment OPENFLOW_EDU_DEPLOYMENT — DROP 완료
-- [ ] EAI PG_SOURCE_EAI — DROP 완료 (계정 레벨: 놓치면 영구 잔존)
-- [ ] Network Rule / Secret / Stage — DROP 완료
-- [ ] Event Table EVENTS — OPENFLOW_EDU_DB DROP 으로 함께 제거됨
-- [ ] Database OPENFLOW_EDU_DB — DROP 완료
-- [ ] Database CDC_LAB_PG_DB — DROP 완료 (또는 의도적으로 보존)
-- [ ] **Warehouse OPENFLOW_EDU_WH — DROP 완료 (컴퓨트 비용)**
-- [ ] Role 3종 — DROP 완료
-- [ ] 사용자 DEFAULT_SECONDARY_ROLES — 실습 전 값으로 원복 확인
--
-- 외부 (소스 DB)
-- [ ] **복제 슬롯 삭제 완료 (WAL 축적 방지 — 소스 디스크)**
-- [ ] PUBLICATION openflow_pub 삭제 완료
-- [ ] 실습 테이블 customers / orders 삭제 완료
-- [ ] 복제 사용자 openflow_repl 삭제 완료
-- [ ] wal_level (또는 binlog 파라미터) 원복 + 재시작 완료
-- [ ] pg_hba.conf / listen_addresses 원복 완료
--
-- 검증
-- [ ] PART E 의 모든 쿼리를 실행해 잔여 객체가 없음을 확인
-- [ ] 02번 STEP 0-6 사전 스냅샷과 대조해 차이 없음을 확인
--
-- 대조 기준: 01_교육자료_정리본.md 의 "객체 대장" 전 행이 위에서 처리되었는가?
