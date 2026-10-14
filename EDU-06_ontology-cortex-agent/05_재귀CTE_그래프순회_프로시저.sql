/*
title: Recursive CTE 기반 그래프 순회 프로시저 구현
step: 05
type: sql
summary: 계층 하향(자손) 및 상향(조상) 경로를 탐색하고 사이클을 방지하는 Recursive CTE 기반 저장 프로시저(SP_GET_ANCESTORS, SP_EXPAND_COHORT) 구현
requires: [04_비즈니스_실측데이터_적재.sql]
next: [06_Flattened_GraphRAG_프로파일_생성.sql]
*/

-- 세션 컨텍스트 확인
USE ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
USE WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH;
USE DATABASE EDU06_IHCHO_ONTOLOGY_DB;
USE SCHEMA PUBLIC;

-- ============================================================================
-- [1.0] Recursive CTE를 통한 하향 계층 전개 (Descendants Traversal) 원리
-- 'epithelial cell' (CL:0000066)의 모든 하위 자손 세포 및 경로 탐색
-- 사이클 방지: NOT e.SRC_NODE_ID = ANY(p.PATH)
-- ============================================================================

WITH RECURSIVE DESCENDANT_PATHS AS (
    -- Anchor: 시작 노드로 들어오는 직접 자식 (subClassOf 관계에서 SRC가 자식, DST가 부모)
    SELECT 
        e.DST_NODE_ID AS ROOT_ID,
        e.SRC_NODE_ID AS CURRENT_NODE_ID,
        ARRAY_CONSTRUCT(e.DST_NODE_ID, e.SRC_NODE_ID) AS PATH,
        1 AS DEPTH
    FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e
    WHERE e.DST_NODE_ID = 'CL:0000066'
      AND e.EDGE_TYPE = 'subClassOf'
    
    UNION ALL
    
    -- Recursive: 자식의 자식 노드로 1 hop씩 하향 확장
    SELECT 
        p.ROOT_ID,
        e.SRC_NODE_ID AS CURRENT_NODE_ID,
        ARRAY_CAT(p.PATH, ARRAY_CONSTRUCT(e.SRC_NODE_ID)) AS PATH,
        p.DEPTH + 1 AS DEPTH
    FROM DESCENDANT_PATHS p
    JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e
      ON p.CURRENT_NODE_ID = e.DST_NODE_ID
    WHERE e.EDGE_TYPE = 'subClassOf'
      AND NOT ARRAY_CONTAINS(e.SRC_NODE_ID::VARIANT, p.PATH) -- 사이클 방지
)
SELECT 
    p.ROOT_ID,
    n_root.NAME AS ROOT_NAME,
    p.CURRENT_NODE_ID AS DESCENDANT_ID,
    n_desc.NAME AS DESCENDANT_NAME,
    p.DEPTH,
    p.PATH
FROM DESCENDANT_PATHS p
JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n_root ON p.ROOT_ID = n_root.NODE_ID
JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n_desc ON p.CURRENT_NODE_ID = n_desc.NODE_ID
ORDER BY p.DEPTH, DESCENDANT_NAME;

-- ============================================================================
-- [2.0] Stored Procedure: 특정 개념의 모든 상위 조상 노드 탐색 (SP_GET_ANCESTORS)
-- 입력: 개념 명칭 (예: 'keratinocyte')
-- 출력: 상위 조상 노드 목록 및 탐색 깊이 테이블
-- ============================================================================

