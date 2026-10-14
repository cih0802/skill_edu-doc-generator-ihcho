/*
title: 온톨로지 지식 그래프 데이터 모델 구축
step: 03
type: sql
summary: 온톨로지 엔티티 노드(KG_NODE) 및 관계 엣지(KG_EDGE) 테이블 생성 및 세포 계통 도메인 지식 그래프 데이터 적재
requires: [02_환경설정_및_스냅샷.sql]
next: [04_비즈니스_실측데이터_적재.sql]
*/

-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ KG_NODE/KG_EDGE 생성·적재 — 실제 실행 (노드 CELL_TYPE 10 + TISSUE 4, 엣지 subClassOf 9 + locatedIn 5)
--   💡 PRIMARY KEY / FOREIGN KEY 는 Snowflake 일반 테이블에서 강제되지 않습니다(메타데이터용). 무결성은 적재 시 직접 확인하십시오

-- 세션 컨텍스트 확인
USE ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
USE WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH;
USE DATABASE EDU06_IHCHO_ONTOLOGY_DB;
USE SCHEMA PUBLIC;

-- ============================================================================
-- [1.0] 온톨로지 노드 테이블 (KG_NODE) 생성
-- 엔티티 고유 ID, 표준 명칭, 유형, 유의어 목록, 상세 메타데이터(VARIANT) 저장
-- ============================================================================

