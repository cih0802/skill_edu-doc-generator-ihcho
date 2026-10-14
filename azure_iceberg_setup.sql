-- ============================================================
-- Azure Parquet → Iceberg 테이블 생성 (External Volume 방식)
-- ============================================================
-- A경로 (원본): azure://damadfstoragetest01.blob.core.windows.net/landing/erp/
-- B경로 (Iceberg): azure://damadfstoragetest01.blob.core.windows.net/iceberg/raw/
-- ============================================================

-- 1. Storage Integration 생성 (A경로 + B경로 모두 허용)
CREATE OR REPLACE STORAGE INTEGRATION azure_parquet_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'AZURE'
  AZURE_TENANT_ID = '20dba212-5442-4fc6-82cb-accf2ed36903'
  ENABLED = TRUE
  STORAGE_ALLOWED_LOCATIONS = (
    'azure://damadfstoragetest01.blob.core.windows.net/landing/erp/',
    'azure://damadfstoragetest01.blob.core.windows.net/iceberg/raw/'
  );

-- Azure 콘센트 URL 및 서비스 프린시펄 확인
DESC INTEGRATION azure_parquet_int;
-- AZURE_CONSENT_URL → 브라우저에서 열고 Accept
-- AZURE_MULTI_TENANT_APP_NAME → Azure IAM에서 역할 할당 시 검색용

-- ============================================================
-- [Azure Portal 작업 필요]
-- Storage Account: damadfstoragetest01 → Access Control (IAM)
-- Role: Storage Blob Data Contributor
-- Member: AZURE_MULTI_TENANT_APP_NAME 언더스코어 앞부분으로 검색
-- ============================================================

-- 2. External Volume 생성 (B경로, 쓰기 허용)
CREATE OR REPLACE EXTERNAL VOLUME iceberg_azure_vol
  STORAGE_LOCATIONS = ((
    NAME = 'azure-iceberg-raw'
    STORAGE_PROVIDER = 'AZURE'
    STORAGE_BASE_URL = 'azure://damadfstoragetest01.blob.core.windows.net/iceberg/raw/'
    AZURE_TENANT_ID = '20dba212-5442-4fc6-82cb-accf2ed36903'
  ))
  ALLOW_WRITES = TRUE;

DESC EXTERNAL VOLUME iceberg_azure_vol;

-- 3. External Stage 생성 (A경로 원본 Parquet 읽기)
CREATE OR REPLACE STAGE PFL_DB.PUBLIC.azure_parquet_stage
  STORAGE_INTEGRATION = azure_parquet_int
  URL = 'azure://damadfstoragetest01.blob.core.windows.net/landing/erp/'
  FILE_FORMAT = (TYPE = PARQUET);

-- 파일 목록 확인
LIST @PFL_DB.PUBLIC.azure_parquet_stage;

-- 4. Parquet File Format 생성 (INFER_SCHEMA용)
CREATE OR REPLACE FILE FORMAT PFL_DB.PUBLIC.parquet_ff TYPE = PARQUET;

-- 5. Parquet 스키마 추론
SELECT COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@PFL_DB.PUBLIC.azure_parquet_stage/parquet_actionlog_20261008_01.parquet',
    FILE_FORMAT => 'PFL_DB.PUBLIC.parquet_ff'
  )
);

-- 6. Iceberg 테이블 생성 (External Volume 사용 → B경로에 저장)
CREATE ICEBERG TABLE IF NOT EXISTS PFL_DB.PUBLIC.ICEBERG_TBL_TEST (
  LOGGED_TIME TIMESTAMP_NTZ,
  MACHINE STRING,
  USER_NAME STRING,
  ORIGINAL_TIME TIMESTAMP_NTZ,
  ORIGINAL_IP STRING,
  LOG_CATEGORY STRING,
  LOG_ACTION STRING,
  SUCCESS STRING,
  SESSION_ID STRING,
  ID1 STRING,
  ID2 STRING,
  ARG1 STRING,
  ARG2 STRING,
  ARG3 STRING,
  ARG4 STRING,
  ARG5 STRING,
  ARG6 STRING
)
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'iceberg_azure_vol'
  BASE_LOCATION = 'iceberg_tbl_test';

-- 7. Parquet 데이터 로드
COPY INTO PFL_DB.PUBLIC.ICEBERG_TBL_TEST
FROM @PFL_DB.PUBLIC.azure_parquet_stage/parquet_actionlog_20261008_01.parquet
  FILE_FORMAT = (TYPE = PARQUET)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- 8. 데이터 검증
SELECT COUNT(*) AS total_rows FROM PFL_DB.PUBLIC.ICEBERG_TBL_TEST;
SELECT * FROM PFL_DB.PUBLIC.ICEBERG_TBL_TEST LIMIT 10;
