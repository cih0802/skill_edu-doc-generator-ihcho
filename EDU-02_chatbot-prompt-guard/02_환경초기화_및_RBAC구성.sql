/*
title: 환경 초기화 및 RBAC 구성
step: 02
type: sql
summary: 실습 가능 조건 게이트 확인, 실습 전 스냅샷 및 접두사 충돌 검사 후 전용 Warehouse / Database / 6대 스키마 / Role 2종을 생성하고 최소 권한을 부여한다.
requires: 없음
next: 03_문서스테이지_및_디렉터리테이블.sql
*/

-- ==============================================================================
-- 검증 상태
--
-- [2026-09-17 재검증 — 모델 수명 게이트 [0.6] 신설]
--   계정 LJ20513 / AWS_AP_NORTHEAST_1 / Enterprise, 실습 완주
--   ✅ [0.6-a] 모델 수명 게이트 — **실제 실행 검증 완료.**
--      SHOW CORTEX BASE MODELS + RESULT_SCAN 조합이 동작하며 실제 출력:
--        CLAUDE-HAIKU-4-5              | GA | legacy_date NULL | ✅ 사용 가능
--        SNOWFLAKE-ARCTIC-EMBED-L-V2.0 | GA | legacy_date NULL | ✅ 사용 가능
--   ✅ [0.6-b] GA 대체 후보 조회 — 실제 실행 검증 완료
--      arctic-embed-l-v2.0 의 in_region_availability 에 AWS_AP_NORTHEAST_1 이
--      포함되어 크로스 리전 없이 사용 가능함을 확인
--   🔴 이 게이트를 새로 넣은 이유: 이전 판이 기본 모델로 쓰던 llama3.1-70b 가
--      LEGACY(legacy_date 2026-08-12, 이미 경과) 상태였습니다. 게이트가 없으면
--      학습자가 09_ 에서 원인을 모른 채 막힙니다
--   ✅ [3][4][5][6][7] WH / DB / 6대 스키마 / Role 2종 / 소유권 이전 / 권한 부여
--      — 실제 실행 재검증 완료
--   ✅ 98_ 정리 후 잔여물 0 — 실제 실행. SHOW ... LIKE 'KSM_CHATBOT%' 3종 모두 0행
--
-- [이전 회차(2026-09-16) 검증 — 그대로 유효]
--   ✅ [0.2][0.3] CORTEX_ENABLED_CROSS_REGION=ANY_REGION, AI_SETTINGS 미설정 확인
--   ✅ [0.5] SNOWFLAKE.CORTEX_USER 데이터베이스 롤 존재 확인
--   ✅ [1] 사전 스냅샷 / [2] 접두사 충돌 검사 — 충돌 0건
--   ✅ [6] GRANT OWNERSHIP ... COPY CURRENT GRANTS 가 08_ Cortex Search 의
--      변경추적 자동 활성화를 가능하게 함(실증)
--   ✅ [8] 검증 쿼리 — LAB_SCHEMA_COUNT=6, 태그된 Role 2행
--
-- ⚠️ [0.4] Edition 확인은 SQL 로 불가하므로 Snowsight 수동 확인 항목입니다
-- ==============================================================================
-- ==============================================================================
-- ⚙️ 설정값 — 이 문서의 하드코딩 값은 여기에 집약되어 있습니다
-- ==============================================================================
--   객체 접두사      : KSM_CHATBOT_
--   COMMENT 태그     : [chatbot-prompt-guard]
--   Warehouse        : KSM_CHATBOT_WH        (XSMALL / AUTO_SUSPEND 60초)
--   Database         : KSM_CHATBOT_DB
--   Schemas          : BRONZE SILVER GOLD SERVING OPS SECURITY
--   Admin Role       : KSM_CHATBOT_ADMIN_ROLE
--   User Role        : KSM_CHATBOT_USER_ROLE
--
--   예상 소요 시간   : 약 10분
-- ==============================================================================


-- ##############################################################################
-- [0] 🚦 실습 가능 조건 게이트 — 통과하지 못하면 이후 단계를 진행하지 마십시오
-- ##############################################################################
-- 이 실습은 아래 조건을 모두 만족해야 완주할 수 있습니다.
-- 조건을 만족하지 못하면 06_, 09_, 10_ 단계에서 실패합니다.

USE ROLE ACCOUNTADMIN;

