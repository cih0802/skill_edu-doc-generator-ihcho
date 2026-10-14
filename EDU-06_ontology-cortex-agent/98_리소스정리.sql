/*
title: 온톨로지 실습 리소스 완전 정리
step: 98
type: sql
summary: 실습 중 생성된 모든 객체(Cortex Search 서비스, 테이블, 뷰, 프로시저, DB, WH, ROLE)를 객체 대장과 1:1 대조하여 안전하고 멱등하게 완전 정리
requires: [08_온톨로지_그라운딩_CortexAgent_구현.sql, 90_아키텍처_심화_및_벤치마크_분석.md]
next: [99_generate_index.py]
*/

-- ============================================================================
-- [0.0] 관리자 역할 전환 및 컨텍스트 정리
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================================
-- [PART A] 지속 과금 및 스키마 레벨 종속 서비스 정리 (Cortex Search)
-- 상위 데이터베이스가 이미 DROP된 경우 IF EXISTS만으로는 'Database does not exist' 오류가
-- 발생하므로, 프로시저 블록으로 DB 존재 여부를 사전 확인 후 안전하게 삭제합니다.
-- ============================================================================

EXECUTE IMMEDIATE $$
BEGIN
    LET db_cnt INT := (SELECT COUNT(*) FROM SNOWFLAKE.INFORMATION_SCHEMA.DATABASES WHERE DATABASE_NAME = 'EDU06_IHCHO_ONTOLOGY_DB');
    IF (db_cnt > 0) THEN
        DROP CORTEX SEARCH SERVICE IF EXISTS EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE;
        DROP DATABASE IF EXISTS EDU06_IHCHO_ONTOLOGY_DB;
    END IF;
END;
$$;

-- ============================================================================
-- [PART B] 계정 레벨 컴퓨트 및 보안 객체 정리
-- ============================================================================

DROP WAREHOUSE IF EXISTS EDU06_IHCHO_ONTOLOGY_WH;
DROP ROLE IF EXISTS EDU06_IHCHO_ONTOLOGY_ROLE;

-- ============================================================================
-- [PART D] 잔여 객체 0건 검증 (사전 스냅샷 대조)
-- ============================================================================

SHOW DATABASES LIKE 'EDU06_IHCHO_%';
SHOW WAREHOUSES LIKE 'EDU06_IHCHO_%';
SHOW ROLES LIKE 'EDU06_IHCHO_%';

-- 검증 기대 결과: 위 3개 SHOW 질의 모두 0 rows 반환되어야 함.
