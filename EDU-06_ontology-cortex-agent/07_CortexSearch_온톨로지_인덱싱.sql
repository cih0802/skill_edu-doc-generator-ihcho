/*
title: Cortex Search 온톨로지 하이브리드 인덱싱
step: 07
type: sql
summary: Flattened GraphRAG 프로파일을 대상으로 키워드/벡터 하이브리드 검색을 수행하는 Cortex Search 서비스 생성 및 도메인 유의어 검색 검증
requires: [06_Flattened_GraphRAG_프로파일_생성.sql]
next: [08_온톨로지_그라운딩_CortexAgent_구현.sql]
*/

-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ CREATE CORTEX SEARCH SERVICE, SHOW/DESCRIBE, SEARCH_PREVIEW — 실제 실행
--   ✅ 유의어 질의 "flat epithelial …" 의 1순위 결과 NODE_ID 확인 — 실제 실행 (아래 [3.1])
--   ⚠️ TARGET_LAG '1 hour' 자동 재인덱싱은 시간 경과가 필요해 관찰하지 않았습니다
--   💡 임베딩 모델은 지정하지 않아 기본값을 씁니다. 실제 모델은 DESCRIBE 결과의 embedding_model 열로 확인합니다

-- 세션 컨텍스트 확인
USE ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
USE WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH;
USE DATABASE EDU06_IHCHO_ONTOLOGY_DB;
USE SCHEMA PUBLIC;

-- ============================================================================
-- [1.0] Cortex Search 서비스 생성 (ONTOLOGY_SEARCH_SERVICE)
-- ON 절: 검색 대상 텍스트 컬럼 (PROFILE_DOCUMENT)
-- ATTRIBUTES 절: 메타데이터 필터링 컬럼 (NODE_ID, NODE_TYPE, CONCEPT_NAME, AGGREGATED_TISSUES_STR)
-- ============================================================================

CREATE OR REPLACE CORTEX SEARCH SERVICE EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE
    ON PROFILE_DOCUMENT
    ATTRIBUTES NODE_ID, NODE_TYPE, CONCEPT_NAME, AGGREGATED_TISSUES_STR
    WAREHOUSE = EDU06_IHCHO_ONTOLOGY_WH
    TARGET_LAG = '1 hour'
    COMMENT = 'EDU-06 도메인 온톨로지 및 유의어 하이브리드 검색 서비스'
AS (
    SELECT 
        NODE_ID,
        NODE_TYPE,
        CONCEPT_NAME,
        AGGREGATED_TISSUES_STR,
        PROFILE_DOCUMENT
    FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_FLATTENED_PROFILES
);

-- ============================================================================
-- [2.0] Cortex Search 서비스 상태 확인
-- ============================================================================

SHOW CORTEX SEARCH SERVICES LIKE 'ONTOLOGY_SEARCH_SERVICE' IN SCHEMA EDU06_IHCHO_ONTOLOGY_DB.PUBLIC;

DESCRIBE CORTEX SEARCH SERVICE EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE;

-- ============================================================================
-- [3.0] 유의어 및 비정형 질의 검색 시험
-- 유저 질의: "flat epithelial" (자연어 유의어)
-- 기대 결과: "squamous epithelial cell" (CL:0000076) 및 연관 조직(skin, lung, esophagus, bladder) 정확 검색
-- ============================================================================

-- SQL 내에서 Cortex Search 함수 테스트
-- (참고: 애플리케이션 및 Agent는 REST API 또는 Python/Cortex Agent 도구를 통해 호출함)
SELECT 
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE',
        '{
            "query": "flat epithelial cell lining and associated tissues",
            "columns": ["NODE_ID", "CONCEPT_NAME", "AGGREGATED_TISSUES_STR", "PROFILE_DOCUMENT"],
            "limit": 3
        }'
    ) AS SEARCH_RESULTS;

-- [3.1] 판정 쿼리: 1순위 결과가 CL:0000076 (squamous epithelial cell) 인가
--       질의어에 "squamous" 가 없어도 유의어 "flat epithelial" 로 찾아야 합니다
SELECT r.value:NODE_ID::VARCHAR AS NODE_ID, r.value:CONCEPT_NAME::VARCHAR AS CONCEPT_NAME, r.index AS RANK0
FROM (SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE',
        '{"query": "flat epithelial cell lining and associated tissues", "columns": ["NODE_ID", "CONCEPT_NAME"], "limit": 3}'
     )) AS J) s,
     LATERAL FLATTEN(input => s.J:results) r
ORDER BY r.index;

-- ============================================================================
-- 🧹 이 단계까지의 정리
--   💰 Cortex Search 는 서빙 중 비용이 발생합니다. 일시 중단: ALTER CORTEX SEARCH SERVICE … SUSPEND SERVING
--   삭제: 98_ PART A
-- ============================================================================