-- 0.1 계정 식별 정보 및 리전 확인
--     AI_PARSE_DOCUMENT / Cortex Search 는 리전별 제공 여부가 다릅니다.
SELECT
    CURRENT_ACCOUNT()   AS ACCOUNT_IDENTIFIER,
    CURRENT_REGION()    AS SNOWFLAKE_REGION,
    CURRENT_USER()      AS EXEC_USER,
    CURRENT_ROLE()      AS EXEC_ROLE;
--   확인한 리전: ______________________________

-- 0.2 🔴 크로스 리전 추론 활성화 여부 — Cortex AI Guardrails(10_)의 필수 전제
--     DISABLED 이면 10_ 단계를 수행할 수 없습니다.
--     값이 이미 ANY_REGION / AWS_US / AWS_EU / AWS_JP / AWS_APJ / AWS_GLOBAL 중
--     하나라면 변경이 필요 없습니다. 변경이 필요한 경우의 절차와 원복은 10_ 에 있습니다.
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;

SELECT "key", "value", "level",
       CASE WHEN "value" = 'DISABLED'
            THEN '🔴 미활성 — 10_ 단계 수행 불가. 활성화 방법은 10_ 참고'
            ELSE '✅ 활성 — 10_ 단계 수행 가능'
       END AS GATE_RESULT
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "key" = 'CORTEX_ENABLED_CROSS_REGION';
--   실습 전 CORTEX_ENABLED_CROSS_REGION 값: ______________________________
--   (이 값은 10_ 의 원복 절에서 필요합니다. 반드시 기록하십시오)

-- 0.3 🔴 AI_SETTINGS 실습 전 값 — 10_ 에서 변경하는 계정 파라미터
--     10_ 은 이 값을 변경합니다. DROP 으로 되돌아가지 않으므로 지금 기록해야 합니다.
SHOW PARAMETERS LIKE 'AI_SETTINGS' IN ACCOUNT;

SELECT "key", "value", "level"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "key" = 'AI_SETTINGS';
--   실습 전 AI_SETTINGS 값: ______________________________
--     · 비어 있음(미설정)  → 정리 시 ALTER ACCOUNT UNSET AI_SETTINGS
--     · 값이 있음          → 그 YAML 전문을 아래에 그대로 보관하십시오
--   ______________________________________________________________________
--   ______________________________________________________________________

-- 0.4 Edition 확인 — Cortex AI Guardrails(10_)는 Enterprise Edition 이상 필요
--     Edition 은 SQL 로 직접 조회할 수 없습니다.
--     Snowsight → Admin → Account 에서 확인하십시오.
--   확인한 Edition: ______________________  (Standard 이면 10_ 단계 생략)

-- 0.5 Cortex 함수 사용 권한 확인 — SNOWFLAKE.CORTEX_USER 데이터베이스 롤 존재 여부
SHOW DATABASE ROLES IN DATABASE SNOWFLAKE;

SELECT "name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'CORTEX_USER';
--   결과가 없으면 Cortex 기능이 비활성화된 계정입니다. 실습을 진행할 수 없습니다.

-- 0.6 🔴🔴 모델 수명(lifecycle) 게이트 — 건너뛰지 마십시오 🔴🔴
--     Cortex 모델은 GA → LEGACY → EOL 로 폐기됩니다.
--     **LEGACY 날짜가 지난 모델은, 그 직전 30일 내에 그 모델을 쓴 적이 없는
--     계정에서는 선택 자체가 불가능합니다.** 즉 교육자료에 모델명을 박아 두면
--     시간이 지나 실습이 실패합니다. 이 게이트가 그것을 미리 잡습니다.
--
--     실측 사례(2026-09-17, 계정 LJ20513): 이 자료의 이전 판이 기본 모델로 쓰던
--     `llama3.1-70b` 는 lifecycle_status = LEGACY, legacy_date = 2026-08-12(경과),
--     eol_date = No sooner than 2026-10-14 상태였습니다. 그대로 두면 신규 학습자는
--     09_ 에서 막힙니다. 그래서 `claude-haiku-4-5` 로 교체했습니다.

