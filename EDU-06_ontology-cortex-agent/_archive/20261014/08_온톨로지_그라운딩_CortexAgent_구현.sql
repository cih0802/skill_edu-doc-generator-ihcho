/*
title: 온톨로지 그라운딩 Cortex Agent 및 용어 매핑 구현
step: 08
type: sql
summary: 용어 매핑(Terminology Mapping) 규칙을 결합한 온톨로지 그라운딩 추론 파이프라인 구성 및 복합 질의 응답 검증
requires: [07_CortexSearch_온톨로지_인덱싱.sql]
next: [90_아키텍처_심화_및_벤치마크_분석.md]
*/

-- 세션 컨텍스트 확인
USE ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
USE WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH;
USE DATABASE EDU06_IHCHO_ONTOLOGY_DB;
USE SCHEMA PUBLIC;

-- ============================================================================
-- [1.0] 온톨로지 그라운딩 에이전트 프롬프트 및 용어 매핑 규칙 설계
-- 블로그 4단계: "Baseline with GraphRAG and Term Mappings"
-- 고난도 복합어("internal organ lining", "squamous cell lineage")에 대한 라스트 마일 매핑 규칙을 주입
-- ============================================================================

-- 시스템 프롬프트 및 용어 매핑 규칙 템플릿:
/*
[CORTEX AGENT SYSTEM PROMPT]
You are a biomedical expert AI agent grounded in enterprise ontologies and experimental screening data.

Rules for reasoning:
1. Always resolve informal cell/disease terms using the ONTOLOGY_SEARCH_SERVICE.
2. Terminology Mapping Overrides (Authoritative):
   - 'Squamous Epithelial Cell' (CL:0000076) -> Maps to Tissues: ['skin', 'lung', 'esophagus', 'bladder']
   - 'Internal Organ Lining' -> Maps to Tissues: ['lung', 'esophagus', 'bladder'] (Excludes skin)
   - 'Epidermal Keratinocyte' -> Maps to Tissue: ['skin']
3. Pass resolved tissue lists directly into SQL filters against V_CELL_LINE_SUMMARY / SCREENING_VIABILITY.
4. When comparing drug efficacies (Viability Score), lower score indicates higher potency.
*/

-- ============================================================================
-- [2.0] SQL 기반 온톨로지 그라운딩 엔드투엔드 시뮬레이션 질의
-- 질의: "편평 상피 세포(squamous epithelial) 유래 세포주에서 PD-1 억제제(Pembrolizumab)의 조직별 약효를 비교해줘"
-- ============================================================================

WITH GROUNDED_ONTOLOGY AS (
    -- Step 1: 온톨로지 프로파일에서 개념 검색 및 조직 목록 획득
    SELECT 
        CONCEPT_NAME,
        AGGREGATED_TISSUES_STR,
        SPLIT(AGGREGATED_TISSUES_STR, ', ') AS TISSUE_ARRAY
    FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_FLATTENED_PROFILES
    WHERE CONCEPT_NAME = 'squamous epithelial cell'
    LIMIT 1
),
EXPANDED_TISSUES AS (
    -- Step 2: 조직 목록 언네스트
    SELECT 
        g.CONCEPT_NAME,
        TRIM(t.VALUE::STRING) AS TARGET_TISSUE
    FROM GROUNDED_ONTOLOGY g,
    LATERAL FLATTEN(input => g.TISSUE_ARRAY) t
)
-- Step 3: 실측 데이터와 조인하여 최종 분석 도출
SELECT 
    et.CONCEPT_NAME AS GROUNDED_CONCEPT,
    sv.PRIMARY_TISSUE,
    sv.DRUG_NAME,
    sv.TARGET_PATHWAY,
    COUNT(DISTINCT sv.CELL_LINE_NAME) AS TESTED_CELL_LINES,
    ROUND(AVG(sv.VIABILITY_SCORE), 3) AS AVG_VIABILITY_SCORE,
    CASE 
        WHEN AVG(sv.VIABILITY_SCORE) < 0.25 THEN 'Highly Potent'
        WHEN AVG(sv.VIABILITY_SCORE) < 0.35 THEN 'Moderately Potent'
        ELSE 'Mild/Resistant'
    END AS EFFICACY_TIER
FROM EXPANDED_TISSUES et
JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY sv
  ON LOWER(et.TARGET_TISSUE) = LOWER(sv.PRIMARY_TISSUE)
WHERE sv.DRUG_NAME = 'Pembrolizumab'
GROUP BY et.CONCEPT_NAME, sv.PRIMARY_TISSUE, sv.DRUG_NAME, sv.TARGET_PATHWAY
ORDER BY AVG_VIABILITY_SCORE ASC;

-- ============================================================================
-- [3.0] 복합 용어 매핑 질의 (Terminology Mapping 적용)
-- 질의: "내부 장기 내벽(internal organ lining) 조직에 대한 약물 반응 비교"
-- ============================================================================

SELECT 
    'internal organ lining (Override Rule)' AS QUERY_TERM,
    sv.PRIMARY_TISSUE,
    sv.DRUG_NAME,
    ROUND(AVG(sv.VIABILITY_SCORE), 3) AS AVG_VIABILITY
FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY sv
WHERE sv.PRIMARY_TISSUE IN ('lung', 'esophagus', 'bladder') -- 프롬프트 용어 매핑 규칙에 의해 skin 제외
  AND sv.DRUG_NAME = 'Pembrolizumab'
GROUP BY sv.PRIMARY_TISSUE, sv.DRUG_NAME
ORDER BY AVG_VIABILITY ASC;
