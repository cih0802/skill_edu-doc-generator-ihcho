/*
title: 스토리지 모델 비교 및 외부 볼륨 구성
step: 03
type: sql
summary: Snowflake-Managed Iceberg 스토리지와 Customer-Managed External Volume 스토리지 모델의 차이점을 분석하고, External Volume 및 Storage Integration 아키텍처와 생성 문법을 학습합니다.
requires: 02_사전준비_및_환경설정.sql
next: 04_아이스버그_테이블생성_및_데이터적재.sql
*/

-- ----------------------------------------------------------------------------
-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ [1] ICB_STORAGE_MODEL_DEMO 생성·적재·조회, [3] SHOW EXTERNAL VOLUMES — 실제 실행
--   ⚠️ [2] External Volume 템플릿 A/B — 외부 S3 버킷·IAM 역할이 없어 미실행. 문법은 공식 문서 대조
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- [0. 스토리지 관리 모델 핵심 비교]
--
-- Snowflake에서 Iceberg 테이블을 운용하는 방식은 크게 2가지입니다:
--
-- 1. Snowflake storage (EXTERNAL_VOLUME 생략 = SNOWFLAKE_MANAGED)
--    - 별도의 S3 / Azure Blob 버킷 및 IAM 설정 없이 생성 (AWS·Azure 리전 한정, Gov·중국 리전 불가)
--    - Snowflake 가 Iceberg 데이터·메타데이터 파일을 관리하며, 스토리지 요금은 Snowflake 가 청구
--    - 외부 엔진은 파일 경로가 아니라 Horizon Iceberg REST Catalog 를 통해 접근 (10_ 참고)
--
-- 2. Customer-Managed Storage (External Volume 기반)
--    - 고객사의 자체 S3/GCS/Azure 오브젝트 스토리지에 데이터 및 메타데이터를 저장
--    - EXTERNAL VOLUME 을 생성하여 IAM 신뢰 관계 수립 (Iceberg 테이블은 STORAGE INTEGRATION 을 쓰지 않음)
--    - 타 엔진(Spark, Trino, Flink 등)이 고객사 버킷에서 직접 파일 접근 가능
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA RAW;

-- ----------------------------------------------------------------------------
-- [1. Snowflake-Managed Storage 방식의 동작 원리 확인]
-- Snowflake-Managed 방식은 EXTERNAL_VOLUME 속성을 생략하거나 CATALOG='SNOWFLAKE' 로 지정하여
-- 테이블을 생성하며, 백그라운드에서 Horizon Catalog 가 스토리지 라이프사이클을 통제합니다.
-- ----------------------------------------------------------------------------

-- Snowflake-Managed 테스트용 샘플 Iceberg 테이블 생성
CREATE OR REPLACE ICEBERG TABLE ICB_STORAGE_MODEL_DEMO (
    ID INT,
    MODEL_TYPE VARCHAR,
    DESCRIPTION VARCHAR,
    CREATED_AT TIMESTAMP_NTZ
);

-- 데이터 삽입
INSERT INTO ICB_STORAGE_MODEL_DEMO (ID, MODEL_TYPE, DESCRIPTION, CREATED_AT)
VALUES 
    (1, 'SNOWFLAKE_MANAGED', '클라우드 인프라 설정 없이 즉시 사용 가능한 완전 관리형 오픈 레이크하우스', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ),
    (2, 'CUSTOMER_MANAGED', '자체 S3/GCS/Azure 버킷에 데이터를 보관하며 External Volume으로 연동', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

SELECT * FROM ICB_STORAGE_MODEL_DEMO;

-- ----------------------------------------------------------------------------
-- [2. Customer-Managed External Volume 아키텍처 및 DDL 템플릿]
-- 아래는 AWS S3, Azure Blob, GCS 버킷을 연동할 때 사용하는 EXTERNAL VOLUME 생성 표준 템플릿입니다.
-- (실제 외부 버킷이 없는 실습 환경에서는 구문 학습용으로 참고하며, 실행 시에는 ACCOUNTADMIN 권한 필요)
-- ----------------------------------------------------------------------------

/*
-- [참고 템플릿 A: AWS S3 External Volume 생성 (ACCOUNTADMIN 필요)]
USE ROLE ACCOUNTADMIN;

CREATE EXTERNAL VOLUME IF NOT EXISTS VOL_S3_ICEBERG_STORAGE
    STORAGE_LOCATIONS =
    (
        (
            NAME = 'my-s3-iceberg-us-west-2'
            STORAGE_PROVIDER = 'S3'
            STORAGE_BASE_URL = 's3://my-customer-iceberg-bucket/lakehouse/'
            STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake_iceberg_s3_role'
            STORAGE_AWS_EXTERNAL_ID = 'iceberg_lab_ext_id'
        )
    )
    COMMENT = 'AWS S3 기반 Customer-Managed Iceberg 스토리지 볼륨';

-- 신뢰 관계 수립용 Snowflake IAM User 및 External ID 확인
DESCRIBE EXTERNAL VOLUME VOL_S3_ICEBERG_STORAGE;

-- 실습 역할에 볼륨 사용 권한 부여
GRANT USAGE ON EXTERNAL VOLUME VOL_S3_ICEBERG_STORAGE TO ROLE ICEBERG_LAB_RL;
*/

/*
-- [참고 템플릿 B: External Volume을 이용한 Iceberg 테이블 생성]
USE ROLE ICEBERG_LAB_RL;

CREATE OR REPLACE ICEBERG TABLE ICB_CUSTOMER_MANAGED_TABLE (
    RECORD_ID VARCHAR,
    SENSOR_VAL DOUBLE,
    RECORD_TIME TIMESTAMP_NTZ
)
EXTERNAL_VOLUME = 'VOL_S3_ICEBERG_STORAGE'
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'customer_sensor_data/';
*/

-- ----------------------------------------------------------------------------
-- [3. Storage Integration vs External Volume 개념 정리]
-- - STORAGE INTEGRATION : 기존 External Stage 및 External Table에서 S3/Azure/GCS 자격증명을 관리하던 객체
-- - EXTERNAL VOLUME      : Iceberg Table을 위해 도입된 전용 스토리지 객체 (Read/Write 양방향 지원)
-- ----------------------------------------------------------------------------

-- 현재 계정의 External Volume 목록 조회
SHOW EXTERNAL VOLUMES;

-- ----------------------------------------------------------------------------
-- [4. 본 실습의 진행 방식]
-- 본 가이드(EDU-05)의 후속 실습(04~10)은 Snowflake storage 를 기본으로 진행하므로
-- 외부 IAM 설정이 필요 없습니다. 02_ [0] 리전 게이트가 PASS 인 계정이 전제입니다.
-- (2026-10-14 트라이얼 계정 AWS_AP_NORTHEAST_1 에서 04~10 실행 확인)
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 🧹 이 단계까지의 정리: ICB_STORAGE_MODEL_DEMO 는 98_ C-2(DB 삭제)로 함께 삭제됩니다
-- ----------------------------------------------------------------------------
