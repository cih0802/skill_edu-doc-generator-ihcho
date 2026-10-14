/*
title: 리소스 정리 (Teardown)
step: 98
type: sql
summary: 실습에서 생성된 모든 역할, 웨어하우스, 데이터베이스, 스키마, 아이스버그 테이블, 다이나믹 테이블, 정책, 쉐어를 역순으로 정리하고 2회 재실행 안전 방어 블록 및 잔여물 검증 쿼리를 수행합니다.
requires: 10_외부엔진연동_및_의미론적계층.sql
next: 없음
*/

-- ==============================================================================
-- 💰 (1) 비용 경고 — 가장 먼저 읽으십시오
--   지속 과금되는 것 (실습을 멈춰도 계속 나갈 수 있음)
--   | 객체                         | 과금                        | 멈추는 방법                           |
--   |------------------------------|-----------------------------|---------------------------------------|
--   | **DIT_ENRICHED_TELEMETRY**   | 다이나믹 테이블 주기적 갱신 | SUSPEND / DROP                        |
--   | **DIT_DAILY_FLEET_SUMMARY**  | 다이나믹 테이블 주기적 갱신 | SUSPEND / DROP                        |
--   | **ICEBERG_LAB_WH**           | 쿼리 시 (60초 자동중지)      | SUSPEND / DROP                        |
--   | Iceberg 테이블 스토리지      | 스토리지                     | DROP                                  |
-- ==============================================================================

-- ==============================================================================
-- 🔴 사용법
--   · 계정 기본 객체(COMPUTE_WH, SNOWFLAKE DB, 시스템 역할, PUBLIC)는 이 문서가 건드리지 않습니다
--   · 이 문서는 **두 번 실행해도 안전**하도록 멱등 방어 블록을 갖추고 있습니다
-- ==============================================================================

USE ROLE ACCOUNTADMIN;

-- ==============================================================================
-- PART A. 일시 중단 — 삭제 없이 비용만 멈춥니다 (실습을 나중에 이어서 할 때)
-- ==============================================================================
-- ALTER DYNAMIC TABLE IF EXISTS ICEBERG_LAB_DB.TRANSFORM.DIT_DAILY_FLEET_SUMMARY SUSPEND;
-- ALTER DYNAMIC TABLE IF EXISTS ICEBERG_LAB_DB.TRANSFORM.DIT_ENRICHED_TELEMETRY SUSPEND;
-- ALTER WAREHOUSE IF EXISTS ICEBERG_LAB_WH SUSPEND;

-- ==============================================================================
-- PART B. 삭제 전 데이터 보존 (선택)
-- ==============================================================================
-- CREATE TABLE <보존용_DB>.<스키마>.ICB_VEHICLE_REGISTRY_BAK AS SELECT * FROM ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY;

-- ==============================================================================
-- PART C. 완전 삭제 — 역순 및 재실행 안전 방어 블록
-- ==============================================================================

-- C-1. Share 정리
DROP SHARE IF EXISTS SHARE_ICEBERG_FLEET_DATA;

-- C-2. Database 및 하위 전체 객체 일괄 정리 (테이블, 다이나믹 테이블, 프로시저, 정책 포함)
DROP DATABASE IF EXISTS ICEBERG_LAB_DB CASCADE;

-- C-3. 전용 웨어하우스 정리
DROP WAREHOUSE IF EXISTS ICEBERG_LAB_WH;

-- C-4. 실습 전용 역할 정리
DROP ROLE IF EXISTS ICEBERG_ANALYST_RL;
DROP ROLE IF EXISTS ICEBERG_LAB_RL;

-- ==============================================================================
-- PART D. 정리 완료 검증 쿼리 (사전 스냅샷 대조)
-- 모든 결과가 0건(Empty)이어야 완벽하게 정리된 것입니다.
-- ==============================================================================
SHOW SHARES LIKE 'SHARE_ICEBERG_%';
SHOW DATABASES LIKE 'ICEBERG_LAB_DB';
SHOW WAREHOUSES LIKE 'ICEBERG_LAB_WH';
SHOW ROLES LIKE 'ICEBERG_%';