CREATE OR REPLACE PROCEDURE EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SP_GET_ANCESTORS(P_CONCEPT_NAME VARCHAR)
RETURNS TABLE (
    CONCEPT_NAME VARCHAR,
    ANCESTOR_ID VARCHAR,
    ANCESTOR_NAME VARCHAR,
    DEPTH INT,
    PATH ARRAY
)
LANGUAGE SQL
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (
        WITH RECURSIVE ANCESTOR_PATHS AS (
            -- Anchor: 대상 개념 노드에서 출발하는 직접 부모 (DST_NODE_ID)
            SELECT 
                n.NAME AS ROOT_NAME,
                e.SRC_NODE_ID AS START_ID,
                e.DST_NODE_ID AS ANCESTOR_ID,
                ARRAY_CONSTRUCT(e.SRC_NODE_ID, e.DST_NODE_ID) AS PATH,
                1 AS DEPTH
            FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n
            JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e ON n.NODE_ID = e.SRC_NODE_ID
            WHERE LOWER(n.NAME) = LOWER(:P_CONCEPT_NAME)
              AND e.EDGE_TYPE = 'subClassOf'
            
            UNION ALL
            
            -- Recursive: 부모의 부모 노드로 상향 탐색
            SELECT 
                p.ROOT_NAME,
                p.START_ID,
                e.DST_NODE_ID AS ANCESTOR_ID,
                ARRAY_CAT(p.PATH, ARRAY_CONSTRUCT(e.DST_NODE_ID)) AS PATH,
                p.DEPTH + 1 AS DEPTH
            FROM ANCESTOR_PATHS p
            JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e ON p.ANCESTOR_ID = e.SRC_NODE_ID
            WHERE e.EDGE_TYPE = 'subClassOf'
              AND NOT ARRAY_CONTAINS(e.DST_NODE_ID::VARIANT, p.PATH)
        )
        SELECT 
            p.ROOT_NAME AS CONCEPT_NAME,
            p.ANCESTOR_ID,
            n.NAME AS ANCESTOR_NAME,
            p.DEPTH,
            p.PATH
        FROM ANCESTOR_PATHS p
        JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n ON p.ANCESTOR_ID = n.NODE_ID
        ORDER BY p.DEPTH
    );
    RETURN TABLE(res);
END;
$$;

-- 프로시저 실행 검증: 'keratinocyte'의 조상 계통 확인
CALL EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SP_GET_ANCESTORS('keratinocyte');

-- ============================================================================
-- [3.0] Stored Procedure: 상위 세포 개념에 매핑된 조직 및 약물 코호트 확장 (SP_EXPAND_COHORT)
-- 입력: 상위 세포 개념 (예: 'squamous epithelial cell')
-- 출력: 해당 계통에 속하는 조직들과 각 조직별 평균 약물 반응 생존율
-- ============================================================================

CREATE OR REPLACE PROCEDURE EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SP_EXPAND_COHORT(P_ROOT_CONCEPT VARCHAR)
RETURNS TABLE (
    ROOT_CONCEPT VARCHAR,
    MATCHED_TISSUE VARCHAR,
    DRUG_NAME VARCHAR,
    TARGET_PATHWAY VARCHAR,
    AVG_VIABILITY FLOAT
)
LANGUAGE SQL
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (
        WITH RECURSIVE DESCENDANTS AS (
            SELECT 
                n.NODE_ID,
                n.NAME
            FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n
            WHERE LOWER(n.NAME) = LOWER(:P_ROOT_CONCEPT)
            
            UNION ALL
            
            SELECT 
                e.SRC_NODE_ID AS NODE_ID,
                n_child.NAME
            FROM DESCENDANTS d
            JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e ON d.NODE_ID = e.DST_NODE_ID
            JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n_child ON e.SRC_NODE_ID = n_child.NODE_ID
            WHERE e.EDGE_TYPE = 'subClassOf'
        ),
        RELATED_TISSUES AS (
            -- 해당 계통 노드들 및 직간접 위치하는 조직(TISSUE) 매핑
            SELECT DISTINCT 
                n_tissue.NAME AS TISSUE_NAME
            FROM DESCENDANTS d
            JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE e ON d.NODE_ID = e.SRC_NODE_ID
            JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE n_tissue ON e.DST_NODE_ID = n_tissue.NODE_ID
            WHERE e.EDGE_TYPE = 'locatedIn'
              AND n_tissue.NODE_TYPE = 'TISSUE'
        )
        SELECT 
            :P_ROOT_CONCEPT AS ROOT_CONCEPT,
            rt.TISSUE_NAME AS MATCHED_TISSUE,
            sv.DRUG_NAME,
            sv.TARGET_PATHWAY,
            ROUND(AVG(sv.VIABILITY_SCORE), 3) AS AVG_VIABILITY
        FROM RELATED_TISSUES rt
        JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY sv
          ON LOWER(rt.TISSUE_NAME) = LOWER(sv.PRIMARY_TISSUE)
        GROUP BY rt.TISSUE_NAME, sv.DRUG_NAME, sv.TARGET_PATHWAY
        ORDER BY MATCHED_TISSUE, AVG_VIABILITY
    );
    RETURN TABLE(res);
END;
$$;

-- 프로시저 실행 검증: 'squamous epithelial cell' 코호트 전개 결과 확인
CALL EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SP_EXPAND_COHORT('squamous epithelial cell');
