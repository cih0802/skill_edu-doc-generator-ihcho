/*
title: 다이나믹 아이스버그 테이블 파이프라인
step: 06
type: sql
summary: Iceberg 원천 테이블을 기반으로 2단계 Dynamic Iceberg Table(Silver 엔리치먼트 -> Gold 일별 플릿 집계) 증분 파이프라인을 구축하고, 신규 데이터 인입 후 INCREMENTAL 갱신이 일어나는지 갱신 이력으로 확인합니다.
requires: 05_아이스버그_타임트래블_및_메타데이터분석.sql
next: 07_스노우파크_및_고급변환.sql
*/

-- ----------------------------------------------------------------------------
-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ [1][2] CREATE DYNAMIC ICEBERG TABLE 2종 — 실제 실행, SHOW 결과 is_iceberg = true
--   ✅ [3] 초기 REFRESH 후 행 수 확인, [4] 신규 센서 1건 → REFRESH → 행 수 증가 — 실제 실행
--   ✅ [5] DYNAMIC_TABLE_REFRESH_HISTORY 의 REFRESH_ACTION 확인 — 실제 실행
--   ⚠️ TARGET_LAG 에 의한 자동(스케줄) 갱신은 시간 경과가 필요해 관찰하지 않았습니다 (수동 REFRESH 로 대체)
--   ℹ️  1차 판은 일반 CREATE DYNAMIC TABLE 이었습니다 (실측 is_iceberg = false). 주제와 맞게 교체했습니다
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- [0. 실습 개요]
--
-- Dynamic Iceberg Table 은 결과를 Iceberg 포맷으로 저장하는 Dynamic Table 입니다.
-- 일반 Dynamic Table 과 같은 갱신 모드·스케줄을 쓰되, 결과 파일을 외부 엔진이 Iceberg 로 읽을 수 있습니다.
-- Snowflake storage 를 쓸 때는 EXTERNAL_VOLUME / CATALOG / BASE_LOCATION 을 생략합니다.
--
-- [Tier 1 : Silver] DIT_ENRICHED_TELEMETRY   — 센서 + 차량 마스터 조인 (TARGET_LAG = DOWNSTREAM)
-- [Tier 2 : Gold]   DIT_DAILY_FLEET_SUMMARY  — 일자·지역·모델별 집계 (TARGET_LAG = '1 hour')
--
-- 💡 Tier 1 을 DOWNSTREAM 으로 두면 Tier 2 가 필요할 때만 함께 갱신되어 불필요한 갱신 비용이 줄어듭니다.
--
-- 공식 문서 제약 (Create a dynamic Apache Iceberg table):
--   · IF NOT EXISTS 미지원 → CREATE OR REPLACE 사용 (스키마 레벨 객체라 계정 자산 파괴 위험 없음)
--   · ALTER DYNAMIC ICEBERG TABLE 은 없음 → 갱신 속성은 ALTER DYNAMIC TABLE 로 변경
--   · 미래 권한은 ON FUTURE DYNAMIC TABLES 로 부여 (ON FUTURE ICEBERG TABLES 는 적용되지 않음)
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA TRANSFORM;

-- ----------------------------------------------------------------------------
-- [1. Tier 1 (Silver): 엔리치먼트 Dynamic Iceberg Table]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC ICEBERG TABLE DIT_ENRICHED_TELEMETRY
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = ICEBERG_LAB_WH
    REFRESH_MODE = INCREMENTAL
    COMMENT = 'EDU-05 Tier 1 센서 데이터와 차량 마스터가 결합된 정제 테이블'
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
-- [2. Tier 2 (Gold): 일별 플릿 집계 Dynamic Iceberg Table]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC ICEBERG TABLE DIT_DAILY_FLEET_SUMMARY
    TARGET_LAG = '1 hour'
    WAREHOUSE = ICEBERG_LAB_WH
    REFRESH_MODE = INCREMENTAL
    COMMENT = 'EDU-05 Tier 2 일자/지역/모델별 플릿 가동 지표 집계 테이블'