-- 0.6-a 이 실습이 쓰는 두 모델의 수명 상태를 확인합니다
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "legacy_date", "eol_date",
       CASE WHEN "lifecycle_status" = 'GA'     THEN '✅ 사용 가능'
            WHEN "lifecycle_status" = 'LEGACY' THEN '⚠️ LEGACY — 교체를 권합니다'
            WHEN "lifecycle_status" = 'EOL'    THEN '🔴 EOL — 사용 불가. 반드시 교체'
            ELSE '⚠️ 확인 필요 (' || COALESCE("lifecycle_status", 'NULL') || ')'
       END AS GATE_RESULT
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE UPPER("name") IN ('CLAUDE-HAIKU-4-5', 'SNOWFLAKE-ARCTIC-EMBED-L-V2.0');
--   LLM (claude-haiku-4-5)          상태: ____________  legacy_date: __________
--   임베딩 (arctic-embed-l-v2.0)     상태: ____________  legacy_date: __________
--
--   🔴 GA 가 아니면 아래처럼 대체 모델을 고른 뒤 두 곳을 바꾸십시오.
--      · LLM     → 09_ 의 PROMPT_GUARD_CONFIG.DEFAULT_MODEL 행만 UPDATE
--                  (프로시저 재배포 불필요)
--      · 임베딩   → 08_ 의 EMBEDDING_MODEL. 이미 서비스를 만들었다면
--                  CREATE OR REPLACE 로 인덱스를 다시 빌드해야 합니다(크레딧 재발생)

-- 0.6-b GA 상태인 대체 후보를 직접 찾습니다
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "in_region_availability", "cross_region_availability"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
--   🔴 임베딩 모델을 바꿀 때는 **언어 지원**을 반드시 확인하십시오.
--      이 실습의 문서·질의는 전부 한국어이므로 Multilingual 모델이어야 합니다.
--      English-only 모델을 쓰면 오류 없이 검색 품질만 나빠집니다(08_ 상단 표 참고).
--   ⚠️ in_region_availability 에 현재 리전이 없으면 크로스 리전 추론이 필요합니다
--      (0.2 게이트의 CORTEX_ENABLED_CROSS_REGION 값을 함께 보십시오).


-- ##############################################################################
-- [1] 📸 실습 전 상태 스냅샷 — 조회 전용. 계정을 변경하지 않습니다
-- ##############################################################################
-- 정리(98_) 후 이 결과와 대조해 원상복구를 증명합니다.
-- 🔴 아래 값은 계정마다 다릅니다. 결과를 보고 빈칸을 직접 채우십시오.
--    분량이 크면 95_실습전_기준선.md 를 사용하십시오.

SHOW DATABASES;
--   실습 전 데이터베이스 개수: ______ 개
--   목록: ________________________________________________________________

SHOW WAREHOUSES;
--   실습 전 웨어하우스 개수: ______ 개
--   목록: ________________________________________________________________

SHOW ROLES;
--   실습 전 사용자 정의 Role 목록: ______________________________________

SHOW TASKS IN ACCOUNT;
--   실습 전 Task 개수: ______ 개

SHOW CORTEX SEARCH SERVICES IN ACCOUNT;
--   실습 전 Cortex Search Service 개수: ______ 개


-- ##############################################################################
-- [2] 🚧 접두사 충돌 검사 — 기존 자산을 덮어쓰지 않기 위한 필수 게이트
-- ##############################################################################
-- 아래 쿼리 중 하나라도 결과가 나오면 **이후 단계를 실행하지 마십시오.**
-- 접두사(KSM_CHATBOT_)를 다른 값으로 바꾸거나, 해당 객체의 소유자에게 확인하십시오.
-- 이 실습은 CREATE ... IF NOT EXISTS 를 사용하므로 기존 객체를 파괴하지는 않지만,
-- 기존 객체를 실습 대상으로 오인하면 정리 단계에서 사용자 자산이 삭제됩니다.

SHOW DATABASES  LIKE 'KSM_CHATBOT%';   -- 결과 없어야 정상
SHOW WAREHOUSES LIKE 'KSM_CHATBOT%';   -- 결과 없어야 정상
SHOW ROLES      LIKE 'KSM_CHATBOT%';   -- 결과 없어야 정상
--   충돌 검사 통과 여부: ☐ 통과   ☐ 충돌 발견 (진행 중단)


-- ##############################################################################
-- [3] 전용 가상 웨어하우스 생성
-- ##############################################################################
-- 💰 지속 과금 객체입니다. 실습을 중단할 때는 반드시 SUSPEND 하거나 98_ 로 삭제하십시오.
-- IF NOT EXISTS: 재실행해도 기존 웨어하우스와 그 설정을 파괴하지 않습니다.

