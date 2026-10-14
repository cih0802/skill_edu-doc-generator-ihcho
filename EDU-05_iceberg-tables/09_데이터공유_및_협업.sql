/*
title: 데이터 공유 및 협업
step: 09
type: sql
summary: Iceberg 테이블을 기반으로 비즈니스 로직을 보호하는 Secure View를 정의하고, Snowflake Data Sharing을 통해 외부 계정과 실시간 무복제 공유를 구성합니다.
requires: 08_데이터거버넌스_보안정책.sql
next: 10_외부엔진연동_및_의미론적계층.sql
*/

-- ----------------------------------------------------------------------------
-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ Secure View 생성·조회, Share 생성, Share 에 DB/스키마/뷰 권한 부여, DESCRIBE SHARE — 실제 실행
--   ⚠️ ALTER SHARE … ADD ACCOUNTS 및 소비자 측 조회 — 소비자 계정이 없어 미실행
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- [0. Iceberg 테이블과 Secure Data Sharing]
--
-- Snowflake Data Sharing은 데이터 복제나 스토리지 이동 없이,
-- 메타데이터 수준에서 타 계정(소비자)에게 실시간 읽기 권한을 제공합니다.
-- 1. Secure View: 내부 쿼리 최적화 엔진의 메타데이터 노출 및 뷰 정의 유출 방지
-- 2. Secure Share: 데이터베이스, 스키마, 뷰에 대한 접근 권한을 묶어 외부 계정에 전달
-- ----------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- [1. Iceberg 테이블 기반 보안 뷰(Secure View) 생성]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE SECURE VIEW ICEBERG_LAB_DB.GOVERNANCE.SV_FLEET_MONITORING_PUBLIC AS
SELECT 
    v.VEHICLE_ID,
    v.MODEL_NAME,
    v.REGION_CODE,
    s.RECORDED_AT,
    s.SPEED_KMH,
    s.BATTERY_PCT,
    s.HEALTH_STATUS
FROM ICEBERG_LAB_DB.TRANSFORM.ICB_SNOWPARK_ENRICHED s
JOIN ICEBERG_LAB_DB.RAW.ICB_VEHICLE_REGISTRY v
    ON s.VEHICLE_ID = v.VEHICLE_ID;

-- 뷰 조회 테스트
SELECT * FROM ICEBERG_LAB_DB.GOVERNANCE.SV_FLEET_MONITORING_PUBLIC;

-- ----------------------------------------------------------------------------
-- [2. 아웃바운드 데이터 공유(Outbound Data Share) 생성]
-- ----------------------------------------------------------------------------
-- 🔴 SHARE 는 계정 레벨 객체이므로 CREATE OR REPLACE 를 쓰지 않습니다
CREATE SHARE IF NOT EXISTS SHARE_ICEBERG_FLEET_DATA
    COMMENT = 'EDU-05 Iceberg 실습용 플릿 모니터링 데이터 쉐어';

-- ----------------------------------------------------------------------------
-- [3. Share에 데이터베이스, 스키마 및 뷰 권한 부여]
-- ----------------------------------------------------------------------------
GRANT USAGE ON DATABASE ICEBERG_LAB_DB TO SHARE SHARE_ICEBERG_FLEET_DATA;
GRANT USAGE ON SCHEMA ICEBERG_LAB_DB.GOVERNANCE TO SHARE SHARE_ICEBERG_FLEET_DATA;
GRANT SELECT ON VIEW ICEBERG_LAB_DB.GOVERNANCE.SV_FLEET_MONITORING_PUBLIC TO SHARE SHARE_ICEBERG_FLEET_DATA;

-- ----------------------------------------------------------------------------
-- [4. 공유 상태 확인 및 소비자 계정 추가 가이드]
-- ----------------------------------------------------------------------------
SHOW SHARES LIKE 'SHARE_ICEBERG_%';

DESCRIBE SHARE SHARE_ICEBERG_FLEET_DATA;

/*
-- [소비자 계정 연결 템플릿 (실제 타 계정이 있는 경우 실행)]
-- ALTER SHARE SHARE_ICEBERG_FLEET_DATA ADD ACCOUNTS = <CONSUMER_ACCOUNT_IDENTIFIER>;
*/

-- 실습 관리자 역할로 복귀
USE ROLE ICEBERG_LAB_RL;

-- ----------------------------------------------------------------------------
-- ⚠️ 08_ 의 행 접근 정책 때문에 소비자 계정에서는 이 뷰가 0행으로 보입니다 (08_ 말미 경고 참고)
-- 🧹 이 단계까지의 정리: 98_ C-1(DROP SHARE) — Share 는 계정 레벨이라 DB 삭제로 사라지지 않습니다
-- ----------------------------------------------------------------------------
