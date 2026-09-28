/*
title: 환경 준비 및 비용 가드
step: 02
type: sql
summary: 사전 스냅샷·접두사 충돌·모델 수명 게이트를 확인한 뒤 전용 Role/Warehouse(XS, 60초 자동중지)/Database/Schema 와 리소스 모니터(크레딧 상한)를 만든다.
requires: 01_교육자료_정리본.md
next: 03_스테이지_및_증분감지.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-28, 계정 LJ20513 / AWS_AP_NORTHEAST_1 에서 실습 완주)
--   ✅ [0] 사전 스냅샷·접두사 충돌 검사 — 실제 실행
--   ✅ [0.5] SHOW CORTEX BASE MODELS 수명 게이트 — 실제 실행
--   ✅ [1]~[4] Role/WH/RM/DB/Schema 생성·권한 — 실제 실행 (2회 실행해 IF NOT EXISTS 확인)
--   ⚠️ 리소스 모니터 트리거(SUSPEND) 실제 발동 — 크레딧 상한 도달이 필요해 미관찰
-- ==============================================================================

-- ==============================================================================
-- ⚙️ 설정값 (이 문서에서 쓰는 이름. 바꾸면 98_ 도 같이 바꾸십시오)
--   Role              : DOCRAG_ADMIN_RL
--   Warehouse         : DOCRAG_WH   (XSMALL, AUTO_SUSPEND 60초, 초기 중지 상태)
--   Resource Monitor  : DOCRAG_RM   (월 3 크레딧, 90% 알림 / 100% 중지)
--   Database          : DOCRAG_DB   (스키마 RAW / CURATED / SERVING)
--   공통 태그         : [unstructured-doc-rag-pipeline]
-- ==============================================================================

-- 💰 비용 최적화 설계 — 이 문서에서 적용하는 것
--   · 웨어하우스는 XSMALL + AUTO_SUSPEND 60초. 청킹 UDTF·프로시저만 이 WH 를 쓴다
--   · STATEMENT_TIMEOUT 을 WH 에 걸어 폭주 쿼리를 끊는다
--   · 리소스 모니터로 이 WH 의 크레딧 사용량 상한을 둔다
--     ⚠️ 리소스 모니터는 **웨어하우스 크레딧만** 통제한다. AI 함수 토큰·Cortex Search
--        서빙 같은 서버리스 비용은 통제하지 않는다 (09_ 의 사용량 조회로 따로 본다)

USE ROLE ACCOUNTADMIN;

-- ==============================================================================
-- [0] 사전 스냅샷 — 실습 전 상태를 기록합니다 (조회 전용)
--     결과를 아래 빈칸에 직접 적으십시오. 98_ 정리 후 같은 쿼리로 대조합니다.
-- ==============================================================================
SHOW DATABASES;
--   실습 전 데이터베이스 수: ______
SHOW WAREHOUSES;
--   실습 전 웨어하우스 목록: ______________________________
SHOW ROLES;
--   실습 전 역할 수: ______
SHOW RESOURCE MONITORS;
--   실습 전 리소스 모니터 목록: ______________________________

-- 접두사 충돌 검사 — 결과가 **0행**이어야 합니다.
-- 행이 나오면 동명 자산이 이미 있다는 뜻입니다. 진행하지 말고 접두사를 바꾸십시오.
SHOW DATABASES         LIKE 'DOCRAG%';
SHOW WAREHOUSES        LIKE 'DOCRAG%';
SHOW ROLES             LIKE 'DOCRAG%';
SHOW RESOURCE MONITORS LIKE 'DOCRAG%';

-- ==============================================================================
-- [0.5] 🔴 모델 수명 게이트 — 실습 전에 반드시 확인
--   Cortex 모델은 GA → LEGACY → EOL 로 폐기됩니다. 자료를 고치지 않아도 시간이 지나면
--   실습이 실패로 바뀝니다. 아래 두 모델이 GA 이고, 계정 리전 또는 허용된 크로스 리전에서
--   사용 가능한지 확인하십시오.
--     임베딩: SNOWFLAKE-ARCTIC-EMBED-L-V2.0   ← Multilingual (한국어 지원)
--     생성  : CLAUDE-HAIKU-4-5                ← 크로스 리전 필요할 수 있음
--   작성 시점 참고값(계정마다 다름): 두 모델 모두 lifecycle_status = GA.
--   CLAUDE-HAIKU-4-5 는 AP_NORTHEAST_1 리전 내 제공이 없고 cross_region 으로만 제공되었다.
-- ==============================================================================
SHOW CORTEX BASE MODELS;
SELECT "name", "lifecycle_status", "legacy_date", "eol_date",
       "in_region_availability", "cross_region_availability"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" IN ('SNOWFLAKE-ARCTIC-EMBED-L-V2.0', 'CLAUDE-HAIKU-4-5', 'LLAMA3.1-8B');
--   임베딩 모델 상태: ______   생성 모델 상태: ______

-- 크로스 리전 허용 여부 — 조회만 합니다. 이 실습은 이 값을 **변경하지 않습니다.**
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
--   실습 전 값: ______
--   · DISABLED 이고 생성 모델이 리전 내 제공되지 않으면 08_ 의 기본 모델이 실패합니다.
--     이 경우 계정 파라미터를 바꾸지 말고, 08_ 설정 테이블의 모델을 리전 내 GA 모델
--     (예: LLAMA3.1-8B — 한국어 품질은 낮을 수 있음)로 바꾸십시오.
--   · 계정 파라미터 변경은 계정 전체에 영향을 주므로 관리자 판단 사항입니다.

-- ==============================================================================
-- [1] 전용 Role — 실습 객체는 이 역할이 만들고 소유합니다
-- ==============================================================================
CREATE ROLE IF NOT EXISTS DOCRAG_ADMIN_RL
    COMMENT = '비정형 문서 RAG 실습 관리 역할. [unstructured-doc-rag-pipeline]';

-- 현재 사용자에게 부여합니다. (DROP ROLE 시 함께 사라집니다)
-- CURRENT_USER() 는 식별자 자리에 직접 쓸 수 없어 세션 변수 + IDENTIFIER 로 전달합니다.
SET MY_USER = CURRENT_USER();
GRANT ROLE DOCRAG_ADMIN_RL TO USER IDENTIFIER($MY_USER);

-- Cortex AI 함수·Cortex Search 사용 권한 (데이터베이스 역할)
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE DOCRAG_ADMIN_RL;

-- 태스크 실행 권한 — 계정 레벨 권한이며 DROP ROLE 로 함께 회수됩니다
GRANT EXECUTE TASK ON ACCOUNT TO ROLE DOCRAG_ADMIN_RL;

-- ==============================================================================
-- [2] Warehouse + 리소스 모니터 — 비용 가드
-- ==============================================================================
-- 🔴 세대(GENERATION)와 QAS 를 **명시**합니다 — 생략하면 기본값이 비용을 바꿉니다
--   공식 문서: GENERATION 을 생략하면 Gen2 가 기본이고(리전에서 가능할 때),
--   새 Gen2 웨어하우스는 Query Acceleration Service(QAS) 가 **자동으로 켜집니다**
--   (QAS 는 별도 서버리스 크레딧). 2026-09-28 이 계정에서 생략하고 만들었더니
--   실제로 generation=2, enable_query_acceleration=true 로 생성되었습니다.
--   이 실습은 소량 문서 + 무거운 연산 대부분이 서버리스 AI 함수라 Gen2/QAS 이점이 작습니다.
--   Gen1/Gen2 요율은 Snowflake Service Consumption Table 에서 확인하십시오.
CREATE WAREHOUSE IF NOT EXISTS DOCRAG_WH
    WAREHOUSE_SIZE      = 'XSMALL'
    GENERATION          = '1'
    ENABLE_QUERY_ACCELERATION = FALSE
    AUTO_SUSPEND        = 60          -- 60초 유휴 시 중지
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE        -- 만들자마자 과금되지 않도록
    STATEMENT_TIMEOUT_IN_SECONDS = 600
    COMMENT = '비정형 문서 RAG 실습용 XS 웨어하우스. [unstructured-doc-rag-pipeline]';

-- 리소스 모니터 — 월 3 크레딧 상한 (실습 규모에서 충분한 여유값. 측정값이 아닙니다)
-- ⚠️ CREATE RESOURCE MONITOR 는 IF NOT EXISTS 를 지원합니다. OR REPLACE 는 쓰지 않습니다.
CREATE RESOURCE MONITOR IF NOT EXISTS DOCRAG_RM
    WITH CREDIT_QUOTA = 3
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 90  PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND;

-- 이 실습 WH 에만 연결합니다. (계정 전체 모니터가 아닙니다)
ALTER WAREHOUSE DOCRAG_WH SET RESOURCE_MONITOR = DOCRAG_RM;

GRANT USAGE, OPERATE ON WAREHOUSE DOCRAG_WH TO ROLE DOCRAG_ADMIN_RL;

-- ==============================================================================
-- [3] Database — ACCOUNTADMIN 이 소유하고, 실습 역할에는 스키마 생성 권한만 줍니다
--     (계정 레벨 CREATE DATABASE 권한을 위임하지 않기 위함 — 최소 권한)
-- ==============================================================================
CREATE DATABASE IF NOT EXISTS DOCRAG_DB
    COMMENT = '비정형 문서 RAG 실습 DB. [unstructured-doc-rag-pipeline]';

GRANT USAGE, CREATE SCHEMA ON DATABASE DOCRAG_DB TO ROLE DOCRAG_ADMIN_RL;

-- ==============================================================================
-- [4] Schema — 실습 역할로 전환해 만듭니다 (소유자 = DOCRAG_ADMIN_RL)
--   RAW     : 원본 파일 스테이지 + 변경 감지 스트림
--   CURATED : 파싱 결과·청크·처리 로직(UDTF/프로시저/태스크)
--   SERVING : 검색 서비스·RAG 프로시저·답변 캐시·평가
-- ==============================================================================
USE ROLE DOCRAG_ADMIN_RL;
USE WAREHOUSE DOCRAG_WH;

CREATE SCHEMA IF NOT EXISTS DOCRAG_DB.RAW
    COMMENT = '원본 문서 스테이지. [unstructured-doc-rag-pipeline]';
CREATE SCHEMA IF NOT EXISTS DOCRAG_DB.CURATED
    COMMENT = '파싱·청킹 결과. [unstructured-doc-rag-pipeline]';
CREATE SCHEMA IF NOT EXISTS DOCRAG_DB.SERVING
    COMMENT = '검색·RAG 서빙. [unstructured-doc-rag-pipeline]';

-- ==============================================================================
-- [5] 확인 — 결과로 단정합니다
-- ==============================================================================
SHOW SCHEMAS IN DATABASE DOCRAG_DB;              -- RAW / CURATED / SERVING 이 보여야 합니다
SHOW WAREHOUSES LIKE 'DOCRAG_WH';                -- size = X-Small, auto_suspend = 60, resource_monitor = DOCRAG_RM,
                                                 -- generation = 1, enable_query_acceleration = false
SELECT AI_COMPLETE('claude-haiku-4-5', '한 단어로만 답하세요: 준비 완료?') AS SMOKE_TEST;
--   ↑ 권한·모델 접근 확인용 1회 호출 (소량 토큰 과금). 오류가 나면 [0.5] 게이트를 다시 보십시오.

-- ==============================================================================
-- 🧹 리소스 정리 (이 문서에서 만든 객체만. 전체 정리는 98_리소스정리.sql 이 정본입니다)
-- ==============================================================================
-- USE ROLE ACCOUNTADMIN;
-- DROP DATABASE IF EXISTS DOCRAG_DB;
-- DROP WAREHOUSE IF EXISTS DOCRAG_WH;
-- DROP RESOURCE MONITOR IF EXISTS DOCRAG_RM;
-- DROP ROLE IF EXISTS DOCRAG_ADMIN_RL;
