/*
title: 외부 엔진 연동 및 의미론적 계층
step: 10
type: sql
summary: Snowflake Horizon Catalog를 통해 Iceberg 메타데이터를 외부 쿼리 엔진(DuckDB, Apache Spark)에서 직접 질의하는 방법과 Cortex AI / BI 연동을 위한 시맨틱 뷰 계층을 구성합니다.
requires: 09_데이터공유_및_협업.sql
next: 98_리소스정리.sql
*/

-- ----------------------------------------------------------------------------
-- [0. 실습 개요 및 멀티 엔진 상호운용성]
--
-- Snowflake Horizon Catalog는 Iceberg 오픈 표준 REST 카탈로그 인터페이스를 제공하여
-- Snowflake에 저장된 Iceberg 테이블을 타 엔진에서도 단일 진실 공급원(Single Source of Truth)으로
-- 복제 없이 직접 읽을 수 있도록 지원합니다.
--
-- 1. DuckDB / Python : SYSTEM$GET_ICEBERG_TABLE_INFORMATION 메타데이터 위치로 직접 쿼리
-- 2. Apache Spark    : Snowflake Horizon Catalog REST Endpoint 연결
-- 3. Semantic Layer  : Cortex AI Analyst 및 BI 대시보드 연동용 비즈니스 의미론적 뷰
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA TRANSFORM;

-- ----------------------------------------------------------------------------
-- [1. 의미론적 계층(Semantic Layer) 뷰 정의]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_FLEET_SEMANTIC_LAYER AS
SELECT 
    v.VEHICLE_ID,
    v.MODEL_NAME,
    v.REGION_CODE,
    v.STATUS AS VEHICLE_STATUS,
    d.SUMMARY_DATE,
    d.AVG_SPEED_KMH,
    d.AVG_BATTERY_PCT,
    d.AVG_ENGINE_TEMP_C,
    d.TOTAL_DISTANCE_KM
FROM ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY v
LEFT JOIN ICEBERG_LAB_DB.TRANSFORM.DIT_DAILY_FLEET_SUMMARY d
    ON v.MODEL_NAME = d.MODEL_NAME AND v.REGION_CODE = d.REGION_CODE;

SELECT * FROM V_FLEET_SEMANTIC_LAYER ORDER BY VEHICLE_ID;

-- ----------------------------------------------------------------------------
-- [2. DuckDB 연동을 위한 메타데이터 경로 추출 가이드]
-- ----------------------------------------------------------------------------

-- Snowflake에서 메타데이터 JSON 파일 S3/스토리지 경로 확인
SELECT 
    PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY'))['metadataLocation']::VARCHAR AS METADATA_PATH;

/*
-- [DuckDB Python 연동 예시 코드 (로컬 또는 노트북 환경)]
import duckdb

conn = duckdb.connect()
# AWS 인증 정보 또는 스테이지 자격 증명 설정
conn.execute("""
    INSTALL iceberg;
    LOAD iceberg;
    INSTALL httpfs;
    LOAD httpfs;
""")

# 추출한 metadata.json 파일 경로를 직접 조회
# metadata_url = 's3://.../00000-xxx.metadata.json'
# df = conn.execute(f"SELECT * FROM iceberg_scan('{metadata_url}')").fetchdf()
# print(df.head())
*/

-- ----------------------------------------------------------------------------
-- [3. Apache Spark / Horizon REST Catalog 연동 가이드]
-- ----------------------------------------------------------------------------

/*
-- [Apache Spark conf 설정 템플릿 (Spark 3.5+ / 4.0)]
spark-sql \
  --packages org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.5.0 \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.snowflake_horizon=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.snowflake_horizon.type=rest \
  --conf spark.sql.catalog.snowflake_horizon.uri=https://<account_id>.snowflakecomputing.com/polaris/api/catalog \
  --conf spark.sql.catalog.snowflake_horizon.credential=<client_id>:<client_secret> \
  --conf spark.sql.catalog.snowflake_horizon.warehouse=ICEBERG_LAB_DB

-- Spark 질의 실행:
-- SELECT * FROM snowflake_horizon.RAW.ICB_VEHICLE_REGISTRY WHERE REGION_CODE = 'KR-SEOUL';
*/

-- ----------------------------------------------------------------------------
-- [4. 통합 질의 및 최종 실습 완주 확인]
-- ----------------------------------------------------------------------------
SELECT 
    'SUCCESS' AS LAB_STATUS,
    COUNT(*) AS TOTAL_ACTIVE_VEHICLES,
    CURRENT_TIMESTAMP() AS COMPLETED_AT
FROM V_FLEET_SEMANTIC_LAYER
WHERE VEHICLE_STATUS = 'ACTIVE';
