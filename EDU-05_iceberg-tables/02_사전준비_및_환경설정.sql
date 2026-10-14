/*
title: 사전 준비 및 환경 설정
step: 02
type: sql
summary: 리전 게이트와 이름 충돌 게이트를 통과한 뒤, Iceberg 실습 전용 관리자/분석가 역할, 웨어하우스, 데이터베이스, 스키마를 생성하고 사전 상태 스냅샷을 기록합니다.
requires: 01_교육자료_정리본.md
next: 03_스토리지모델_비교_및_외부볼륨구성.sql
*/

-- ----------------------------------------------------------------------------
-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ [0] 리전 게이트, [1] 스냅샷, [1-1] 충돌 게이트 — 실제 실행
--   ✅ [2]~[4] 역할/웨어하우스/DB/스키마 생성·권한 부여 — 실제 실행
--   ⚠️ 충돌 게이트의 "차단" 경로는 동명 객체를 일부러 만들어 보지 않았으므로 미관찰
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- [0. 사전 안내 및 리전 게이트]
-- 이 스크립트는 ACCOUNTADMIN 으로 실습 전용 역할과 인프라를 만들고,
-- 이후 실습은 ICEBERG_LAB_RL 로 진행합니다 (최소 권한).
--
-- 🔴 Snowflake storage(EXTERNAL_VOLUME 생략) Iceberg 테이블은 AWS·Azure 리전에서만 쓸 수 있고,
--    정부(Gov) 리전과 중국 리전에서는 쓸 수 없습니다 (공식 문서: Snowflake storage for Iceberg tables).
--    아래 쿼리 결과가 FAIL 이면 이 자료의 04_ 이후는 External Volume 없이 진행할 수 없습니다.
-- ----------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES NONE;
-- [1-1] 충돌 게이트의 RESULT_SCAN 은 웨어하우스가 필요합니다. 실습 WH 는 아직 없으므로 기존 WH 를 씁니다
-- (계정에 있는 다른 웨어하우스로 바꿔도 됩니다. 이 실습은 이 WH 를 변경하지 않습니다)
USE WAREHOUSE COMPUTE_WH;

SELECT CURRENT_REGION() AS REGION,
       IFF((CURRENT_REGION() LIKE 'AWS_%' OR CURRENT_REGION() LIKE 'AZURE_%')
           AND CURRENT_REGION() NOT ILIKE '%GOV%',
           'PASS — Snowflake storage Iceberg 사용 가능 리전',
           'FAIL — External Volume 이 필요합니다 (03_ 템플릿 참고)') AS REGION_GATE;

-- ----------------------------------------------------------------------------
-- [1. 사전 스냅샷 기록]
-- 아래 결과를 실행 전에 기록해 두고, 98_ PART D 결과와 대조합니다.
--   SHOW ROLES LIKE 'ICEBERG_%'        -> 결과: [          ]
--   SHOW WAREHOUSES LIKE 'ICEBERG_%'   -> 결과: [          ]
--   SHOW DATABASES LIKE 'ICEBERG_%'    -> 결과: [          ]
--   SHOW SHARES LIKE 'SHARE_ICEBERG_%' -> 결과: [          ]
-- ----------------------------------------------------------------------------
SHOW ROLES LIKE 'ICEBERG_%';
SHOW WAREHOUSES LIKE 'ICEBERG_%';
SHOW DATABASES LIKE 'ICEBERG_%';
SHOW SHARES LIKE 'SHARE_ICEBERG_%';

-- ----------------------------------------------------------------------------
-- [1-1. 이름 충돌 게이트]
-- 같은 이름의 객체가 이미 있고 그것이 이 실습(COMMENT 'EDU-05 …')이 만든 것이 아니면 중단합니다.
-- 이 실습이 만든 객체라면 통과합니다 (중단 후 이어서 실행하는 경우).
-- ----------------------------------------------------------------------------
EXECUTE IMMEDIATE $$
DECLARE
    foreign_cnt INT DEFAULT 0;
    c INT;
    name_conflict EXCEPTION (-20001, '충돌: ICEBERG_LAB_* 이름의 기존 객체가 EDU-05 소유가 아닙니다. 이름을 바꾸거나 기존 객체를 확인하십시오.');
BEGIN
    SHOW DATABASES LIKE 'ICEBERG_LAB_DB';
    SELECT COUNT(*) INTO :c FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE COALESCE("comment", '') NOT LIKE 'EDU-05%';
    foreign_cnt := foreign_cnt + c;
    SHOW WAREHOUSES LIKE 'ICEBERG_LAB_WH';
    SELECT COUNT(*) INTO :c FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE COALESCE("comment", '') NOT LIKE 'EDU-05%';
    foreign_cnt := foreign_cnt + c;
    SHOW ROLES LIKE 'ICEBERG_%_RL';
    SELECT COUNT(*) INTO :c FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
        WHERE "name" IN ('ICEBERG_LAB_RL', 'ICEBERG_ANALYST_RL') AND COALESCE("comment", '') NOT LIKE 'EDU-05%';
    foreign_cnt := foreign_cnt + c;
    IF (foreign_cnt > 0) THEN
        RAISE name_conflict;
    END IF;
    RETURN 'PASS — 충돌 없음';