AS
SELECT 
    RECORDED_AT::DATE AS SUMMARY_DATE,
    REGION_CODE,
    MODEL_NAME,
    COUNT(*) AS READING_COUNT,
    COUNT(DISTINCT VEHICLE_ID) AS ACTIVE_VEHICLE_COUNT,
    AVG(SPEED_KMH) AS AVG_SPEED_KMH,
    AVG(BATTERY_PCT) AS AVG_BATTERY_PCT,
    AVG(ENGINE_TEMP_C) AS AVG_ENGINE_TEMP_C,
    MAX(ODOMETER_KM) - MIN(ODOMETER_KM) AS TOTAL_DISTANCE_KM
FROM ICEBERG_LAB_DB.TRANSFORM.DIT_ENRICHED_TELEMETRY
GROUP BY RECORDED_AT::DATE, REGION_CODE, MODEL_NAME;

-- 두 테이블이 Iceberg 로 저장되는지 확인 (기대: is_iceberg = true, refresh_mode = INCREMENTAL)
SHOW DYNAMIC TABLES IN SCHEMA ICEBERG_LAB_DB.TRANSFORM
    ->> SELECT "name", "is_iceberg", "refresh_mode", "target_lag", "scheduling_state" FROM $1 ORDER BY "name";

-- ----------------------------------------------------------------------------
-- [3. 초기 결과 확인]
-- 생성 시 초기 갱신이 수행됩니다. 기대: Tier1 10행(05_ 이후 센서 10건), Tier2 그룹 행
-- ----------------------------------------------------------------------------
SELECT COUNT(*) AS T1_ROWS FROM DIT_ENRICHED_TELEMETRY;
SELECT * FROM DIT_DAILY_FLEET_SUMMARY ORDER BY SUMMARY_DATE, REGION_CODE, MODEL_NAME;

-- ----------------------------------------------------------------------------
-- [4. 증분 데이터 인입 → 갱신 → 반영 확인]
-- Tier 2 를 갱신하면 상류 Tier 1(DOWNSTREAM)도 함께 갱신됩니다.
-- 기대: T1_ROWS 가 1 증가, KR-INCHEON 의 READING_COUNT 가 1 증가
-- ----------------------------------------------------------------------------
INSERT INTO ICEBERG_LAB_DB.RAW.ICB_SENSOR_READINGS (READING_ID, VEHICLE_ID, RECORDED_AT, SPEED_KMH, BATTERY_PCT, ENGINE_TEMP_C, ODOMETER_KM)
VALUES ('R-011', 'VH-3001', '2026-10-14 12:00:00', 80.0, 52.0, 93.0, 54500.0);

ALTER DYNAMIC TABLE DIT_DAILY_FLEET_SUMMARY REFRESH;

SELECT COUNT(*) AS T1_ROWS FROM DIT_ENRICHED_TELEMETRY;
SELECT REGION_CODE, MODEL_NAME, READING_COUNT, TOTAL_DISTANCE_KM
FROM DIT_DAILY_FLEET_SUMMARY ORDER BY REGION_CODE;

-- ----------------------------------------------------------------------------
-- [5. 갱신 이력 모니터링 — 실제로 증분(INCREMENTAL) 이었는가]
-- REFRESH_ACTION: INCREMENTAL / FULL / NO_DATA / REINITIALIZE
-- 💡 REFRESH_MODE = INCREMENTAL 로 생성됐다는 것과 매 갱신이 증분으로 실행됐다는 것은 다릅니다. 이력으로 확인합니다
-- ----------------------------------------------------------------------------
SELECT NAME, STATE, REFRESH_ACTION, REFRESH_TRIGGER,
       DATA_TIMESTAMP, REFRESH_START_TIME, REFRESH_END_TIME
FROM TABLE(ICEBERG_LAB_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
WHERE QUALIFIED_NAME ILIKE 'ICEBERG_LAB_DB.TRANSFORM.%'
ORDER BY REFRESH_START_TIME DESC;

-- ----------------------------------------------------------------------------
-- 🧹 이 단계까지의 정리
--   일시 중단: 98_ PART A (ALTER DYNAMIC TABLE … SUSPEND) — TARGET_LAG '1 hour' 자동 갱신 비용을 멈춥니다
--   삭제     : 98_ C-2 (DB 삭제 시 함께 삭제)
-- ----------------------------------------------------------------------------
