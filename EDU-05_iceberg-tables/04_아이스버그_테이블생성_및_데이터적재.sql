/*
title: 아이스버그 테이블 생성 및 데이터 적재
step: 04
type: sql
summary: 정형 마스터 데이터, 시계열 IoT 센서 데이터, 반정형 JSON 정비 로그를 위한 Iceberg 테이블을 생성하고 원천 데이터를 적재 및 검증합니다.
requires: 03_스토리지모델_비교_및_외부볼륨구성.sql
next: 05_아이스버그_타임트래블_및_메타데이터분석.sql
*/

-- ----------------------------------------------------------------------------
-- [0. 실습 개요 및 스키마 설계]
--
-- 본 실습에서는 커넥티드 차량 및 물류 플릿(Fleet) 시나리오를 바탕으로
-- 3종류의 핵심 Iceberg 테이블을 구성합니다:
--
-- 1. ICB_VEHICLE_REGISTRY (정형 마스터) : 차량 고유 ID, 모델, 제조년도, 차대번호(VIN), 지역 코드
-- 2. ICB_SENSOR_READINGS  (시계열 IoT) : 차량 ID, 타임스탬프, 속도, 배터리 잔량, 엔진 온도
-- 3. ICB_MAINTENANCE_LOGS (반정형 JSON) : 정비 내역 로그 (JSON 문자열 저장 후 PARSE_JSON 활용)
--
-- 💡 Iceberg 테이블 DDL 핵심 규칙:
-- - 문자열 컬럼은 길이 제한(예: VARCHAR(50)) 대신 비모수 VARCHAR 또는 STRING 타입을 사용합니다.
-- - 오픈 아파치 아이스버그 호환성을 위해 유연한 스키마 정의를 따릅니다.
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA RAW;

-- ----------------------------------------------------------------------------
-- [1. Iceberg 테이블 DDL 정의]
-- Snowflake-Managed Iceberg 테이블은 일반 테이블과 동일하게 CREATE ICEBERG TABLE DDL로 생성됩니다.
-- ----------------------------------------------------------------------------

-- 1-1. 차량 등록 마스터 Iceberg 테이블
CREATE OR REPLACE ICEBERG TABLE ICB_VEHICLE_REGISTRY (
    VEHICLE_ID VARCHAR,
    MODEL_NAME VARCHAR,
    MANUFACTURE_YEAR INT,
    VIN VARCHAR,
    REGION_CODE VARCHAR,
    STATUS VARCHAR,
    REGISTERED_DATE DATE
);

-- 1-2. 시계열 IoT 센서 데이터 Iceberg 테이블
CREATE OR REPLACE ICEBERG TABLE ICB_SENSOR_READINGS (
    READING_ID VARCHAR,
    VEHICLE_ID VARCHAR,
    RECORDED_AT TIMESTAMP_NTZ,
    SPEED_KMH DOUBLE,
    BATTERY_PCT DOUBLE,
    ENGINE_TEMP_C DOUBLE,
    ODOMETER_KM DOUBLE
);

-- 1-3. 반정형 JSON 정비 이력 Iceberg 테이블
CREATE OR REPLACE ICEBERG TABLE ICB_MAINTENANCE_LOGS (
    LOG_ID VARCHAR,
    VEHICLE_ID VARCHAR,
    MAINTENANCE_DATE DATE,
    DETAILS VARCHAR
);

-- ----------------------------------------------------------------------------
-- [2. 데이터 적재 (Data Ingestion)]
-- ----------------------------------------------------------------------------

-- 2-1. 차량 마스터 데이터 삽입 (정형)
INSERT INTO ICB_VEHICLE_REGISTRY (VEHICLE_ID, MODEL_NAME, MANUFACTURE_YEAR, VIN, REGION_CODE, STATUS, REGISTERED_DATE)
VALUES
    ('VH-1001', 'EcoTruck-EV', 2024, '1HGCR2F83HA001001', 'KR-SEOUL', 'ACTIVE', '2024-01-15'),
    ('VH-1002', 'EcoTruck-EV', 2024, '1HGCR2F83HA001002', 'KR-SEOUL', 'ACTIVE', '2024-01-20'),
    ('VH-2001', 'CityVan-Hybrid', 2023, '2HKRM4H75NH002001', 'KR-BUSAN', 'ACTIVE', '2023-06-10'),
    ('VH-2002', 'CityVan-Hybrid', 2023, '2HKRM4H75NH002002', 'KR-BUSAN', 'MAINTENANCE', '2023-07-05'),
    ('VH-3001', 'HeavyFreight-D', 2022, '3VW2B7AJ9KM003001', 'KR-INCHEON', 'ACTIVE', '2022-11-01');

