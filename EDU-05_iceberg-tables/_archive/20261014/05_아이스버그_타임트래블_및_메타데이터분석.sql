/*
title: 아이스버그 타임트래블 및 메타데이터 분석
step: 05
type: sql
summary: Apache Iceberg의 스냅샷 히스토리, 메타데이터 계층 구조(Metadata -> Manifest List -> Manifest -> Data Parquet)를 분석하고 Snowflake Time Travel 기능을 실습합니다.
requires: 04_아이스버그_테이블생성_및_데이터적재.sql
next: 06_다이나믹_아이스버그_테이블_파이프라인.sql
*/

-- ----------------------------------------------------------------------------
-- [0. Iceberg 메타데이터 및 스냅샷 원리]
--
-- Apache Iceberg는 각 트랜잭션(INSERT, UPDATE, DELETE)이 발생할 때마다
-- 새로운 불변(Immutable) 스냅샷(Snapshot)을 생성합니다.
--
-- 1. 메타데이터 파일 (v1.metadata.json, v2.metadata.json ...) : 스키마, 파티션 사양, 스냅샷 목록
-- 2. 매니페스트 리스트 (snap-*.avro) : 해당 스냅샷을 구성하는 매니페스트 파일 목록
-- 3. 매니페스트 파일 (*.avro) : 실제 Parquet 데이터 파일들의 경로와 컬럼별 통계(Min/Max/Null수)
-- 4. 데이터 파일 (*.parquet) : 실제 데이터가 압축되어 저장된 열 지향 스토리지
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA RAW;

-- ----------------------------------------------------------------------------
-- [1. 데이터 변경 트랜잭션 수행 전 시점 기록]
-- ----------------------------------------------------------------------------

-- 변경 전 데이터 상태 및 건수 확인
SELECT COUNT(*) AS CNT_BEFORE_CHANGE FROM ICB_SENSOR_READINGS;

-- 현재 시점 타임스탬프 저장
SET T_BEFORE_UPDATE = CURRENT_TIMESTAMP();

-- ----------------------------------------------------------------------------
-- [2. 데이터 수정 및 신규 삽입 (스냅샷 발생)]
-- ----------------------------------------------------------------------------

-- 2-1. 특정 차량의 센서 판독치 보정 (UPDATE)
UPDATE ICB_SENSOR_READINGS
SET SPEED_KMH = 0.0, BATTERY_PCT = 100.0
WHERE READING_ID = 'R-001';

-- 2-2. 신규 센서 데이터 추가 (INSERT)
INSERT INTO ICB_SENSOR_READINGS (READING_ID, VEHICLE_ID, RECORDED_AT, SPEED_KMH, BATTERY_PCT, ENGINE_TEMP_C, ODOMETER_KM)
VALUES
    ('R-009', 'VH-1001', '2026-10-14 11:00:00', 75.0, 95.0, 80.0, 12690.0),
    ('R-010', 'VH-2002', '2026-10-14 11:30:00', 60.0, 82.0, 77.0, 18500.0);

-- 현재 변경 후 데이터 확인
SELECT READING_ID, VEHICLE_ID, SPEED_KMH, BATTERY_PCT 
FROM ICB_SENSOR_READINGS 
ORDER BY READING_ID;

-- ----------------------------------------------------------------------------
-- [3. Time Travel 질의 실습]
-- Snowflake의 AT (OFFSET => ...) 또는 AT (TIMESTAMP => ...) 구문으로
-- Iceberg 테이블의 과거 스냅샷 상태를 즉시 복원·조회할 수 있습니다.
-- ----------------------------------------------------------------------------

-- 3-1. 2분 전(과거 스냅샷) 시점의 센서 데이터 조회
SELECT 'PAST_SNAPSHOT' AS SNAPSHOT_TYPE, READING_ID, VEHICLE_ID, SPEED_KMH, BATTERY_PCT
FROM ICB_SENSOR_READINGS AT(OFFSET => -60*2)
WHERE READING_ID = 'R-001';

-- 3-2. 현재 시점 데이터와 과거 시점 데이터 차이 비교
SELECT 
    curr.READING_ID,
    curr.SPEED_KMH AS CURR_SPEED,
    past.SPEED_KMH AS PAST_SPEED,
    curr.BATTERY_PCT AS CURR_BATTERY,
    past.BATTERY_PCT AS PAST_BATTERY
FROM ICB_SENSOR_READINGS curr
LEFT JOIN ICB_SENSOR_READINGS AT(OFFSET => -60*2) past
    ON curr.READING_ID = past.READING_ID
ORDER BY curr.READING_ID;

-- ----------------------------------------------------------------------------
-- [4. 스키마 진화 (Schema Evolution) 실습]
-- Apache Iceberg는 파티션이나 컬럼 변경 시 테이블 전체 리라이트 없이
-- 메타데이터 수정만으로 즉각적인 스키마 진화를 지원합니다.
-- ----------------------------------------------------------------------------

-- 신규 컬럼 추가 (ALTER TABLE ADD COLUMN)
ALTER ICEBERG TABLE ICB_VEHICLE_REGISTRY ADD COLUMN FIRMWARE_VERSION VARCHAR;

-- 신규 컬럼에 값 업데이트
UPDATE ICB_VEHICLE_REGISTRY
SET FIRMWARE_VERSION = 'v2.4.1'
WHERE MODEL_NAME = 'EcoTruck-EV';

UPDATE ICB_VEHICLE_REGISTRY
SET FIRMWARE_VERSION = 'v1.8.0'
WHERE MODEL_NAME != 'EcoTruck-EV';

-- 스키마 진화 후 데이터 확인
SELECT VEHICLE_ID, MODEL_NAME, FIRMWARE_VERSION, STATUS 
FROM ICB_VEHICLE_REGISTRY 
ORDER BY VEHICLE_ID;