CREATE OR REPLACE TABLE EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE (
    NODE_ID         VARCHAR(100) PRIMARY KEY,
    NAME            VARCHAR(255) NOT NULL,
    NODE_TYPE       VARCHAR(50)  NOT NULL, -- 'CELL_TYPE', 'TISSUE', 'DISEASE', 'DRUG'
    SYNONYMS        ARRAY,                 -- 도메인 유의어 목록
    PROPERTIES      VARIANT,               -- 확장 메타데이터 (정의, 출처 등)
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================================================
-- [2.0] 온톨로지 관계 엣지 테이블 (KG_EDGE) 생성
-- 소스 노드, 타겟 노드, 관계 유형(subClassOf, partOf, expressedIn 등), 가중치
-- ============================================================================

CREATE OR REPLACE TABLE EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE (
    EDGE_ID         VARCHAR(100) PRIMARY KEY,
    SRC_NODE_ID     VARCHAR(100) NOT NULL,
    DST_NODE_ID     VARCHAR(100) NOT NULL,
    EDGE_TYPE       VARCHAR(50)  NOT NULL, -- 'subClassOf', 'derivedFrom', 'locatedIn'
    METADATA        VARIANT,
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT FK_KG_EDGE_SRC FOREIGN KEY (SRC_NODE_ID) REFERENCES EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE(NODE_ID),
    CONSTRAINT FK_KG_EDGE_DST FOREIGN KEY (DST_NODE_ID) REFERENCES EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE(NODE_ID)
);

-- ============================================================================
-- [3.0] 세포 계통 및 생명과학 도메인 온톨로지 샘플 데이터 적재
-- Cell Ontology (CL) 표준 계층 구조 모방 데이터셋
-- ============================================================================

INSERT INTO EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE (NODE_ID, NAME, NODE_TYPE, SYNONYMS, PROPERTIES)
SELECT 
    column1 AS NODE_ID,
    column2 AS NAME,
    column3 AS NODE_TYPE,
    PARSE_JSON(column4) AS SYNONYMS,
    PARSE_JSON(column5) AS PROPERTIES
FROM (VALUES
    ('CL:0000000', 'cell', 'CELL_TYPE', '["cellule", "biological cell"]', '{"definition":"A basic unit of living organisms"}'),
    ('CL:0000003', 'native cell', 'CELL_TYPE', '["natural cell"]', '{"definition":"A cell that is found in a living organism"}'),
    ('CL:0000066', 'epithelial cell', 'CELL_TYPE', '["epitheliocyte", "lining cell"]', '{"definition":"A cell of the epithelium"}'),
    ('CL:0000076', 'squamous epithelial cell', 'CELL_TYPE', '["squamous cell", "flat epithelial"]', '{"definition":"A flat, thin epithelial cell"}'),
    ('CL:0000312', 'keratinocyte', 'CELL_TYPE', '["epidermal cell", "skin keratinocyte"]', '{"definition":"The primary type of cell found in the epidermis"}'),
    ('CL:0000099', 'columnar epithelial cell', 'CELL_TYPE', '["columnar cell"]', '{"definition":"An epithelial cell that is shaped like a column"}'),
    ('CL:0000151', 'secretory cell', 'CELL_TYPE', '["glandular cell"]', '{"definition":"A cell that produces secretions"}'),
    ('CL:0000160', 'goblet cell', 'CELL_TYPE', '["mucus-secreting goblet cell"]', '{"definition":"A column-shaped cell found in the respiratory and intestinal tracts"}'),
    ('CL:0000499', 'stromal cell', 'CELL_TYPE', '["connective tissue cell"]', '{"definition":"A cell that makes up the supporting tissue"}'),
    ('CL:0000057', 'fibroblast', 'CELL_TYPE', '["fibrocyte precursor"]', '{"definition":"A cell in connective tissue which produces collagen"}'),
    ('UBERON:0002048', 'lung', 'TISSUE', '["pulmonary tissue", "respiratory organ"]', '{"system":"respiratory"}'),
    ('UBERON:0002097', 'skin', 'TISSUE', '["dermis", "epidermis", "cutaneous"]', '{"system":"integumentary"}'),
    ('UBERON:0001043', 'esophagus', 'TISSUE', '["gullet", "esophageal tract"]', '{"system":"digestive"}'),
    ('UBERON:0001255', 'bladder', 'TISSUE', '["urinary bladder"]', '{"system":"urinary"}')
);

-- 계층 관계 (subClassOf) 및 조직 위치 관계 (locatedIn)
INSERT INTO EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE (EDGE_ID, SRC_NODE_ID, DST_NODE_ID, EDGE_TYPE, METADATA)
SELECT
    column1 AS EDGE_ID,
    column2 AS SRC_NODE_ID,
    column3 AS DST_NODE_ID,
    column4 AS EDGE_TYPE,
    PARSE_JSON(column5) AS METADATA
FROM (VALUES
    -- 계층 구조: keratinocyte -> squamous epithelial cell -> epithelial cell -> native cell -> cell
    ('E01', 'CL:0000003', 'CL:0000000', 'subClassOf', '{"confidence":1.0}'),
    ('E02', 'CL:0000066', 'CL:0000003', 'subClassOf', '{"confidence":1.0}'),
    ('E03', 'CL:0000076', 'CL:0000066', 'subClassOf', '{"confidence":1.0}'),
    ('E04', 'CL:0000312', 'CL:0000076', 'subClassOf', '{"confidence":1.0}'),
    ('E05', 'CL:0000099', 'CL:0000066', 'subClassOf', '{"confidence":1.0}'),
    ('E06', 'CL:0000151', 'CL:0000066', 'subClassOf', '{"confidence":1.0}'),
    ('E07', 'CL:0000160', 'CL:0000151', 'subClassOf', '{"confidence":1.0}'),
    ('E08', 'CL:0000499', 'CL:0000003', 'subClassOf', '{"confidence":1.0}'),
    ('E09', 'CL:0000057', 'CL:0000499', 'subClassOf', '{"confidence":1.0}'),
    -- 조직 매핑 관계 (locatedIn)
    ('E10', 'CL:0000312', 'UBERON:0002097', 'locatedIn', '{"organ":"skin"}'),
    ('E11', 'CL:0000076', 'UBERON:0002048', 'locatedIn', '{"organ":"lung"}'),
    ('E12', 'CL:0000076', 'UBERON:0001043', 'locatedIn', '{"organ":"esophagus"}'),
    ('E13', 'CL:0000076', 'UBERON:0001255', 'locatedIn', '{"organ":"bladder"}'),
    ('E14', 'CL:0000160', 'UBERON:0002048', 'locatedIn', '{"organ":"lung"}')
);

-- ============================================================================
-- [4.0] 데이터 적재 검증
-- ============================================================================

SELECT NODE_TYPE, COUNT(*) AS NODE_COUNT 
FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_NODE 
GROUP BY NODE_TYPE;

SELECT EDGE_TYPE, COUNT(*) AS EDGE_COUNT 
FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_EDGE 
GROUP BY EDGE_TYPE;

-- ============================================================================
-- 🧹 이 단계까지의 정리: 98_ PART A(DB 삭제)로 함께 삭제됩니다
-- ============================================================================
