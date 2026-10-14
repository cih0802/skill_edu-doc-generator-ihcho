/*
title: 데이터 거버넌스 및 보안 정책
step: 08
type: sql
summary: Snowflake Horizon 거버넌스 기능을 Iceberg 테이블에 직접 적용하여 차대번호(VIN) 동적 데이터 마스킹(CLS) 및 지역별 행 접근 제어(RLS)를 구성하고 역할별 접근 결과를 검증합니다.
requires: 07_스노우파크_및_고급변환.sql
next: 09_데이터공유_및_협업.sql
*/

-- ----------------------------------------------------------------------------
-- [0. Iceberg 테이블 거버넌스 원리]
--
-- Snowflake Horizon Catalog는 Iceberg 테이블에 대해서도 일반 테이블과 완전히 동일한
-- 세밀한 접근 제어(Fine-Grained Access Control) 보안 정책을 지원합니다:
--
-- 1. Masking Policy (열 레벨 보안, CLS)
--    - 민감 정보인 차대번호(VIN)를 비인가 사용자에게 일부 마스킹 처리하여 노출
--
-- 2. Row Access Policy (행 레벨 보안, RLS)
--    - 분석가 역할(ICEBERG_ANALYST_RL)은 허가된 지역(KR-SEOUL) 데이터만 조회 가능
-- ----------------------------------------------------------------------------

USE ROLE ICEBERG_LAB_RL;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA GOVERNANCE;

-- ----------------------------------------------------------------------------
-- [1. 마스킹 정책(Masking Policy) 생성]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE MASKING POLICY MP_VIN_MASK AS (val VARCHAR) RETURNS VARCHAR ->
    CASE 
        WHEN CURRENT_ROLE() IN ('ICEBERG_LAB_RL', 'ACCOUNTADMIN') THEN val
        ELSE CONCAT(LEFT(val, 3), '***MASKED***', RIGHT(val, 3))
    END;

-- ----------------------------------------------------------------------------
-- [2. 행 접근 제어 정책(Row Access Policy) 생성]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE ROW ACCESS POLICY RAP_REGION_FILTER AS (region_val VARCHAR) RETURNS BOOLEAN ->
    CASE 
        WHEN CURRENT_ROLE() IN ('ICEBERG_LAB_RL', 'ACCOUNTADMIN') THEN TRUE
        WHEN CURRENT_ROLE() = 'ICEBERG_ANALYST_RL' AND region_val = 'KR-SEOUL' THEN TRUE
        ELSE FALSE
    END;

-- ----------------------------------------------------------------------------
-- [3. Iceberg 테이블에 정책 적용 (Policy Binding)]
-- ----------------------------------------------------------------------------

-- 3-1. VIN 컬럼에 마스킹 정책 바인딩
ALTER ICEBERG TABLE ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY
    MODIFY COLUMN VIN SET MASKING POLICY ICEBERG_LAB_DB.GOVERNANCE.MP_VIN_MASK;

-- 3-2. REGION_CODE 컬럼에 행 접근 제어 정책 바인딩
ALTER ICEBERG TABLE ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY
    ADD ROW ACCESS POLICY ICEBERG_LAB_DB.GOVERNANCE.RAP_REGION_FILTER ON (REGION_CODE);

-- 분석가 역할에 대상 테이블 SELECT 권한 위임
GRANT SELECT ON TABLE ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY TO ROLE ICEBERG_ANALYST_RL;

-- ----------------------------------------------------------------------------
-- [4. 관리자 역할(ICEBERG_LAB_RL) 조회 검증]
-- 관리자는 모든 행(5건)과 원본 VIN 값을 그대로 조회할 수 있어야 합니다.
-- ----------------------------------------------------------------------------
USE ROLE ICEBERG_LAB_RL;
SELECT VEHICLE_ID, MODEL_NAME, VIN, REGION_CODE 
FROM ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY 
ORDER BY VEHICLE_ID;

-- ----------------------------------------------------------------------------
-- [5. 분석가 역할(ICEBERG_ANALYST_RL) 조회 검증]
-- ⚠️ 주의: 권한 검증 시 보조 역할(Secondary Role) 간섭을 방지하기 위해
-- 반드시 USE SECONDARY ROLES NONE 을 선언합니다.
-- ----------------------------------------------------------------------------
USE ROLE ICEBERG_ANALYST_RL;
USE SECONDARY ROLES NONE;
USE WAREHOUSE ICEBERG_LAB_WH;
USE DATABASE ICEBERG_LAB_DB;
USE SCHEMA RAW;

-- 검증 기대 결과:
-- 1. 행 필터: 'KR-SEOUL' 지역 차량 2건만 노출 (KR-BUSAN, KR-INCHEON 은 숨김)
-- 2. 열 마스킹: VIN 컬럼이 '1HG***MASKED***001' 형태로 마스킹 처리됨
SELECT VEHICLE_ID, MODEL_NAME, VIN, REGION_CODE 
FROM ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY 
ORDER BY VEHICLE_ID;

-- 실습 관리자 역할로 복귀
USE ROLE ICEBERG_LAB_RL;
USE SECONDARY ROLES ALL;