CREATE WAREHOUSE IF NOT EXISTS KSM_CHATBOT_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'KSM HQ 챗봇 파이프라인 및 서비스용 웨어하우스. 실습용. [chatbot-prompt-guard]';

USE WAREHOUSE KSM_CHATBOT_WH;


-- ##############################################################################
-- [4] 전용 데이터베이스 및 6대 스키마 생성
-- ##############################################################################
-- 💰 스토리지 비용이 발생합니다.

CREATE DATABASE IF NOT EXISTS KSM_CHATBOT_DB
    COMMENT = 'KSM HQ 챗봇 및 Cortex 검색/가드레일 실습 데이터베이스. 실습용. [chatbot-prompt-guard]';

-- Medallion(BRONZE/SILVER/GOLD) + SERVING + OPS + SECURITY
CREATE SCHEMA IF NOT EXISTS KSM_CHATBOT_DB.BRONZE
    COMMENT = '비정형 원본 문서 적재 및 인덱싱 스키마 (Raw Layer). [chatbot-prompt-guard]';

CREATE SCHEMA IF NOT EXISTS KSM_CHATBOT_DB.SILVER
    COMMENT = 'AI_PARSE_DOCUMENT 및 청킹 처리된 텍스트/메타데이터 스키마 (Refined Layer). [chatbot-prompt-guard]';

CREATE SCHEMA IF NOT EXISTS KSM_CHATBOT_DB.GOLD
    COMMENT = '정제된 업무 요약 및 도메인 지식 베이스 스키마 (Aggregated Layer). [chatbot-prompt-guard]';

CREATE SCHEMA IF NOT EXISTS KSM_CHATBOT_DB.SERVING
    COMMENT = 'Cortex Search Service 및 챗봇 서빙 프로시저 스키마 (Serving Layer). [chatbot-prompt-guard]';

CREATE SCHEMA IF NOT EXISTS KSM_CHATBOT_DB.OPS
    COMMENT = 'Serverless Task 및 파이프라인 운영 모니터링 스키마 (Operations Layer). [chatbot-prompt-guard]';

CREATE SCHEMA IF NOT EXISTS KSM_CHATBOT_DB.SECURITY
    COMMENT = '보안 가드 설정 테이블, PII 마스킹 UDF 및 거버넌스 스키마 (Security Layer). [chatbot-prompt-guard]';

-- 계정 생성 시 자동으로 만들어지는 PUBLIC 스키마는 이 실습에서 쓰지 않습니다.
-- 삭제하지 않습니다 (DB 삭제 시 함께 사라집니다).


-- ##############################################################################
-- [5] RBAC 구성 — 전용 Role 2종
-- ##############################################################################

CREATE ROLE IF NOT EXISTS KSM_CHATBOT_ADMIN_ROLE
    COMMENT = 'KSM 챗봇 파이프라인 개발 및 Cortex Search/Agent 관리자 역할. 실습용. [chatbot-prompt-guard]';

CREATE ROLE IF NOT EXISTS KSM_CHATBOT_USER_ROLE
    COMMENT = 'KSM 챗봇 검색 서비스 조회 전용 역할. 실습용. [chatbot-prompt-guard]';

-- 5.1 역할 계층 — SYSADMIN 이 관리자 역할을 상속받아 객체를 관리할 수 있게 합니다
GRANT ROLE KSM_CHATBOT_ADMIN_ROLE TO ROLE SYSADMIN;
GRANT ROLE KSM_CHATBOT_USER_ROLE  TO ROLE KSM_CHATBOT_ADMIN_ROLE;

-- 5.2 실습 수행자에게 관리자 역할 부여
--     ⚠️ 이것은 기존 USER 객체에 Role 을 부여하는 것입니다.
--     98_ 에서 Role 을 DROP 하면 이 부여도 함께 사라지므로 별도 원복은 필요 없습니다.
SET V_EXEC_USER = CURRENT_USER();
GRANT ROLE KSM_CHATBOT_ADMIN_ROLE TO USER IDENTIFIER($V_EXEC_USER);


