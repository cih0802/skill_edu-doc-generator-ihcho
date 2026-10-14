/*
title: 리소스 정리 (Teardown)
step: 98
type: sql
summary: 실습에서 생성된 Share, 데이터베이스(테이블·Dynamic Iceberg Table·프로시저·정책·Semantic View 포함), 웨어하우스, 역할을 역순으로 정리하고, 2회 재실행 안전 방어 블록과 사전 스냅샷 대조 쿼리로 잔여물 0 을 확인합니다.
requires: 10_외부엔진연동_및_의미론적계층.sql
next: 없음
*/

-- ----------------------------------------------------------------------------
-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ PART A SUSPEND 3구문 — 실제 실행 (scheduling_state = SUSPENDED 확인)
--   ✅ PART C 전체 실행 1회차 — 성공
--   ✅ PART C 전체 재실행 2회차 — 오류 없음 (C-2 방어 블록 "건너뜁니다" 반환), PART D 4개 SHOW 모두 0행 = 사전 스냅샷과 일치
--   ℹ️  2회차 최초 시도에서 세션 웨어하우스 삭제로 인한 실패를 실측해 USE WAREHOUSE 지시를 추가했습니다
-- ----------------------------------------------------------------------------

-- ==============================================================================
-- 💰 (1) 비용 경고 — 가장 먼저 읽으십시오
--   | 객체                              | 과금                                 | 멈추는 방법       |
--   |-----------------------------------|--------------------------------------|-------------------|
--   | **DIT_DAILY_FLEET_SUMMARY**       | TARGET_LAG 1 hour 자동 갱신 (WH 사용) | PART A SUSPEND    |
--   | **DIT_ENRICHED_TELEMETRY**        | DOWNSTREAM — 위 테이블 갱신 시 함께   | PART A SUSPEND    |
--   | **ICEBERG_LAB_WH**                | 쿼리 실행 시 (60초 자동 중지)          | PART A SUSPEND    |
--   | **Iceberg 테이블 (Snowflake storage)** | 스토리지 (Snowflake 청구)        | PART C DROP       |
-- ==============================================================================

-- ==============================================================================
-- 🔴 사용법
--   · PART C 의 DROP 은 주석 처리되어 있습니다. 대상 확인(PART C-0) 후 주석을 해제해 실행하십시오
--   · 계정 기본 객체(COMPUTE_WH, SNOWFLAKE DB, 시스템 역할, PUBLIC)는 건드리지 않습니다
--   · 두 번 실행해도 안전합니다 (C-2 는 DB 부재 시 건너뛰는 방어 블록)
-- ==============================================================================

USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES NONE;
-- 🔴 실습 웨어하우스(ICEBERG_LAB_WH)가 아닌 웨어하우스를 쓰십시오 (계정에 있는 것으로 바꿔도 됩니다).
--    ICEBERG_LAB_WH 로 실행하면 C-3 에서 세션 웨어하우스가 삭제되어, 2회차 실행 시 C-2 방어 블록의
--    RESULT_SCAN 이 "No active warehouse selected" 로 실패합니다 (2026-10-14 실측)
USE WAREHOUSE COMPUTE_WH;

-- ==============================================================================
-- (2) PART A. 일시 중단 — 삭제 없이 비용만 멈춥니다 (실습을 이어서 할 때)
--   DB 가 없으면 이 구문들은 실패합니다(IF EXISTS 는 상위 DB 부재를 막지 못함). 이때는 건너뛰십시오
-- ==============================================================================
-- ALTER DYNAMIC TABLE IF EXISTS ICEBERG_LAB_DB.TRANSFORM.DIT_DAILY_FLEET_SUMMARY SUSPEND;
-- ALTER DYNAMIC TABLE IF EXISTS ICEBERG_LAB_DB.TRANSFORM.DIT_ENRICHED_TELEMETRY SUSPEND;
-- ALTER WAREHOUSE IF EXISTS ICEBERG_LAB_WH SUSPEND;

-- ==============================================================================
-- (5) PART B. 삭제 전 데이터 보존 (선택)
--   보존 테이블은 실습 DB 밖에 만들어야 하며 스토리지 비용이 계속 발생합니다
-- ==============================================================================
-- CREATE TABLE <보존용_DB>.<스키마>.ICB_VEHICLE_REGISTRY_BAK AS SELECT * FROM ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY;

-- ==============================================================================
-- (3)(4)(9) PART C. 완전 삭제 — 역순 + 재실행 안전
--   순서: ① Share(계정 레벨, DB 를 참조) → ② DB(하위 전체) → ③ WH → ④ 역할(마지막)
--   상태 전이가 필요한 객체 없음: Dynamic Iceberg Table·Iceberg 테이블은 DROP DATABASE 로 삭제됩니다
-- ==============================================================================

