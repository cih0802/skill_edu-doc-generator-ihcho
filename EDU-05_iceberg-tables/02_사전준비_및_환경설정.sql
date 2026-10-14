/*
title: 사전 준비 및 환경 설정
step: 02
type: sql
summary: Iceberg 실습을 위한 전용 관리자/분석가 역할, 웨어하우스, 데이터베이스, 스키마 및 파일 스테이지를 생성하고 사전 상태 스냅샷을 기록합니다.
requires: 01_교육자료_정리본.md
next: 03_스토리지모델_비교_및_외부볼륨구성.sql
*/

-- ----------------------------------------------------------------------------
-- [0. 사전 안내 및 주의사항]
-- 이 스크립트는 ACCOUNTADMIN 권한으로 실행하여 실습 전용 역할과 인프라를 프로비저닝합니다.
-- 최소 권한 원칙(Least Privilege)에 따라 인프라 생성 후 본 실습은 ICEBERG_LAB_RL 로 진행합니다.
-- ----------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- [1. 사전 스냅샷 기록]
-- 실습 시작 전 기존 객체 상태를 기록하여 98_리소스정리 후 잔여물 여부를 대조합니다.
-- ----------------------------------------------------------------------------
SHOW ROLES LIKE 'ICEBERG_%';
SHOW WAREHOUSES LIKE 'ICEBERG_%';
SHOW DATABASES LIKE 'ICEBERG_%';

-- ----------------------------------------------------------------------------
-- [2. 실습 전용 역할(Role) 생성 및 권한 부여]
-- ----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS ICEBERG_LAB_RL
    COMMENT = 'EDU-05 Apache Iceberg 실습 전용 관리자 역할';

CREATE ROLE IF NOT EXISTS ICEBERG_ANALYST_RL
    COMMENT = 'EDU-05 거버넌스 및 행/열 보안 검증용 분석가 역할';

-- 관리자 계층 구조 연결 (SYSADMIN 하위에 실습 역할 배치)
GRANT ROLE ICEBERG_LAB_RL TO ROLE SYSADMIN;
GRANT ROLE ICEBERG_ANALYST_RL TO ROLE ICEBERG_LAB_RL;

-- 현재 작업 사용자에게 역할 부여 (TRIALADMIN / CURRENT_USER)
SET MY_USER = CURRENT_USER();
GRANT ROLE ICEBERG_LAB_RL TO USER IDENTIFIER($MY_USER);
GRANT ROLE ICEBERG_ANALYST_RL TO USER IDENTIFIER($MY_USER);

-- ----------------------------------------------------------------------------
-- [3. 전용 웨어하우스(Warehouse) 생성]
-- 비용 최소화를 위해 XSMALL 크기 및 60초 자동 중지 설정
-- ----------------------------------------------------------------------------
CREATE OR REPLACE WAREHOUSE ICEBERG_LAB_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'EDU-05 Apache Iceberg 실습 전용 컴퓨팅 웨어하우스';

GRANT USAGE, OPERATE ON WAREHOUSE ICEBERG_LAB_WH TO ROLE ICEBERG_LAB_RL;
GRANT USAGE ON WAREHOUSE ICEBERG_LAB_WH TO ROLE ICEBERG_ANALYST_RL;

-- ----------------------------------------------------------------------------
-- [4. 데이터베이스 및 스키마 생성]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE DATABASE ICEBERG_LAB_DB
    COMMENT = 'EDU-05 Apache Iceberg 실습 전용 데이터베이스';

-- 원천 데이터 및 Iceberg 테이블용 스키마
CREATE OR REPLACE SCHEMA ICEBERG_LAB_DB.RAW
    COMMENT = '원천 데이터 및 기본 Iceberg 테이블 스키마';

-- 가공 및 다이나믹 테이블용 스키마
CREATE OR REPLACE SCHEMA ICEBERG_LAB_DB.TRANSFORM
    COMMENT = 'Dynamic Iceberg Tables 및 Snowpark 변환 스키마';

-- 보안 및 거버넌스 정책 스키마
CREATE OR REPLACE SCHEMA ICEBERG_LAB_DB.GOVERNANCE
    COMMENT = 'Row Access/Masking Policy 및 Secure View 스키마';

-- 실습 역할에 DB 및 스키마 권한 위임
GRANT ALL ON DATABASE ICEBERG_LAB_DB TO ROLE ICEBERG_LAB_RL;
GRANT ALL ON SCHEMA ICEBERG_LAB_DB.RAW TO ROLE ICEBERG_LAB_RL;
GRANT ALL ON SCHEMA ICEBERG_LAB_DB.TRANSFORM TO ROLE ICEBERG_LAB_RL;
GRANT ALL ON SCHEMA ICEBERG_LAB_DB.GOVERNANCE TO ROLE ICEBERG_LAB_RL;

-- 분석가 역할에 기본 읽기 권한 위임
GRANT USAGE ON DATABASE ICEBERG_LAB_DB TO ROLE ICEBERG_ANALYST_RL;
GRANT USAGE ON SCHEMA ICEBERG_LAB_DB.RAW TO ROLE ICEBERG_ANALYST_RL;
GRANT USAGE ON SCHEMA ICEBERG_LAB_DB.TRANSFORM TO ROLE ICEBERG_ANALYST_RL;
GRANT USAGE ON SCHEMA ICEBERG_LAB_DB.GOVERNANCE TO ROLE ICEBERG_ANALYST_RL;

-- ----------------------------------------------------------------------------
-- [5. 실습용 내부 스테이지 및 파일 포맷 생성]
-- ----------------------------------------------------------------------------
USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA RAW;

-- 실습 데이터 적재용 내부 스테이지 (Snowflake 관리형 암호화)
CREATE OR REPLACE STAGE STG_ICEBERG_DATA
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Iceberg 테이블 적재용 원천 파일 임시 저장 스테이지';

-- CSV 및 JSON 파일 포맷 생성
CREATE OR REPLACE FILE FORMAT FF_CSV_HEADER
    TYPE = 'CSV'
    PARSE_HEADER = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('NULL', 'null', '')
    COMMENT = '헤더 포함 CSV 파일 포맷';

CREATE OR REPLACE FILE FORMAT FF_JSON_STANDARD
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE
    COMMENT = '배열 언래핑 JSON 파일 포맷';

-- ----------------------------------------------------------------------------
-- [6. 환경 설정 검증]
-- ----------------------------------------------------------------------------
SELECT 
    CURRENT_ROLE() AS CURRENT_ROLE,
    CURRENT_WAREHOUSE() AS CURRENT_WAREHOUSE,
    CURRENT_DATABASE() AS CURRENT_DATABASE,
    CURRENT_SCHEMA() AS CURRENT_SCHEMA;

SHOW STAGES IN SCHEMA ICEBERG_LAB_DB.RAW;
SHOW FILE FORMATS IN SCHEMA ICEBERG_LAB_DB.RAW;