-- 2-2. IoT 센서 시계열 데이터 삽입
INSERT INTO ICB_SENSOR_READINGS (READING_ID, VEHICLE_ID, RECORDED_AT, SPEED_KMH, BATTERY_PCT, ENGINE_TEMP_C, ODOMETER_KM)
VALUES
    ('R-001', 'VH-1001', '2026-10-14 08:00:00', 65.5, 92.0, 78.5, 12540.2),
    ('R-002', 'VH-1001', '2026-10-14 09:00:00', 82.0, 84.5, 82.1, 12615.8),
    ('R-003', 'VH-1002', '2026-10-14 08:30:00', 45.0, 88.0, 75.0, 8420.0),
    ('R-004', 'VH-1002', '2026-10-14 09:30:00', 70.2, 79.0, 80.4, 8485.5),
    ('R-005', 'VH-2001', '2026-10-14 08:15:00', 55.0, 95.0, 72.0, 24100.1),
    ('R-006', 'VH-2001', '2026-10-14 10:00:00', 0.0,  91.0, 68.0, 24145.3),
    ('R-007', 'VH-3001', '2026-10-14 07:00:00', 90.0, 70.0, 88.0, 54200.0),
    ('R-008', 'VH-3001', '2026-10-14 09:45:00', 88.5, 58.0, 91.5, 54410.2);

-- 2-3. 반정형 JSON 정비 로그 데이터 삽입
INSERT INTO ICB_MAINTENANCE_LOGS (LOG_ID, VEHICLE_ID, MAINTENANCE_DATE, DETAILS)
VALUES
    ('ML-101', 'VH-1001', '2026-09-10'::DATE, '{"service_type": "REGULAR_INSPECTION", "technician": "Kim Min-soo", "cost_krw": 250000, "diagnostics": {"battery_health_pct": 98.5}}'),
    ('ML-102', 'VH-2002', '2026-10-01'::DATE, '{"service_type": "EMERGENCY_REPAIR", "technician": "Park Ji-hoon", "cost_krw": 480000, "diagnostics": {"battery_health_pct": 89.0}}');

-- ----------------------------------------------------------------------------
-- [3. 적재 결과 검증 및 JSON 필드 질의]
-- ----------------------------------------------------------------------------
SELECT * FROM ICB_VEHICLE_REGISTRY ORDER BY VEHICLE_ID;
SELECT * FROM ICB_SENSOR_READINGS ORDER BY RECORDED_AT;

-- Iceberg 테이블의 JSON 문자열 필드를 PARSE_JSON으로 파싱하여 정형 컬럼처럼 질의
SELECT 
    LOG_ID,
    VEHICLE_ID,
    MAINTENANCE_DATE,
    PARSE_JSON(DETAILS):service_type::VARCHAR AS SERVICE_TYPE,
    PARSE_JSON(DETAILS):technician::VARCHAR AS TECHNICIAN,
    PARSE_JSON(DETAILS):cost_krw::NUMBER AS COST_KRW,
    PARSE_JSON(DETAILS):diagnostics.battery_health_pct::DOUBLE AS BATTERY_HEALTH_PCT
FROM ICB_MAINTENANCE_LOGS;

-- ----------------------------------------------------------------------------
-- [4. Iceberg 메타데이터 정보 조회 내장 함수]
-- Snowflake 내장 함수 SYSTEM$GET_ICEBERG_TABLE_INFORMATION을 통해
-- Iceberg 메타데이터 파일 위치 및 스냅샷 사양을 파싱합니다.
-- ----------------------------------------------------------------------------
SELECT 
    PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICB_VEHICLE_REGISTRY')) AS REGISTRY_ICEBERG_META,
    PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICB_SENSOR_READINGS')) AS SENSOR_ICEBERG_META,
    PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICB_MAINTENANCE_LOGS')) AS MAINTENANCE_ICEBERG_META;
