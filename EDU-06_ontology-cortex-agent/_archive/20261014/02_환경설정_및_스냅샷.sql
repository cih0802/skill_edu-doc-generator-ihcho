/*
title: 온톨로지 실습 환경설정 및 사전 스냅샷
step: 02
type: sql
summary: 실습 전 환경 상태 스냅샷 서식 확인, 전용 역할/웨어하우스/데이터베이스 생성 및 Cortex 가용 모델 사전 점검
requires: [01_교육자료_정리본.md]
next: [03_온톨로지_데이터모델_구축.sql]
*/

-- ============================================================================
-- [0.0] 실습 환경 사전 스냅샷 (Pre-Lab Snapshot)
-- 실습 시작 전 계정 내 충돌 가능 객체 상태를 기록합니다. (실측값은 빈 서식에 기록)
-- ============================================================================

-- 기록 서식:
-- 1. 기존 DB 확인: SHOW DATABASES LIKE 'EDU06_IHCHO_%'; -> 결과: [         ]
-- 2. 기존 WH 확인: SHOW WAREHOUSES LIKE 'EDU06_IHCHO_%'; -> 결과: [         ]
-- 3. 기존 ROLE 확인: SHOW ROLES LIKE 'EDU06_IHCHO_%';    -> 결과: [         ]

SHOW DATABASES LIKE 'EDU06_IHCHO_%';
SHOW WAREHOUSES LIKE 'EDU06_IHCHO_%';
SHOW ROLES LIKE 'EDU06_IHCHO_%';

-- ============================================================================
-- [1.0] 계정 적합성 및 Cortex 가용 모델 점검
-- AI 모델의 수명(GA/LEGACY/EOL) 및 임베딩 모델 가용성을 확인합니다.
-- ============================================================================

SHOW CORTEX BASE MODELS;

SELECT CURRENT_ACCOUNT(), CURRENT_REGION(), CURRENT_ROLE(), CURRENT_USER();

-- ============================================================================
-- [2.0] 실습 전용 역할 (ROLE) 생성 및 권한 설정
-- ============================================================================

USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS EDU06_IHCHO_ONTOLOGY_ROLE
    COMMENT = 'EDU-06 온톨로지 실습 전용 역할';

GRANT ROLE EDU06_IHCHO_ONTOLOGY_ROLE TO ROLE ACCOUNTADMIN;
GRANT ROLE EDU06_IHCHO_ONTOLOGY_ROLE TO USER TRIALADMIN;

-- ============================================================================
-- [3.0] 실습 전용 웨어하우스 (WAREHOUSE) 생성
-- ============================================================================

CREATE WAREHOUSE IF NOT EXISTS EDU06_IHCHO_ONTOLOGY_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'EDU-06 온톨로지 실습 가상 웨어하우스';

GRANT USAGE, OPERATE ON WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH TO ROLE EDU06_IHCHO_ONTOLOGY_ROLE;

-- ============================================================================
-- [4.0] 실습 전용 데이터베이스 (DATABASE) 및 스키마 생성
-- ============================================================================

CREATE DATABASE IF NOT EXISTS EDU06_IHCHO_ONTOLOGY_DB
    COMMENT = 'EDU-06 온톨로지 및 Cortex Agent 실습 데이터베이스';

GRANT OWNERSHIP ON DATABASE EDU06_IHCHO_ONTOLOGY_DB TO ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
GRANT ALL ON SCHEMA EDU06_IHCHO_ONTOLOGY_DB.PUBLIC TO ROLE EDU06_IHCHO_ONTOLOGY_ROLE;

-- 세션 컨텍스트 전환
USE ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
USE WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH;
USE DATABASE EDU06_IHCHO_ONTOLOGY_DB;
USE SCHEMA PUBLIC;

SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();
