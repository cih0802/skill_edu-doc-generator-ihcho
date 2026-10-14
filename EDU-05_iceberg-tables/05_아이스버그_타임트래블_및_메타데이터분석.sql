/*
title: 아이스버그 타임트래블 및 메타데이터 분석
step: 05
type: sql
summary: DML 전후 Iceberg 메타데이터 파일(metadata.json) 버전 변화를 SYSTEM$GET_ICEBERG_TABLE_INFORMATION 으로 직접 비교하고, 저장한 시점 기준 Time Travel(AT TIMESTAMP)과 스키마 진화를 실습합니다.
requires: 04_아이스버그_테이블생성_및_데이터적재.sql
next: 06_다이나믹_아이스버그_테이블_파이프라인.sql
*/

-- ----------------------------------------------------------------------------
-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ [1] 메타데이터 위치 기록, [2] UPDATE/INSERT, [3] 메타데이터 버전 증가 비교 — 실제 실행
--   ✅ [4] AT(TIMESTAMP => $T_BEFORE_UPDATE) 과거 값 조회 — 실제 실행 (R-001 SPEED 65.5 → 현재 0.0)
--   ✅ [5] ALTER ICEBERG TABLE ADD COLUMN 스키마 진화 — 실제 실행
--   ℹ️  1차 판의 AT(OFFSET => -120) 은 04_ 직후 2분 안에 실행하면
--      "Time travel data is not available … before the object creation time" 으로 실패함을 실측해 교체했습니다
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- [0. Iceberg 메타데이터 및 스냅샷 원리]
--
-- Apache Iceberg 는 커밋(INSERT, UPDATE, DELETE, 스키마 변경)마다 새 스냅샷과
-- 새 메타데이터 파일을 만듭니다. 계층은 다음과 같습니다.
--
-- 1. 메타데이터 파일 (NNNNN-<uuid>.metadata.json) : 스키마, 파티션 사양, 스냅샷 목록, 현재 스냅샷
-- 2. 매니페스트 리스트 (snap-*.avro) : 한 스냅샷을 구성하는 매니페스트 목록
-- 3. 매니페스트 파일 (*.avro) : Parquet 데이터 파일 경로와 컬럼 통계(Min/Max/Null 수)
-- 4. 데이터 파일 (*.parquet)
--
-- Snowflake 에서는 SYSTEM$GET_ICEBERG_TABLE_INFORMATION 이 "현재 메타데이터 파일 경로" 를 돌려줍니다.
-- 파일명 앞 5자리 번호가 커밋마다 증가하는 것을 아래 [3] 에서 직접 확인합니다.
-- (매니페스트·Parquet 파일 자체는 Snowflake storage 에 있어 SQL 로 목록을 볼 수 없습니다)
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA RAW;

-- ----------------------------------------------------------------------------
-- [1. 변경 전 상태 기록 — 건수, 메타데이터 파일, 시점]
-- ----------------------------------------------------------------------------
SELECT COUNT(*) AS CNT_BEFORE_CHANGE FROM ICB_SENSOR_READINGS;   -- 기대: 8

