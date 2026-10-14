/*
title: 스노우파크 및 고급 변환
step: 07
type: sql
summary: Snowpark Python DataFrame API를 활용하여 Iceberg 원천 테이블의 데이터를 프로그래밍 방식으로 조인, 정제 및 이상 징후 판별 로직을 적용하여 Iceberg 타깃 테이블에 적재합니다.
requires: 06_다이나믹_아이스버그_테이블_파이프라인.sql
next: 08_데이터거버넌스_보안정책.sql
*/

-- ----------------------------------------------------------------------------
-- [0. 실습 개요 및 Snowpark + Iceberg 결합의 이점]
--
-- Snowpark Python은 Python의 강력한 표현력을 유지하면서,
-- 데이터 이동 없이 Snowflake 웨어하우스 엔진에서 Iceberg 테이블을 직접 조작합니다.
-- 1. 복잡한 비즈니스 로직(예: 배터리/온도 복합 이상치 감지)을 파이썬 함수로 구현
-- 2. DataFrame을 활용해 타입 세이프한 파이프라인 구축
-- 3. 처리 결과를 대상 Iceberg 테이블에 안전하게 Append / Merge
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA TRANSFORM;

-- ----------------------------------------------------------------------------
-- [1. Snowpark 처리 결과 저장용 Iceberg 테이블 사전 생성]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE ICB_SNOWPARK_ENRICHED (
    READING_ID VARCHAR,
    VEHICLE_ID VARCHAR,
    MODEL_NAME VARCHAR,
    VIN VARCHAR,
    REGION_CODE VARCHAR,
    RECORDED_AT TIMESTAMP_NTZ,
    SPEED_KMH DOUBLE,
    BATTERY_PCT DOUBLE,
    ENGINE_TEMP_C DOUBLE,
    HEALTH_STATUS VARCHAR
);

-- ----------------------------------------------------------------------------
-- [2. Snowpark Python 저장 프로시저 정의]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_TRANSFORM_ICEBERG_TELEMETRY()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'transform_telemetry'
COMMENT = 'Snowpark Python 기반 Iceberg 테이블 원천 정제 및 이상치 탐지 프로시저'
AS
$$
import snowflake.snowpark.functions as F

def transform_telemetry(session):
    # 1. Iceberg 원천 테이블을 Snowpark DataFrame으로 로드
    df_sensors = session.table("ICEBERG_LAB_DB.RAW.ICB_SENSOR_READINGS")
    df_vehicles = session.table("ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY")
    
    # 2. DataFrame 조인 및 파이썬 파생 컬럼 생성 (헬스 상태 분류)
    df_joined = df_sensors.join(
        df_vehicles,
        df_sensors["VEHICLE_ID"] == df_vehicles["VEHICLE_ID"]
    ).select(
        df_sensors["READING_ID"],
        df_sensors["VEHICLE_ID"],
        df_vehicles["MODEL_NAME"],
        df_vehicles["VIN"],
        df_vehicles["REGION_CODE"],
        df_sensors["RECORDED_AT"],
        df_sensors["SPEED_KMH"],
        df_sensors["BATTERY_PCT"],
        df_sensors["ENGINE_TEMP_C"],
        F.when(df_sensors["BATTERY_PCT"] < 80.0, "BATTERY_WARNING")
         .when(df_sensors["ENGINE_TEMP_C"] > 85.0, "TEMP_WARNING")
         .otherwise("NORMAL").alias("HEALTH_STATUS")
    )
    
    # 3. 정제된 결과를 대상 Iceberg 테이블에 저장
    df_joined.write.mode("append").save_as_table("ICEBERG_LAB_DB.TRANSFORM.ICB_SNOWPARK_ENRICHED")
    
    return "SUCCESS: Transformed telemetry appended to Iceberg table"
$$;

-- ----------------------------------------------------------------------------
-- [3. 프로시저 실행 및 결과 검증]
-- ----------------------------------------------------------------------------
CALL SP_TRANSFORM_ICEBERG_TELEMETRY();

-- 저장된 Iceberg 테이블 데이터 확인
SELECT 
    READING_ID,
    VEHICLE_ID,
    MODEL_NAME,
    HEALTH_STATUS,
    BATTERY_PCT,
    ENGINE_TEMP_C
FROM ICB_SNOWPARK_ENRICHED
ORDER BY RECORDED_AT;
