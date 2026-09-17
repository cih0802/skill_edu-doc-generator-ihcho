/*
title: 리소스 정리 (전체 원상복구)
step: 98
type: sql
summary: 실습에서 만든 모든 Snowflake 객체와 외부(소스 DB) 리소스를 역순으로 삭제해 실습 전 상태로 되돌린다. 비용 경고, 일시 중단 선택지, 상태 전이 절차, 원복 항목, 완료 검증 쿼리, 체크리스트를 포함한다.
requires: 09_적재결과_검증.sql
next: 96_실습후_대조.md
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
--   ④ Deployment    TERMINATE → DROP   ← DROP 만으로는 안 됩니다 (비가역)
--   ⑤ 계정/스키마 레벨 부속 객체  EAI, Network Rule, Secret, Stage
--   ⑥ Database / Warehouse
--   ⑦ Role (가장 마지막 — 앞 단계 실행에 이 Role 들이 필요합니다)
--   ⑧ 사용자 속성 원복 (DEFAULT_SECONDARY_ROLES)
--   ⑨ 외부 리소스 (소스 DB) — PART D
--
-- 순서를 지키지 않으면 상위 객체 삭제가 실패합니다.
-- 예) 커넥터가 남아 있으면 Runtime TERMINATE 실패
--     Runtime 이 남아 있으면 Deployment TERMINATE 및 OPENFLOW_EDU_DB DROP 실패
--     Deployment 가 ACTIVE 이면 Deployment DROP 실패
--
-- 💡 단축 경로: ALTER OPENFLOW RUNTIME <name> TERMINATE CASCADE 는 Runtime
--    안의 커넥터를 먼저 모두 terminate 한 뒤 Runtime 을 terminate 합니다.
--    ①을 건너뛸 수 있습니다. 단, 부모 Deployment 가 ACTIVE 가 아니거나
--    커넥터가 전이 상태(STARTING/STOPPING 등)이면 실패합니다.
--
-- ⚠️ 상태 전이 제약: OPENFLOW RUNTIME 이 CREATING / CREATE_FAILED /
--    TERMINATING / TERMINATED 상태이면 ALTER 가 거부됩니다.
--    SHOW OPENFLOW RUNTIMES IN ACCOUNT 로 상태를 먼저 확인하세요.
--
-- 🔴 재실행 안전성 — 정리 문서는 두 번 실행된다고 전제하십시오
--    커넥터·Runtime·Network Rule·Secret·Stage 구문은 모두
--    `OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.` 로 정규화되어 있습니다.
--    ⑥ 에서 그 데이터베이스를 DROP 한 뒤 이 문서를 처음부터 다시 실행하면
--    **`IF EXISTS` 에도 불구하고** 상위 DB 부재로 실패합니다.
--
--    실측 근거(2026-09-17, EDU-02 자료에서 같은 구조를 2회 실행해 확인):
--      DROP DATABASE 이후 `ALTER TASK IF EXISTS <DB>.<SCH>.<OBJ> SUSPEND` 가
--      "Database '<DB>' does not exist or not authorized." 로 실패했습니다.
--      `IF EXISTS` 는 **그 객체 자체**의 부재만 처리하며, 상위 컨테이너가
--      없으면 객체 존재를 보기 전에 **이름 해석 단계에서** 실패합니다.
--
-- 🔴 2026-09-17 정정 — 산문 안내에서 **방어 블록 코드**로 바꿨습니다
--    이전 판은 "이미 끝난 절을 건너뛰십시오" 라는 안내만 두었습니다.
--    안내는 스크립트로 일괄 실행하는 사용자를 보호하지 못하므로,
--    아래 PART C-1 / C-2 / C-4 에 **상위 DB 존재 확인 블록**을 넣었습니다.
--    DB 가 이미 없으면 각 절이 '건너뜁니다' 를 반환하고 정상 종료합니다.
--
--    이 결함은 이 자료의 8차 검토 이력에 이미 기록되어 있었으나
--    **조치되지 않은 상태로 남아 있었습니다.** 이번에 실제로 고쳤습니다.
--
-- 💡 검증 방법: 실습을 완주해 정리를 수행했다면 **곧바로 한 번 더 실행**해
--    2회차가 오류 없이 끝나는지 확인하십시오. 1회 성공은 재실행 안전성의
--    근거가 아닙니다.


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
-- 🔴 아래 구문은 모두 `OPENFLOW_EDU_DB.` 로 시작하는 정규화된 이름입니다.
--    2회차 실행(= DB 를 이미 지운 뒤)을 위해 방어 블록으로 감쌌습니다.
--    DB 가 없으면 '건너뜁니다' 를 반환하고 정상 종료합니다.
--
-- USE ROLE OPENFLOW_EDU_DE_RL;
--
-- EXECUTE IMMEDIATE $$
-- DECLARE
--     v_db_count INTEGER;
--     rs RESULTSET;
-- BEGIN
--     -- ACCOUNT_USAGE / INFORMATION_SCHEMA 뷰 존재를 가정하지 않고 SHOW 로 확인합니다
--     rs := (SHOW DATABASES LIKE 'OPENFLOW_EDU_DB');
--     SELECT COUNT(*) INTO v_db_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--
--     IF (v_db_count = 0) THEN
--         RETURN 'OPENFLOW_EDU_DB 가 이미 없습니다. 커넥터 정리 절을 건너뜁니다.';
--     END IF;
--
--     ALTER OPENFLOW CONNECTOR
--       OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR STOP;
--     SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'STOPPED',
--       'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');
--
--     ALTER OPENFLOW CONNECTOR
--       OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR TERMINATE;
--     SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'DELETED',
--       'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');
--
--     DROP OPENFLOW CONNECTOR IF EXISTS
--       OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR;
--
--     RETURN '커넥터 정리 완료';
-- END;
-- $$;
--
-- -- 정리 확인 (DB 가 있을 때만 의미가 있습니다)
-- SHOW OPENFLOW CONNECTORS IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;

-- 💡 TERMINATE 는 DELETED 상태로 보내고, DROP 이 객체 자체를 제거합니다.
--    Openflow UI 의 Delete = TERMINATE, Drop = DROP 입니다.
-- ❗ 실패 시 확인: 커넥터가 STARTING/STOPPING 등 전이 상태이면 명령이
--    거부됩니다. WAIT 함수로 안정 상태를 확인한 뒤 재시도하세요.
-- ⚠️ 미검증: 이 블록의 커넥터 구문은 트라이얼 계정에서 커넥터를 만들 수
--    없어(05_ EAI 차단) 실행 검증되지 않았습니다. 방어 블록의 골격
--    (SHOW DATABASES → RESULT_SCAN → 조건 반환)은 EDU-02 에서 DB 부재
--    상태로 실제 실행해 '건너뜁니다' 반환을 확인했습니다.


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
-- PART C-3. ④ Deployment 정리 — TERMINATE → DROP (2단계)
-- =============================================================
-- 🔴 Deployment 도 Runtime 과 같이 **DROP 만으로는 제거되지 않습니다.**
--    ACTIVE 상태에서 DROP 을 실행하면 다음 오류로 거부됩니다.
--      DROP not allowed while OPENFLOW DEPLOYMENT <name> is in ACTIVE status.
--    → 2026-09-16 실행 검증에서 실제로 재현했습니다.
--    공식 문서(ALTER OPENFLOW DEPLOYMENT)도 "The deployment must be terminated
--    before it can be dropped" 로 명시합니다. TERMINATE 는 **되돌릴 수 없습니다.**
--
-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
--
-- -- (a) 종료 — 비가역
-- ALTER OPENFLOW DEPLOYMENT OPENFLOW_EDU_DEPLOYMENT TERMINATE;
--
-- -- (b) TERMINATED 상태 도달 대기
-- SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_DEPLOYMENTS(900, 'OPENFLOW_EDU_DEPLOYMENT');
-- SHOW OPENFLOW DEPLOYMENTS;
-- --   status = ______   (TERMINATED 를 확인한 뒤 (c) 로 갑니다)
--
-- -- (c) 레코드 제거
-- DROP OPENFLOW DEPLOYMENT IF EXISTS OPENFLOW_EDU_DEPLOYMENT;
--
-- SHOW OPENFLOW DEPLOYMENTS;
-- --   OPENFLOW_EDU_DEPLOYMENT 가 사라져야 합니다

-- ❗ 실패 시 확인:
--    (a) TERMINATE 가 실패하면 Runtime 이 아직 남아 있습니다.
--        SHOW OPENFLOW RUNTIMES IN ACCOUNT 로 확인하세요.
--    (c) DROP 이 ACTIVE 오류로 거부되면 (a)·(b) 를 건너뛴 것입니다.


-- =============================================================
-- PART C-4. ⑤ EAI / Network Rule / Secret / Stage 정리
-- =============================================================
-- 🔴 계정 레벨 객체(EAI)와 스키마 레벨 객체(Network Rule / Secret / Stage)를
--    분리했습니다. EAI 는 DB 와 무관하므로 방어 블록 밖에 둡니다.
--
-- USE ROLE OPENFLOW_EDU_ADMIN_RL;
--
-- -- (a) EAI — 계정 레벨. 놓치면 계정에 영구히 남습니다. DB 부재와 무관합니다.
-- DROP INTEGRATION IF EXISTS PG_SOURCE_EAI;
--
-- -- (b) 스키마 레벨 3종 — 상위 DB 존재를 먼저 확인합니다 (2회차 실행 방어)
-- EXECUTE IMMEDIATE $$
-- DECLARE
--     v_db_count INTEGER;
--     rs RESULTSET;
-- BEGIN
--     rs := (SHOW DATABASES LIKE 'OPENFLOW_EDU_DB');
--     SELECT COUNT(*) INTO v_db_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--
--     IF (v_db_count = 0) THEN
--         RETURN 'OPENFLOW_EDU_DB 가 이미 없습니다. 스키마 레벨 객체 정리를 건너뜁니다.';
--     END IF;
--
--     DROP NETWORK RULE IF EXISTS
--       OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_NETWORK_RULE;
--     DROP SECRET IF EXISTS
--       OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET;
--     -- config.json 편집용 스테이지 (07번 문서에서 생성)
--     DROP STAGE IF EXISTS
--       OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_CONFIG_STAGE_OPENFLOW_EDU_DE_RL;
--
--     RETURN 'Network Rule / Secret / Stage 정리 완료';
-- END;
-- $$;

-- ❗ 실패 시 확인: DROP INTEGRATION 이 실패하면 Runtime 이 아직 EAI 를
--    참조하고 있습니다. PART C-2 (a) 를 먼저 수행하세요.
--
-- 🔴 재실행 주의 — `IF EXISTS` 는 상위 데이터베이스 부재를 막아주지 않습니다
--    OPENFLOW_EDU_DB 를 이미 DROP 한 뒤(PART C-5) 이 절을 다시 실행하면
--    스키마 레벨 구문 3개(Network Rule / Secret / Stage)는 원래 다음으로
--    실패했습니다.
--      Database 'OPENFLOW_EDU_DB' does not exist or not authorized.
--    `IF EXISTS` 는 **그 객체 자체**의 부재만 처리하며, 정규화된 이름의
--    상위 컨테이너가 없으면 이름 해석 단계에서 실패합니다.
--    → **2026-09-17 부터 위 (b) 방어 블록이 이 경우를 처리합니다.**
--      DB 가 없으면 '건너뜁니다' 를 반환하고 정상 종료하므로, 이제 이 절을
--      순서와 무관하게 다시 실행해도 안전합니다.
--    → 계정 레벨인 (a) `DROP INTEGRATION PG_SOURCE_EAI` 는 DB 와 무관하므로
--      언제든 단독 실행할 수 있습니다.
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
-- 🔴 이 절의 **기록 정본은 `96_실습후_대조.md` 입니다.**
--    아래 쿼리는 정리 직후 이 스크립트 안에서 바로 확인할 수 있도록 둔 것이고,
--    값을 적어 남기는 것은 96_ 의 서식에 하십시오.
--    두 곳의 쿼리가 어긋나면 **96_ 을 기준으로 맞춥니다.**
--    (같은 쿼리를 두 문서에 복제해 두면 한쪽만 고쳐져 갈라지기 때문입니다.)
--
--    대조 기준값은 `95_실습전_기준선.md` 에 기록해 두었어야 합니다.
--    (`02_` STEP 0-6 의 스냅샷과 같은 쿼리입니다. 어느 쪽으로 기록했든 무관합니다.)
--
-- 🔴 96_ 에는 이 절에 없는 항목이 두 개 더 있습니다. 반드시 그쪽도 수행하십시오.
--      · §5 소스 DB(복제 슬롯·binlog) 원복 확인 — 방치 시 실질 피해가 가장 큽니다
--      · §6 이 문서를 **2회차 실행**해 재실행 안전성 확인 — 지금만 가능합니다

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
-- [ ] Deployment OPENFLOW_EDU_DEPLOYMENT — TERMINATE + DROP 완료
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