-- ##############################################################################
-- [6] 객체 소유권 이전 — 최소 권한 원칙 적용
-- ##############################################################################
-- [3]~[5]는 ACCOUNTADMIN 으로 실행했으므로 객체 소유자가 ACCOUNTADMIN 입니다.
-- 이후 단계를 전용 Role 로 수행하려면 소유권을 넘겨야 합니다.
-- REVOKE CURRENT GRANTS 를 쓰지 않으므로 기존 부여는 유지됩니다.

GRANT OWNERSHIP ON DATABASE KSM_CHATBOT_DB
    TO ROLE KSM_CHATBOT_ADMIN_ROLE COPY CURRENT GRANTS;

GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE KSM_CHATBOT_DB
    TO ROLE KSM_CHATBOT_ADMIN_ROLE COPY CURRENT GRANTS;

GRANT OWNERSHIP ON WAREHOUSE KSM_CHATBOT_WH
    TO ROLE KSM_CHATBOT_ADMIN_ROLE COPY CURRENT GRANTS;


-- ##############################################################################
-- [7] 권한 부여
-- ##############################################################################

-- 7.1 웨어하우스
GRANT USAGE ON WAREHOUSE KSM_CHATBOT_WH TO ROLE KSM_CHATBOT_USER_ROLE;

-- 7.2 Cortex AI 함수 실행 권한 (SNOWFLAKE.CORTEX_USER 데이터베이스 롤)
--     ⚠️ 이 부여는 SNOWFLAKE 데이터베이스의 롤을 실습 Role 에 주는 것입니다.
--     실습 Role 을 DROP 하면 함께 사라지므로 별도 원복은 필요 없습니다.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE KSM_CHATBOT_ADMIN_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE KSM_CHATBOT_USER_ROLE;

-- 7.3 🔴 계정 레벨 권한 — Serverless Task 실행에 필요합니다
--     이것은 계정 스코프 GRANT 입니다. Role 을 DROP 하면 함께 사라집니다.
GRANT EXECUTE TASK         ON ACCOUNT TO ROLE KSM_CHATBOT_ADMIN_ROLE;
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE KSM_CHATBOT_ADMIN_ROLE;

-- 7.4 사용자 역할 — SERVING 스키마 읽기 전용 (최소 권한)
--     BRONZE(원본 문서), SECURITY(보안 설정)에는 접근 권한을 주지 않습니다.
GRANT USAGE ON DATABASE KSM_CHATBOT_DB          TO ROLE KSM_CHATBOT_USER_ROLE;
GRANT USAGE ON SCHEMA   KSM_CHATBOT_DB.SERVING  TO ROLE KSM_CHATBOT_USER_ROLE;


-- ##############################################################################
-- [8] 구성 검증
-- ##############################################################################
USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;

-- 8.1 스키마 6개가 모두 있는지
SHOW SCHEMAS IN DATABASE KSM_CHATBOT_DB;

SELECT COUNT(*) AS LAB_SCHEMA_COUNT   -- 6 이어야 정상 (PUBLIC / INFORMATION_SCHEMA 제외)
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" IN ('BRONZE','SILVER','GOLD','SERVING','OPS','SECURITY');

-- 8.2 Role 2개와 태그 확인
SHOW ROLES LIKE 'KSM_CHATBOT%';

SELECT "name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[chatbot-prompt-guard]%';   -- 2행이어야 정상

-- 8.3 관리자 역할에 부여된 권한
SHOW GRANTS TO ROLE KSM_CHATBOT_ADMIN_ROLE;


-- ##############################################################################
-- 🧹 리소스 정리 — 이 문서까지 진행한 뒤 중단하는 경우
-- ##############################################################################
-- 전체 정리는 98_리소스정리.sql 이 정본입니다. 아래는 이 문서에서 만든 것만 되돌립니다.
-- 실행하려면 주석을 해제하십시오. 생성의 역순입니다.
--
-- USE ROLE ACCOUNTADMIN;
-- DROP DATABASE  IF EXISTS KSM_CHATBOT_DB;
-- DROP WAREHOUSE IF EXISTS KSM_CHATBOT_WH;
-- DROP ROLE      IF EXISTS KSM_CHATBOT_USER_ROLE;
-- DROP ROLE      IF EXISTS KSM_CHATBOT_ADMIN_ROLE;   -- Role 은 가장 마지막
-- UNSET V_EXEC_USER;
--
-- 💰 비용만 멈추고 실습을 이어서 하려면 삭제하지 말고 아래만 실행하십시오.
-- ALTER WAREHOUSE KSM_CHATBOT_WH SUSPEND;
