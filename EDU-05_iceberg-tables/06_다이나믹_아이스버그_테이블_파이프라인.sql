/*
title: 다이나믹 아이스버그 테이블 파이프라인
step: 06
type: sql
summary: Iceberg 원천 테이블을 기반으로 2단계 다이나믹 테이블(Silver Tier 엔리치먼트 -> Gold Tier 일별 플릿 집계) 증분 파이프라인을 구축하고 자동 갱신을 실습합니다.
requires: 05_아이스버그_타임트래블_및_메타데이터분석.sql
next: 07_스노우파크_및_고급변환.sql
*/

-- ----------------------------------------------------------------------------
-- [0. 실습 개요 및 증분 파이프라인 아키텍처]
--
-- Snowflake Dynamic Tables는 원천 Iceberg 테이블에 새로운 데이터가 인입될 때마다
-- 변경분(CDC)만을 자동으로 감지하여 다운스트림 테이블로 증분 변환(Incremental Refresh)합니다.
--
-- [Tier 1 : Silver] DIT_ENRICHED_TELEMETRY
--   - ICB_SENSOR_READINGS + ICB_VEHICLE_REGISTRY 조인
--   - 차량 마스터 메타데이터와 시계열 센서 값 결합
--
-- [Tier 2 : Gold] DIT_DAILY_FLEET_SUMMARY
--   - DIT_ENRICHED_TELEMETRY 집계
--   - 일자별, 지역별, 차종별 플릿 가동 및 배터리/엔진 효율 지표 산출
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA TRANSFORM;

-- ----------------------------------------------------------------------------
-- [1. Tier 1 (Silver): 엔리치먼트 다이나믹 테이블 생성]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE DIT_ENRICHED_TELEMETRY
    TARGET_LAG = '1 minute'
    WAREHOUSE = ICEBERG_LAB_WH
    COMMENT = 'Tier 1 센서 데이터와 차량 마스터가 결합된 정제 테이블'
AS
SELECT 
    s.READING_ID,
    s.VEHICLE_ID,
    v.MODEL_NAME,
    v.VIN,
    v.REGION_CODE,
    v.STATUS AS VEHICLE_STATUS,
    s.RECORDED_AT,
    s.SPEED_KMH,
    s.BATTERY_PCT,
    s.ENGINE_TEMP_C,
    s.ODOMETER_KM
FROM ICEBERG_LAB_DB.RAW.ICB_SENSOR_READINGS s
JOIN ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY v
    ON s.VEHICLE_ID = v.VEHICLE_ID;

-- ----------------------------------------------------------------------------
-- [2. Tier 2 (Gold): 일별 플릿 집계 다이나믹 테이블 생성]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE DIT_DAILY_FLEET_SUMMARY
    TARGET_LAG = '1 minute'
    WAREHOUSE = ICEBERG_LAB_WH
    COMMENT = 'Tier 2 일자/지역/모델별 플릿 가동 지표 집계 테이블'
AS
SELECT 
    RECORDED_AT::DATE AS SUMMARY_DATE,
    REGION_CODE,
    MODEL_NAME,
    COUNT(DISTINCT VEHICLE_ID) AS ACTIVE_VEHICLE_COUNT,
    AVG(SPEED_KMH) AS AVG_SPEED_KMH,
    AVG(BATTERY_PCT) AS AVG_BATTERY_PCT,
    AVG(ENGINE_TEMP_C) AS AVG_ENGINE_TEMP_C,
    MAX(ODOMETER_KM) - MIN(ODOMETER_KM) AS TOTAL_DISTANCE_KM
FROM ICEBERG_LAB_DB.TRANSFORM.DIT_ENRICHED_TELEMETRY
GROUP BY RECORDED_AT::DATE, REGION_CODE, MODEL_NAME;

-- ----------------------------------------------------------------------------
-- [3. 수동 리프레시 트리거 및 데이터 흐름 검증]
-- ----------------------------------------------------------------------------

-- Tier 1 리프레시
ALTER DYNAMIC TABLE DIT_ENRICHED_TELEMETRY REFRESH;

-- Tier 2 리프레시
ALTER DYNAMIC TABLE DIT_DAILY_FLEET_SUMMARY REFRESH;

-- 결과 확인
SELECT * FROM DIT_ENRICHED_TELEMETRY ORDER BY RECORDED_AT;
SELECT * FROM DIT_DAILY_FLEET_SUMMARY ORDER BY SUMMARY_DATE, REGION_CODE;

-- ----------------------------------------------------------------------------
-- [4. 다이나믹 테이블 파이프라인 모니터링]
-- ----------------------------------------------------------------------------
SELECT 
    NAME,
    SCHEMA_NAME,
    TARGET_LAG,
    WAREHOUSE,
    REFRESH_MODE,
    SCHEDULING_STATE
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES())
WHERE DATABASE_NAME = 'ICEBERG_LAB_DB';