SET META_BEFORE = (SELECT PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_LAB_DB.RAW.ICB_SENSOR_READINGS')):metadataLocation::VARCHAR);
SELECT $META_BEFORE AS METADATA_BEFORE;

-- Time Travel 기준 시점. 반드시 [2] DML 직전에 저장합니다
SET T_BEFORE_UPDATE = CURRENT_TIMESTAMP();

-- ----------------------------------------------------------------------------
-- [2. 데이터 수정 및 신규 삽입 (커밋 2회 → 스냅샷 2개)]
-- ----------------------------------------------------------------------------
UPDATE ICB_SENSOR_READINGS
SET SPEED_KMH = 0.0, BATTERY_PCT = 100.0
WHERE READING_ID = 'R-001';

INSERT INTO ICB_SENSOR_READINGS (READING_ID, VEHICLE_ID, RECORDED_AT, SPEED_KMH, BATTERY_PCT, ENGINE_TEMP_C, ODOMETER_KM)
VALUES
    ('R-009', 'VH-1001', '2026-10-14 11:00:00', 75.0, 95.0, 80.0, 12690.0),
    ('R-010', 'VH-2002', '2026-10-14 11:30:00', 60.0, 82.0, 77.0, 18500.0);

-- ----------------------------------------------------------------------------
-- [3. 메타데이터 분석 — 변경 전후 metadata.json 비교]
-- 기대: METADATA_AFTER 의 파일 번호가 METADATA_BEFORE 보다 큼 (커밋마다 새 파일)
-- ----------------------------------------------------------------------------
SET META_AFTER = (SELECT PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_LAB_DB.RAW.ICB_SENSOR_READINGS')):metadataLocation::VARCHAR);

SELECT
    REGEXP_SUBSTR($META_BEFORE, '([0-9]{5})-[^/]+\\.metadata\\.json$', 1, 1, 'e') AS VERSION_BEFORE,
    REGEXP_SUBSTR($META_AFTER,  '([0-9]{5})-[^/]+\\.metadata\\.json$', 1, 1, 'e') AS VERSION_AFTER,
    VERSION_AFTER::INT - VERSION_BEFORE::INT AS NEW_METADATA_FILES,
    REGEXP_SUBSTR($META_AFTER, '^(.*)/metadata/', 1, 1, 'e') AS TABLE_BASE_PATH;

-- ----------------------------------------------------------------------------
-- [4. Time Travel 질의 실습]
-- AT (TIMESTAMP => …) 는 지정 시점의 스냅샷을 읽습니다.
-- OFFSET(-초) 대신 [1] 에서 저장한 시점을 쓰면 실행 속도와 무관하게 항상 "변경 직전" 을 가리킵니다.
-- ----------------------------------------------------------------------------

-- 4-1. 변경 직전 R-001 (기대: SPEED 65.5 / BATTERY 92.0)
SELECT 'PAST_SNAPSHOT' AS SNAPSHOT_TYPE, READING_ID, VEHICLE_ID, SPEED_KMH, BATTERY_PCT
FROM ICB_SENSOR_READINGS AT(TIMESTAMP => $T_BEFORE_UPDATE::TIMESTAMP_LTZ)
WHERE READING_ID = 'R-001';

-- 4-2. 현재와 과거 비교 (기대: R-001 값 변경, R-009/R-010 은 PAST 가 NULL = 신규 행)
SELECT 
    curr.READING_ID,
    curr.SPEED_KMH   AS CURR_SPEED,
    past.SPEED_KMH   AS PAST_SPEED,
    curr.BATTERY_PCT AS CURR_BATTERY,
    past.BATTERY_PCT AS PAST_BATTERY,
    CASE WHEN past.READING_ID IS NULL THEN 'INSERTED'
         WHEN curr.SPEED_KMH <> past.SPEED_KMH OR curr.BATTERY_PCT <> past.BATTERY_PCT THEN 'UPDATED'
         ELSE 'UNCHANGED' END AS CHANGE_TYPE
FROM ICB_SENSOR_READINGS curr
LEFT JOIN ICB_SENSOR_READINGS AT(TIMESTAMP => $T_BEFORE_UPDATE::TIMESTAMP_LTZ) past
    ON curr.READING_ID = past.READING_ID
ORDER BY curr.READING_ID;

-- ----------------------------------------------------------------------------
-- [5. 스키마 진화 (Schema Evolution) 실습]
-- Iceberg 의 컬럼 추가는 데이터 파일을 다시 쓰지 않고 메타데이터만 바꿉니다.
-- ----------------------------------------------------------------------------
ALTER ICEBERG TABLE ICB_VEHICLE_REGISTRY ADD COLUMN FIRMWARE_VERSION VARCHAR;

UPDATE ICB_VEHICLE_REGISTRY
SET FIRMWARE_VERSION = IFF(MODEL_NAME = 'EcoTruck-EV', 'v2.4.1', 'v1.8.0');

SELECT VEHICLE_ID, MODEL_NAME, FIRMWARE_VERSION, STATUS 
FROM ICB_VEHICLE_REGISTRY 
ORDER BY VEHICLE_ID;

-- ----------------------------------------------------------------------------
-- 🧹 이 단계까지의 정리: 새 객체 없음 (세션 변수만 사용). 데이터 변경은 98_ C-2 로 함께 사라집니다
-- ----------------------------------------------------------------------------
