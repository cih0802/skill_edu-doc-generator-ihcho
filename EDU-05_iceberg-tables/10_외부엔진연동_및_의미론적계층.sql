/*
title: 외부 엔진 연동 및 의미론적 계층
step: 10
type: sql
summary: Iceberg 테이블 위에 실제 Semantic View(CREATE SEMANTIC VIEW)를 정의해 SEMANTIC_VIEW() 로 질의하고, 외부 엔진(Spark/PyIceberg/DuckDB)이 Horizon Iceberg REST Catalog 를 통해 같은 테이블에 접근하는 구성을 학습합니다.
requires: 09_데이터공유_및_협업.sql
next: 98_리소스정리.sql
*/

-- ----------------------------------------------------------------------------
-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ [1] CREATE SEMANTIC VIEW, SHOW SEMANTIC VIEWS, SEMANTIC_VIEW() 질의 — 실제 실행
--   ✅ [2] SYSTEM$GET_ICEBERG_TABLE_INFORMATION 으로 메타데이터 위치 확인 — 실제 실행
--   ⚠️ [3] 외부 엔진 연결 — 외부 Spark/Python 환경과 PAT 발급(자격증명)이 필요해 미실행.
--          URI·scope 형식은 공식 문서 "Access Apache Iceberg tables with an external engine
--          through Snowflake Horizon Catalog" 와 대조
--   ℹ️  1차 판의 오류 2건을 정정했습니다
--      ① "Semantic View" 라고 했으나 일반 VIEW 였음 → 실제 CREATE SEMANTIC VIEW 로 교체
--      ② DuckDB 가 metadataLocation 경로를 직접 iceberg_scan 한다고 서술 → Snowflake storage 의
--         경로는 Snowflake 내부 버킷(실측 s3://sfc-…-customer-interop-…)이라 사용자 자격증명으로 읽을 수 없음.
--         외부 엔진은 Horizon Iceberg REST Catalog(vended credentials)로 접근해야 함
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA TRANSFORM;

-- ----------------------------------------------------------------------------
-- [1. 의미론적 계층 — Semantic View]
-- Semantic View 는 테이블·관계·차원·지표의 비즈니스 의미를 스키마 객체로 정의합니다.
-- Cortex Analyst / Cortex Agent / BI 가 같은 정의를 공유하므로 지표 계산이 도구마다 갈라지지 않습니다.
-- 💡 원천이 Iceberg 테이블이어도 정의 방식은 일반 테이블과 같고, 08_ 의 마스킹·행 정책도 그대로 적용됩니다.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW ICEBERG_LAB_DB.TRANSFORM.SEM_FLEET_ANALYTICS
    TABLES (
        vehicles AS ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY
            PRIMARY KEY (VEHICLE_ID)
            COMMENT = '차량 마스터 (Iceberg)',
        readings AS ICEBERG_LAB_DB.RAW.ICB_SENSOR_READINGS
            PRIMARY KEY (READING_ID)
            COMMENT = 'IoT 센서 판독 (Iceberg)'
    )
    RELATIONSHIPS (
        readings_to_vehicles AS readings (VEHICLE_ID) REFERENCES vehicles
    )
    FACTS (
        readings.speed_kmh   AS SPEED_KMH,
        readings.battery_pct AS BATTERY_PCT
    )
    DIMENSIONS (
        vehicles.region_code  AS REGION_CODE  COMMENT = '운행 지역 코드 (예: KR-SEOUL)',
        vehicles.model_name   AS MODEL_NAME   COMMENT = '차종',
        vehicles.status       AS STATUS       COMMENT = '차량 상태 (ACTIVE/MAINTENANCE)',
        readings.reading_date AS RECORDED_AT::DATE COMMENT = '판독 일자'
    )
    METRICS (
        readings.reading_count   AS COUNT(readings.READING_ID)  COMMENT = '센서 판독 건수',
        readings.avg_speed_kmh   AS AVG(readings.speed_kmh)     COMMENT = '평균 속도',
        readings.avg_battery_pct AS AVG(readings.battery_pct)   COMMENT = '평균 배터리 잔량',
        vehicles.vehicle_count   AS COUNT(DISTINCT vehicles.VEHICLE_ID) COMMENT = '차량 수'
    )
    COMMENT = 'EDU-05 Iceberg 플릿 데이터 의미론적 계층';

SHOW SEMANTIC VIEWS IN SCHEMA ICEBERG_LAB_DB.TRANSFORM;

-- 지역별 지표 질의 (기대: KR-SEOUL/KR-BUSAN/KR-INCHEON 3행)
SELECT * FROM SEMANTIC_VIEW(
    ICEBERG_LAB_DB.TRANSFORM.SEM_FLEET_ANALYTICS
    DIMENSIONS vehicles.region_code
    METRICS readings.reading_count, readings.avg_speed_kmh, readings.avg_battery_pct
)
ORDER BY region_code;

-- ----------------------------------------------------------------------------
-- [2. 외부 엔진 접근의 전제 — 메타데이터 위치 확인]
-- Snowflake storage 테이블의 메타데이터 경로는 Snowflake 가 관리하는 버킷입니다.
-- 이 경로를 외부 엔진에 직접 넘기는 방식은 동작하지 않습니다 (자격증명이 없음).
-- ----------------------------------------------------------------------------
SELECT PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY')):metadataLocation::VARCHAR AS METADATA_PATH;

-- 외부 엔진 연결에 쓰는 계정 식별자
SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS ACCOUNT_IDENTIFIER;

-- ----------------------------------------------------------------------------
-- [3. 외부 엔진 → Horizon Iceberg REST Catalog 연결 템플릿]  ⚠️ 미실행
--
-- 절차 (공식 문서 워크플로):
--   ① 외부 엔진용 역할에 DB/스키마 USAGE + 테이블 SELECT 부여
--   ② 해당 역할로 접근 토큰 발급 (PAT 또는 External OAuth)
--      🔴 PAT 는 실제로 쓰이는 자격증명입니다. 값을 문서·채팅·노트북 출력에 남기지 마십시오.
--         발급했다면 ALTER USER … REMOVE PROGRAMMATIC ACCESS TOKEN 으로 폐기합니다
--   ③ 엔진에 URI + 토큰 + scope(session:role:<역할>) + warehouse(=DB 이름, 대문자) 설정
--   ④ 08_ 의 정책은 외부 엔진 조회에도 적용됩니다 (Data protection policy enforcement from Apache Spark)
--   ⚠️ 04_ 의 ICB_MAINTENANCE_LOGS 는 Iceberg v3 이므로 v3 를 지원하는 엔진 버전이 필요합니다
-- ----------------------------------------------------------------------------

/*
# [PySpark 예시 — Horizon IRC, PAT 인증]
from pyspark.sql import SparkSession

CATALOG_URI  = "https://<account_identifier>.snowflakecomputing.com/polaris/api/catalog"
ROLE         = "ICEBERG_LAB_RL"
CATALOG_NAME = "ICEBERG_LAB_DB"          # SHOW DATABASES 결과와 같은 대소문자
ACCESS_TOKEN = "<PAT — 환경변수/시크릿 저장소에서 읽을 것>"

spark = (
    SparkSession.builder
    .config("spark.jars.packages", "org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:<iceberg_version>,"
                                   "org.apache.iceberg:iceberg-aws-bundle:<iceberg_version>")
    .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
    .config("spark.sql.catalog.horizon", "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.horizon.type", "rest")
    .config("spark.sql.catalog.horizon.uri", CATALOG_URI)
    .config("spark.sql.catalog.horizon.warehouse", CATALOG_NAME)
    .config("spark.sql.catalog.horizon.token", ACCESS_TOKEN)
    .config("spark.sql.catalog.horizon.scope", f"session:role:{ROLE}")
    .config("spark.sql.catalog.horizon.header.X-Iceberg-Access-Delegation", "vended-credentials")
    .getOrCreate()
)

spark.sql("SELECT * FROM horizon.RAW.ICB_VEHICLE_REGISTRY WHERE REGION_CODE = 'KR-SEOUL'").show()

# DuckDB / PyIceberg 도 같은 REST 엔드포인트·토큰·scope 로 연결합니다 (엔진별 설정 키는 각 엔진 문서 참고).
*/

-- ----------------------------------------------------------------------------
-- [4. 최종 결과 확인 — 실습 산출물 상태 점검]
-- 각 행의 OBSERVED 가 EXPECTED 와 같아야 합니다
-- ----------------------------------------------------------------------------
SELECT 'Iceberg 원천 센서 행' AS CHECK_ITEM, 11 AS EXPECTED, (SELECT COUNT(*) FROM ICEBERG_LAB_DB.RAW.ICB_SENSOR_READINGS) AS OBSERVED
UNION ALL SELECT 'Dynamic Iceberg Tier1 행', 11, (SELECT COUNT(*) FROM ICEBERG_LAB_DB.TRANSFORM.DIT_ENRICHED_TELEMETRY)
UNION ALL SELECT 'Snowpark 적재 행',         11, (SELECT COUNT(*) FROM ICEBERG_LAB_DB.TRANSFORM.ICB_SNOWPARK_ENRICHED)
UNION ALL SELECT 'Semantic View 지역 수',     3, (SELECT COUNT(*) FROM SEMANTIC_VIEW(ICEBERG_LAB_DB.TRANSFORM.SEM_FLEET_ANALYTICS DIMENSIONS vehicles.region_code METRICS readings.reading_count));

-- ----------------------------------------------------------------------------
-- 🧹 이 단계까지의 정리: Semantic View 는 98_ C-2(DB 삭제)로 함께 삭제됩니다.
--    [3] 을 실제로 수행해 PAT 를 발급했다면 98_ PART C-0 에서 폐기하십시오
-- ----------------------------------------------------------------------------
