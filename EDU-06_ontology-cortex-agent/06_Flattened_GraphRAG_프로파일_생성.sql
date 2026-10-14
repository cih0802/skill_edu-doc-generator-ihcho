/*
title: Flattened GraphRAG 비정형 프로파일 테이블 생성
step: 06
type: sql
summary: 런타임 지식 그래프 순회 부하를 제거하기 위해 온톨로지 계층 및 하위 속성을 단일 비정형 문서 프로파일로 사전 롤업(Rollup)하는 테이블 구축
requires: [05_재귀CTE_그래프순회_프로시저.sql]
next: [07_CortexSearch_온톨로지_인덱싱.sql]
*/

-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ KG_FLATTENED_PROFILES CTAS (14행), squamous epithelial cell 롤업 조직 4개 — 실제 실행
--   💡 ALL_DESCENDANTS 는 PATH 가드 대신 DEPTH < 10 으로 재귀를 끊습니다. 순환이 있어도 종료되지만
--      순환 구간이 반복 집계될 수 있으므로, 실제 온톨로지에서는 05_ [4.0] 방식의 PATH 가드를 권장합니다

-- 세션 컨텍스트 확인
USE ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
USE WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH;
USE DATABASE EDU06_IHCHO_ONTOLOGY_DB;
USE SCHEMA PUBLIC;

-- ============================================================================
-- [1.0] 전처리 파이프라인: 계층 롤업 및 단일 프로파일 문서 합성 원리
-- 각 온톨로지 개념에 대해 다음 요소를 사전 결합합니다:
-- 1. 공식 명칭(Formal Name), 정의(Definition), 도메인 유의어(Synonyms)
-- 2. 직계 부모/자식(1st order) 및 조부모/손자(2nd order)
-- 3. 모든 하위 자손 계통에서 롤업 집계된 도메인 카테고리(매핑 조직 목록 등)
-- ============================================================================

CREATE OR REPLACE TABLE EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_FLATTENED_PROFILES AS
WITH RECURSIVE ALL_DESCENDANTS AS (
    -- Anchor: 모든 노드 자기 자신
    SELECT 
        NODE_ID AS ROOT_NODE_ID,
        NODE_ID AS DESCENDANT_NODE_ID,
        0 AS DEPTH
    FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE
    
    UNION ALL
    
    -- Recursive: 자손 방향 확장 (최대 10레벨)
    SELECT 
        d.ROOT_NODE_ID,
        e.SRC_NODE_ID AS DESCENDANT_NODE_ID,
        d.DEPTH + 1 AS DEPTH
    FROM ALL_DESCENDANTS d
    JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e ON d.DESCENDANT_NODE_ID = e.DST_NODE_ID
    WHERE e.EDGE_TYPE = 'subClassOf'
      AND d.DEPTH < 10
),
ROLLUP_TISSUES AS (
    -- 각 루트 노드의 모든 자손 노드들이 연결된 조직 목록 집계
    SELECT 
        d.ROOT_NODE_ID,
        ARRAY_AGG(DISTINCT n_tissue.NAME) WITHIN GROUP (ORDER BY n_tissue.NAME) AS AGGREGATED_TISSUES
    FROM ALL_DESCENDANTS d
    JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e ON d.DESCENDANT_NODE_ID = e.SRC_NODE_ID
    JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n_tissue ON e.DST_NODE_ID = n_tissue.NODE_ID
    WHERE e.EDGE_TYPE = 'locatedIn'
      AND n_tissue.NODE_TYPE = 'TISSUE'
    GROUP BY d.ROOT_NODE_ID
),
PARENTS_AND_CHILDREN AS (
    -- 직계 부모 및 자식 노드 명칭 집계
    SELECT 
        n.NODE_ID,
        ARRAY_AGG(DISTINCT CASE WHEN e_par.EDGE_TYPE = 'subClassOf' THEN n_par.NAME END) AS PARENT_NAMES,
        ARRAY_AGG(DISTINCT CASE WHEN e_chi.EDGE_TYPE = 'subClassOf' THEN n_chi.NAME END) AS CHILD_NAMES
    FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n
    LEFT JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e_par ON n.NODE_ID = e_par.SRC_NODE_ID
    LEFT JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n_par ON e_par.DST_NODE_ID = n_par.NODE_ID
    LEFT JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e_chi ON n.NODE_ID = e_chi.DST_NODE_ID
    LEFT JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n_chi ON e_chi.SRC_NODE_ID = n_chi.NODE_ID
    GROUP BY n.NODE_ID
)
SELECT 
    n.NODE_ID,
    n.NAME AS CONCEPT_NAME,
    n.NODE_TYPE,
    ARRAY_TO_STRING(n.SYNONYMS, ', ') AS SYNONYMS_STR,
    COALESCE(n.PROPERTIES:definition::STRING, 'No definition provided') AS DEFINITION,
    ARRAY_TO_STRING(pc.PARENT_NAMES, ', ') AS PARENTS_STR,
    ARRAY_TO_STRING(pc.CHILD_NAMES, ', ') AS CHILDREN_STR,
    ARRAY_TO_STRING(rt.AGGREGATED_TISSUES, ', ') AS AGGREGATED_TISSUES_STR,
    
    -- Cortex Search 인덱싱을 위한 풍부한 컨텍스트 문서 본문 합성
    CONCAT(
        'Concept: ', n.NAME, ' (', n.NODE_ID, ')\n',
        'Type: ', n.NODE_TYPE, '\n',
        'Definition: ', COALESCE(n.PROPERTIES:definition::STRING, 'N/A'), '\n',
        'Synonyms: ', COALESCE(ARRAY_TO_STRING(n.SYNONYMS, ', '), 'None'), '\n',
        'Parents: ', COALESCE(ARRAY_TO_STRING(pc.PARENT_NAMES, ', '), 'None'), '\n',
        'Children: ', COALESCE(ARRAY_TO_STRING(pc.CHILD_NAMES, ', '), 'None'), '\n',
        'Aggregated Relevant Tissues / Organs: ', COALESCE(ARRAY_TO_STRING(rt.AGGREGATED_TISSUES, ', '), 'None')
    ) AS PROFILE_DOCUMENT,
    
    CURRENT_TIMESTAMP() AS LAST_INDEXED_AT
FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n
LEFT JOIN PARENTS_AND_CHILDREN pc ON n.NODE_ID = pc.NODE_ID
LEFT JOIN ROLLUP_TISSUES rt ON n.NODE_ID = rt.ROOT_NODE_ID;

-- ============================================================================
-- [2.0] 생성된 비정형 프로파일 데이터 검증
-- ============================================================================

SELECT 
    CONCEPT_NAME, 
    SYNONYMS_STR, 
    AGGREGATED_TISSUES_STR, 
    SUBSTRING(PROFILE_DOCUMENT, 1, 150) AS DOC_PREVIEW
FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_FLATTENED_PROFILES
WHERE NODE_TYPE = 'CELL_TYPE'
ORDER BY CONCEPT_NAME;

-- 판정: squamous epithelial cell 은 자손(keratinocyte)의 skin 까지 롤업되어야 합니다
-- 기대: bladder, esophagus, lung, skin
SELECT AGGREGATED_TISSUES_STR FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_FLATTENED_PROFILES
WHERE CONCEPT_NAME = 'squamous epithelial cell';

-- ============================================================================
-- 🧹 이 단계까지의 정리: 98_ PART A(DB 삭제)로 함께 삭제됩니다
-- ============================================================================