-- C-0. 대상 확인 — COMMENT 가 'EDU-05' 로 시작하는지 확인한 뒤 진행합니다
SHOW SHARES LIKE 'SHARE_ICEBERG_FLEET_DATA';
SHOW DATABASES LIKE 'ICEBERG_LAB_DB';
SHOW WAREHOUSES LIKE 'ICEBERG_LAB_WH';
SHOW ROLES LIKE 'ICEBERG_%_RL';
--  10_ [3] 을 실제로 수행해 PAT 를 발급했다면 먼저 폐기합니다
-- SHOW USER PROGRAMMATIC ACCESS TOKENS FOR USER <사용자>;
-- ALTER USER <사용자> REMOVE PROGRAMMATIC ACCESS TOKEN <토큰_이름>;
--  03_ 템플릿 A 를 실제로 실행했다면 외부 볼륨도 삭제합니다 (계정 레벨, DB 삭제로 사라지지 않음)
-- DROP EXTERNAL VOLUME IF EXISTS VOL_S3_ICEBERG_STORAGE;

-- C-1. Share (계정 레벨)
-- DROP SHARE IF EXISTS SHARE_ICEBERG_FLEET_DATA;

-- C-2. Database 및 하위 전체 (Iceberg 테이블, Dynamic Iceberg Table, 프로시저, 정책, 뷰, Semantic View)
--      CASCADE 영향 범위: ICEBERG_LAB_DB 내부 객체만. 다른 DB 는 이 DB 를 참조하지 않습니다
-- EXECUTE IMMEDIATE $$
-- DECLARE
--     n INT;
-- BEGIN
--     SHOW DATABASES LIKE 'ICEBERG_LAB_DB';
--     SELECT COUNT(*) INTO :n FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--     IF (n = 0) THEN
--         RETURN 'ICEBERG_LAB_DB 가 이미 없습니다. 이 절을 건너뜁니다.';
--     END IF;
--     DROP DATABASE IF EXISTS ICEBERG_LAB_DB CASCADE;
--     RETURN 'ICEBERG_LAB_DB 삭제 완료';
-- END;
-- $$;

-- C-3. 전용 웨어하우스
-- DROP WAREHOUSE IF EXISTS ICEBERG_LAB_WH;

-- C-4. 실습 전용 역할 (가장 마지막. 사용자·SYSADMIN 에 대한 역할 부여도 함께 사라집니다)
-- DROP ROLE IF EXISTS ICEBERG_ANALYST_RL;
-- DROP ROLE IF EXISTS ICEBERG_LAB_RL;

-- ==============================================================================
-- (6) 외부 리소스: 기본 경로(Snowflake storage)에서는 없습니다.
--     External Volume 템플릿을 실제로 썼다면 S3 버킷의 lakehouse/ 경로와 IAM 역할을 클라우드 콘솔에서 삭제하십시오
-- ==============================================================================

-- ==============================================================================
-- (7) PART D. 정리 완료 검증 — 02_ [1] 사전 스냅샷과 대조
--   모든 결과가 0행이어야 하며, 사전 스냅샷에 있던 객체는 그대로 있어야 합니다
-- ==============================================================================
SHOW SHARES LIKE 'SHARE_ICEBERG_%';
SHOW DATABASES LIKE 'ICEBERG_%';
SHOW WAREHOUSES LIKE 'ICEBERG_%';
SHOW ROLES LIKE 'ICEBERG_%';

-- ==============================================================================
-- (8) 정리 체크리스트 (01_ 객체 대장과 1:1)
--   [ ] SHARE_ICEBERG_FLEET_DATA ............................ C-1
--   [ ] **ICEBERG_LAB_DB** (RAW/TRANSFORM/GOVERNANCE 하위 전체) .. C-2
--       └ **DIT_ENRICHED_TELEMETRY / DIT_DAILY_FLEET_SUMMARY** (자동 갱신 비용)
--       └ ICB_* Iceberg 테이블 5종, SP_TRANSFORM_ICEBERG_TELEMETRY,
--         MP_VIN_MASK, RAP_REGION_FILTER, SV_FLEET_MONITORING_PUBLIC, SEM_FLEET_ANALYTICS
--   [ ] **ICEBERG_LAB_WH** .................................... C-3
--   [ ] ICEBERG_ANALYST_RL / ICEBERG_LAB_RL ................... C-4
--   [ ] (조건부) PAT, VOL_S3_ICEBERG_STORAGE ................... C-0
-- ==============================================================================
