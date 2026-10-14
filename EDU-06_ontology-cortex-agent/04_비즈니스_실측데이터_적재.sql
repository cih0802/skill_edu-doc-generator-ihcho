/*
title: 비즈니스 실측 데이터 적재 및 기본 분석 뷰 구축
step: 04
type: sql
summary: PRISM 약물 스크리닝 반응도 실측 데이터(SCREENING_VIABILITY) 적재 및 도메인 분석 뷰 생성
requires: [03_온톨로지_데이터모델_구축.sql]
next: [05_재귀CTE_그래프순회_프로시저.sql]
*/

-- 세션 컨텍스트 확인
USE ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
USE WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH;
USE DATABASE EDU06_IHCHO_ONTOLOGY_DB;
USE SCHEMA PUBLIC;

-- ============================================================================
-- [1.0] 약물 스크리닝 생존율 실측 테이블 (SCREENING_VIABILITY) 생성
-- PRISM 데이터셋 구조: 세포주, 조직 계통, 약물명, 약물 타겟, 생존율(Viability)
-- ============================================================================

CREATE OR REPLACE TABLE EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY (
    EXPERIMENT_ID   VARCHAR(100) PRIMARY KEY,
    CELL_LINE_NAME  VARCHAR(100) NOT NULL,
    PRIMARY_TISSUE  VARCHAR(100) NOT NULL, -- 'lung', 'skin', 'esophagus', 'bladder'
    DRUG_NAME       VARCHAR(100) NOT NULL,
    TARGET_PATHWAY  VARCHAR(100),          -- 'PD-1', 'EGFR', 'MAPK', 'VEGF'
    VIABILITY_SCORE FLOAT        NOT NULL, -- 세포 생존율 (0.0 ~ 1.0, 낮을수록 약효 우수)
    MEASURED_AT     DATE DEFAULT CURRENT_DATE()
);

-- ============================================================================
-- [2.0] 실측 데이터 샘플 적재
-- ============================================================================

INSERT INTO EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY 
    (EXPERIMENT_ID, CELL_LINE_NAME, PRIMARY_TISSUE, DRUG_NAME, TARGET_PATHWAY, VIABILITY_SCORE)
VALUES
    ('EXP-001', 'A549', 'lung', 'Pembrolizumab', 'PD-1', 0.28),
    ('EXP-002', 'A549', 'lung', 'Gefitinib', 'EGFR', 0.45),
    ('EXP-003', 'H460', 'lung', 'Pembrolizumab', 'PD-1', 0.32),
    ('EXP-004', 'A375', 'skin', 'Pembrolizumab', 'PD-1', 0.19),
    ('EXP-005', 'A375', 'skin', 'Dabrafenib', 'MAPK', 0.15),
    ('EXP-006', 'SK-MEL-28', 'skin', 'Pembrolizumab', 'PD-1', 0.24),
    ('EXP-007', 'KYSE-30', 'esophagus', 'Pembrolizumab', 'PD-1', 0.38),
    ('EXP-008', 'TE-1', 'esophagus', 'Gefitinib', 'EGFR', 0.52),
    ('EXP-009', 'T24', 'bladder', 'Pembrolizumab', 'PD-1', 0.35),
    ('EXP-010', 'T24', 'bladder', 'Cisplatin', 'DNA-crosslink', 0.22),
    ('EXP-011', 'MCF-7', 'breast', 'Tamoxifen', 'Estrogen-Receptor', 0.18),
    ('EXP-012', 'HepG2', 'liver', 'Sorafenib', 'VEGF', 0.41);

-- ============================================================================
-- [3.0] 조직 및 약물별 요약 분석 뷰 (V_CELL_LINE_SUMMARY) 생성
-- ============================================================================

CREATE OR REPLACE VIEW EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.V_CELL_LINE_SUMMARY AS
SELECT 
    PRIMARY_TISSUE,
    DRUG_NAME,
    TARGET_PATHWAY,
    COUNT(DISTINCT CELL_LINE_NAME) AS CELL_LINE_COUNT,
    ROUND(AVG(VIABILITY_SCORE), 3) AS AVG_VIABILITY_SCORE,
    ROUND(MIN(VIABILITY_SCORE), 3) AS MIN_VIABILITY_SCORE
FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY
GROUP BY PRIMARY_TISSUE, DRUG_NAME, TARGET_PATHWAY;

-- ============================================================================
-- [4.0] 데이터 검증 질의
-- ============================================================================

SELECT * FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.V_CELL_LINE_SUMMARY
ORDER BY PRIMARY_TISSUE, AVG_VIABILITY_SCORE;