END;
$$;

-- ----------------------------------------------------------------------------
-- [2. 실습 전용 역할(Role) 생성 및 권한 부여]
-- ----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS ICEBERG_LAB_RL
    COMMENT = 'EDU-05 Apache Iceberg 실습 전용 관리자 역할';

CREATE ROLE IF NOT EXISTS ICEBERG_ANALYST_RL
    COMMENT = 'EDU-05 거버넌스 및 행/열 보안 검증용 분석가 역할';

-- 관리자 계층 구조 연결 (SYSADMIN 하위에 실습 역할 배치)
GRANT ROLE ICEBERG_LAB_RL TO ROLE SYSADMIN;
GRANT ROLE ICEBERG_ANALYST_RL TO ROLE ICEBERG_LAB_RL;

-- 현재 작업 사용자에게 역할 부여 (역할 삭제 시 함께 사라집니다)
SET MY_USER = CURRENT_USER();
GRANT ROLE ICEBERG_LAB_RL TO USER IDENTIFIER($MY_USER);
GRANT ROLE ICEBERG_ANALYST_RL TO USER IDENTIFIER($MY_USER);

-- ----------------------------------------------------------------------------
-- [3. 전용 웨어하우스(Warehouse) 생성]
-- 🔴 계정 레벨 객체에는 CREATE OR REPLACE 를 쓰지 않습니다 (동명 사용자 자산 파괴 방지)
-- ----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS ICEBERG_LAB_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'EDU-05 Apache Iceberg 실습 전용 컴퓨팅 웨어하우스';

GRANT USAGE, OPERATE ON WAREHOUSE ICEBERG_LAB_WH TO ROLE ICEBERG_LAB_RL;
GRANT USAGE ON WAREHOUSE ICEBERG_LAB_WH TO ROLE ICEBERG_ANALYST_RL;

-- ----------------------------------------------------------------------------
-- [4. 데이터베이스 및 스키마 생성]
-- ----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ICEBERG_LAB_DB
    COMMENT = 'EDU-05 Apache Iceberg 실습 전용 데이터베이스';

CREATE SCHEMA IF NOT EXISTS ICEBERG_LAB_DB.RAW
    COMMENT = '원천 데이터 및 기본 Iceberg 테이블 스키마';
CREATE SCHEMA IF NOT EXISTS ICEBERG_LAB_DB.TRANSFORM
    COMMENT = 'Dynamic Iceberg Tables 및 Snowpark 변환 스키마';
CREATE SCHEMA IF NOT EXISTS ICEBERG_LAB_DB.GOVERNANCE
    COMMENT = 'Row Access/Masking Policy 및 Secure View 스키마';

-- 실습 역할에 DB 및 스키마 권한 위임
GRANT ALL ON DATABASE ICEBERG_LAB_DB TO ROLE ICEBERG_LAB_RL;
GRANT ALL ON SCHEMA ICEBERG_LAB_DB.RAW TO ROLE ICEBERG_LAB_RL;
GRANT ALL ON SCHEMA ICEBERG_LAB_DB.TRANSFORM TO ROLE ICEBERG_LAB_RL;
GRANT ALL ON SCHEMA ICEBERG_LAB_DB.GOVERNANCE TO ROLE ICEBERG_LAB_RL;

-- 분석가 역할에 기본 사용 권한 위임 (테이블 SELECT 는 08_ 에서 부여)
GRANT USAGE ON DATABASE ICEBERG_LAB_DB TO ROLE ICEBERG_ANALYST_RL;
GRANT USAGE ON SCHEMA ICEBERG_LAB_DB.RAW TO ROLE ICEBERG_ANALYST_RL;
GRANT USAGE ON SCHEMA ICEBERG_LAB_DB.TRANSFORM TO ROLE ICEBERG_ANALYST_RL;
GRANT USAGE ON SCHEMA ICEBERG_LAB_DB.GOVERNANCE TO ROLE ICEBERG_ANALYST_RL;

-- ----------------------------------------------------------------------------
-- [5. 환경 설정 검증]
-- ----------------------------------------------------------------------------
USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA RAW;

SELECT
    CURRENT_ROLE() AS CURRENT_ROLE,
    CURRENT_WAREHOUSE() AS CURRENT_WAREHOUSE,
    CURRENT_DATABASE() AS CURRENT_DATABASE,
    CURRENT_SCHEMA() AS CURRENT_SCHEMA;

SHOW SCHEMAS IN DATABASE ICEBERG_LAB_DB;

-- ----------------------------------------------------------------------------
-- 🧹 이 단계까지의 정리: 98_ PART C 의 C-2(DB), C-3(WH), C-4(역할)
-- ----------------------------------------------------------------------------
