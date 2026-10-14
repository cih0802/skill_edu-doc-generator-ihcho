/*
title: 온톨로지 그라운딩 Cortex Agent 및 용어 매핑 구현
step: 08
type: sql
summary: 실측 데이터용 Semantic View 를 만들고, Analyst 만 쓰는 Baseline Agent 와 온톨로지 검색(Cortex Search) + 용어 매핑 규칙을 갖춘 Grounded Agent 를 CREATE AGENT 로 구현해 같은 질문에 대한 도구 사용과 답변을 SQL 정답 기준과 비교합니다.
requires: [07_CortexSearch_온톨로지_인덱싱.sql]
next: [90_아키텍처_심화_및_벤치마크_분석.md]
*/

-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ [1] SQL 정답 기준 쿼리 2종 — 실제 실행
--   ✅ [2] CREATE SEMANTIC VIEW + SEMANTIC_VIEW() 질의 — 실제 실행
--   ✅ [3][4] CREATE AGENT 2종, SHOW AGENTS — 실제 실행
--   ✅ [5] DATA_AGENT_RUN 으로 두 Agent 에 같은 질문 2개 — 실제 실행. 사용 도구·답변 텍스트를 JSON 에서 추출
--   ⚠️ Agent 답변은 LLM 출력이라 실행마다 달라질 수 있습니다. 관찰은 표본 1회이며 정확도 수치를 주장하지 않습니다
--   ℹ️  1차 판은 Agent 를 만들지 않고 SQL 로 "시뮬레이션" 만 했습니다 (CREATE AGENT 0건).
--      그 SQL 은 [1] 의 정답 기준으로 남겼습니다

-- 세션 컨텍스트 확인
USE ROLE EDU06_IHCHO_ONTOLOGY_ROLE;
USE WAREHOUSE EDU06_IHCHO_ONTOLOGY_WH;
USE DATABASE EDU06_IHCHO_ONTOLOGY_DB;
USE SCHEMA PUBLIC;

-- ============================================================================
-- [0.0] 이 단계의 구조 — 블로그의 4단계 중 1단계(Baseline)와 4단계(GraphRAG + Term Mapping)를 직접 만듭니다
--
--   Baseline Agent  : cortex_analyst_text_to_sql (SEM_SCREENING_VIABILITY) 1개
--   Grounded Agent  : cortex_search (ONTOLOGY_SEARCH_SERVICE) + 같은 Analyst 도구
--                     + instructions.orchestration 에 용어 매핑 규칙
--
--   핵심 차이: SCREENING_VIABILITY 에는 "squamous epithelial cell" 같은 세포 계통 정보가 없습니다.
--   관계형 데이터만 보는 Baseline 은 "편평상피 유래 조직" 을 알 수 없고,
--   Grounded Agent 는 온톨로지 프로파일에서 조직 목록(skin, lung, esophagus, bladder)을 먼저 얻습니다.
-- ============================================================================

-- ============================================================================
-- [1.0] 정답 기준 (Ground Truth) — 온톨로지 규칙을 SQL 로 직접 적용한 결과
--   Agent 답변을 이 결과와 비교합니다.
-- ============================================================================

-- Q1. "squamous epithelial cell 계통 조직에서 Pembrolizumab 효과를 조직별로 비교"
--     기대: skin(0.215) < lung(0.30) < bladder(0.35) < esophagus(0.38) — 낮을수록 효과 큼
WITH GROUNDED_ONTOLOGY AS (
    SELECT CONCEPT_NAME, SPLIT(AGGREGATED_TISSUES_STR, ', ') AS TISSUE_ARRAY
    FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_FLATTENED_PROFILES
    WHERE CONCEPT_NAME = 'squamous epithelial cell'
),
EXPANDED_TISSUES AS (
    SELECT g.CONCEPT_NAME, TRIM(t.VALUE::STRING) AS TARGET_TISSUE
    FROM GROUNDED_ONTOLOGY g, LATERAL FLATTEN(input => g.TISSUE_ARRAY) t
)
SELECT 
    et.CONCEPT_NAME AS GROUNDED_CONCEPT,
    sv.PRIMARY_TISSUE,
    sv.DRUG_NAME,
    COUNT(DISTINCT sv.CELL_LINE_NAME) AS TESTED_CELL_LINES,
    ROUND(AVG(sv.VIABILITY_SCORE), 3) AS AVG_VIABILITY_SCORE
FROM EXPANDED_TISSUES et
JOIN EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY sv
  ON LOWER(et.TARGET_TISSUE) = LOWER(sv.PRIMARY_TISSUE)
WHERE sv.DRUG_NAME = 'Pembrolizumab'
GROUP BY et.CONCEPT_NAME, sv.PRIMARY_TISSUE, sv.DRUG_NAME
ORDER BY AVG_VIABILITY_SCORE ASC;

-- Q2. "internal organ lining 조직의 Pembrolizumab 반응" — 용어 매핑 규칙: lung, esophagus, bladder (skin 제외)
--     기대: lung(0.30) < bladder(0.35) < esophagus(0.38)
SELECT sv.PRIMARY_TISSUE, ROUND(AVG(sv.VIABILITY_SCORE), 3) AS AVG_VIABILITY
FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY sv
WHERE sv.PRIMARY_TISSUE IN ('lung', 'esophagus', 'bladder')
  AND sv.DRUG_NAME = 'Pembrolizumab'
GROUP BY sv.PRIMARY_TISSUE
ORDER BY AVG_VIABILITY ASC;

-- ============================================================================
-- [2.0] 실측 데이터 Semantic View — 두 Agent 의 Cortex Analyst 도구가 공유
--   의도적으로 세포 계통(온톨로지) 정보는 넣지 않습니다. 그것은 검색 도구의 몫입니다.
-- ============================================================================
CREATE OR REPLACE SEMANTIC VIEW EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SEM_SCREENING_VIABILITY
    TABLES (
        screening AS EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SCREENING_VIABILITY
            PRIMARY KEY (EXPERIMENT_ID)
            COMMENT = 'PRISM 형식 약물 스크리닝 실측. 세포주별 약물 처리 후 생존율'
    )
    FACTS (
        screening.viability_score AS VIABILITY_SCORE COMMENT = '세포 생존율 0~1. 낮을수록 약효가 큼'
    )
    DIMENSIONS (
        screening.primary_tissue AS PRIMARY_TISSUE COMMENT = '세포주 원발 조직 (소문자: lung, skin, esophagus, bladder, breast, liver)',
        screening.drug_name      AS DRUG_NAME      COMMENT = '약물명 (예: Pembrolizumab)',
        screening.target_pathway AS TARGET_PATHWAY COMMENT = '약물 표적 (예: PD-1, EGFR)',
        screening.cell_line_name AS CELL_LINE_NAME COMMENT = '세포주 이름 (예: A549)'
    )
    METRICS (
        screening.avg_viability   AS AVG(screening.viability_score) COMMENT = '평균 생존율 (낮을수록 효과 큼)',
        screening.cell_line_count AS COUNT(DISTINCT screening.CELL_LINE_NAME) COMMENT = '시험 세포주 수'
    )
    COMMENT = 'EDU-06 약물 스크리닝 실측 의미론적 계층';

SELECT * FROM SEMANTIC_VIEW(
    EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SEM_SCREENING_VIABILITY
    DIMENSIONS screening.primary_tissue
    METRICS screening.avg_viability, screening.cell_line_count
) ORDER BY primary_tissue;

-- ============================================================================
-- [3.0] Baseline Agent — 관계형 데이터(Analyst)만 사용
-- ============================================================================
CREATE OR REPLACE AGENT EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_BASELINE_AGENT
    COMMENT = 'EDU-06 Baseline: Semantic View(Analyst) 도구만 사용'
FROM SPECIFICATION
$$
models:
  orchestration: auto
orchestration:
  budget:
    seconds: 120
    tokens: 32000
instructions:
  response: "Answer in Korean. Show the tissues you used and the average viability per tissue. Lower viability means higher drug efficacy."
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: screening_analyst
      description: "Drug screening results: cell line, primary tissue, drug, target pathway, viability score."
tool_resources:
  screening_analyst:
    semantic_view: EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SEM_SCREENING_VIABILITY
    execution_environment:
      type: warehouse
      warehouse: EDU06_IHCHO_ONTOLOGY_WH
$$;

-- ============================================================================
-- [4.0] Grounded Agent — 온톨로지 검색 + Analyst + 용어 매핑 규칙
--   용어 매핑(Terminology Mapping)은 계층 순회만으로 풀리지 않는 복합 용어를 명시 규칙으로 고정합니다.
-- ============================================================================
CREATE OR REPLACE AGENT EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_GROUNDED_AGENT
    COMMENT = 'EDU-06 Flattened GraphRAG + Terminology Mapping: 온톨로지 검색 + Analyst'
FROM SPECIFICATION
$$
models:
  orchestration: auto
orchestration:
  budget:
    seconds: 180
    tokens: 48000
instructions:
  response: "Answer in Korean. Show the ontology concept you resolved, the tissues you used, and the average viability per tissue. Lower viability means higher drug efficacy."
  orchestration: |
    1. When the question mentions a cell type, cell lineage, or informal biological term, FIRST call ontology_search
       to resolve it to an ontology concept and read its 'Aggregated Relevant Tissues / Organs'.
    2. Then call screening_analyst, filtering primary_tissue to exactly those tissues (lowercase).
    3. Terminology mapping overrides (authoritative, apply before searching):
       - 'internal organ lining' -> tissues: lung, esophagus, bladder (exclude skin)
       - 'epidermal keratinocyte' -> tissue: skin
    4. Never include tissues that are not in the resolved list.
tools:
  - tool_spec:
      type: cortex_search
      name: ontology_search
      description: "Cell ontology profiles: concept name, synonyms, parents/children, and tissues rolled up from all descendant cell types."
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: screening_analyst
      description: "Drug screening results: cell line, primary tissue, drug, target pathway, viability score."
tool_resources:
  ontology_search:
    search_service: EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE
    max_results: 3
    id_column: NODE_ID
    title_column: CONCEPT_NAME
  screening_analyst:
    semantic_view: EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.SEM_SCREENING_VIABILITY
    execution_environment:
      type: warehouse
      warehouse: EDU06_IHCHO_ONTOLOGY_WH
$$;

SHOW AGENTS IN SCHEMA EDU06_IHCHO_ONTOLOGY_DB.PUBLIC;

-- ============================================================================
-- [5.0] 같은 질문을 두 Agent 에 실행 — DATA_AGENT_RUN (SQL 확인용 유틸리티. 앱 연동은 REST API 권장)
--   관찰할 것
--     ① 사용 도구: Grounded 는 ontology_search → screening_analyst 순서인가
--     ② 조직 목록: [1.0] 정답 기준과 같은가 (Q1: 4개 조직, Q2: skin 제외 3개)
--     ③ status / warnings: completed 여도 warnings 에 도구 접근 경고가 없는지
--   💰 호출마다 LLM 토큰 비용이 발생합니다
-- ============================================================================

-- 5-1. Q1 실행 결과를 임시 테이블에 담아 두 번 호출하지 않고 여러 관점으로 봅니다
CREATE OR REPLACE TEMPORARY TABLE AGENT_RUNS AS
SELECT 'BASELINE' AS AGENT, 'Q1' AS Q, TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_BASELINE_AGENT',
    $${"messages": [{"role": "user", "content": [{"type": "text",
      "text": "Compare Pembrolizumab efficacy across tissues of squamous epithelial cell origin."}]}]}$$)) AS J
UNION ALL
SELECT 'GROUNDED', 'Q1', TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_GROUNDED_AGENT',
    $${"messages": [{"role": "user", "content": [{"type": "text",
      "text": "Compare Pembrolizumab efficacy across tissues of squamous epithelial cell origin."}]}]}$$));

-- 5-2. Q2 (용어 매핑 규칙이 필요한 질문)
INSERT INTO AGENT_RUNS
SELECT 'BASELINE', 'Q2', TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_BASELINE_AGENT',
    $${"messages": [{"role": "user", "content": [{"type": "text",
      "text": "How do internal organ lining tissues respond to Pembrolizumab?"}]}]}$$))
UNION ALL
SELECT 'GROUNDED', 'Q2', TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_GROUNDED_AGENT',
    $${"messages": [{"role": "user", "content": [{"type": "text",
      "text": "How do internal organ lining tissues respond to Pembrolizumab?"}]}]}$$));

-- 5-3. 상태와 사용 도구 순서
--   💡 spec 에 없는 system_execute_sql·data_to_chart·server_skill 도 목록에 나옵니다 (2026-10-14 관찰).
--      Analyst 가 만든 SQL 을 실행하고 차트를 그리는 데 Agent 가 쓰는 내장 도구입니다
SELECT r.AGENT, r.Q, r.J:status::VARCHAR AS STATUS,
       ARRAY_AGG(c.value:tool_use:name::VARCHAR) WITHIN GROUP (ORDER BY c.index) AS TOOLS_USED,
       ARRAY_SIZE(COALESCE(r.J:warnings, ARRAY_CONSTRUCT())) AS WARNING_COUNT
FROM AGENT_RUNS r, LATERAL FLATTEN(input => r.J:content, OUTER => TRUE) c
WHERE c.value:type::VARCHAR = 'tool_use' OR c.value IS NULL
GROUP BY r.AGENT, r.Q, r.J
ORDER BY r.Q, r.AGENT;

-- 5-4. 판정 — Agent 가 실제로 실행한 SQL 의 조직 필터 (답변 문장이 아니라 실행 SQL 로 판정합니다)
--   💡 답변 텍스트에서 조직 이름을 키워드로 찾으면 "제외했다" 고 언급한 조직까지 잡혀 판정이 틀립니다
--   정답 기준: Q1 = bladder, esophagus, lung, skin / Q2 = lung, esophagus, bladder
SELECT r.AGENT, r.Q,
       REGEXP_SUBSTR(c.value:tool_use:input:sql::VARCHAR, 'IN \\([^)]*\\)', 1, 1, 'i') AS TISSUE_FILTER_IN_SQL
FROM AGENT_RUNS r, LATERAL FLATTEN(input => r.J:content) c
WHERE c.value:type::VARCHAR = 'tool_use'
  AND c.value:tool_use:name::VARCHAR = 'system_execute_sql'
ORDER BY r.Q, r.AGENT;

-- 5-5. 최종 답변 텍스트 (사람이 읽고 확인)
WITH t AS (
    SELECT r.AGENT, r.Q, LISTAGG(c.value:text::VARCHAR, '\n') WITHIN GROUP (ORDER BY c.index) AS TXT
    FROM AGENT_RUNS r, LATERAL FLATTEN(input => r.J:content) c
    WHERE c.value:type::VARCHAR = 'text'
    GROUP BY r.AGENT, r.Q
)
SELECT AGENT, Q, LEFT(TXT, 800) AS ANSWER_PREVIEW FROM t ORDER BY Q, AGENT;

-- 2026-10-14 관찰 (표본 1회. LLM 출력이므로 재실행 시 달라질 수 있음)
--   | Agent    | Q  | 사용 도구 (순서)                         | 실행 SQL 조직 필터                     | 정답 기준과 |
--   |----------|----|------------------------------------------|----------------------------------------|-------------|
--   | BASELINE | Q1 | screening_analyst → SQL 실행              | ('skin', 'esophagus')                  | 불일치 — lung·bladder 누락 (모델 자체 생물학 지식으로 판단) |
--   | GROUNDED | Q1 | ontology_search → screening_analyst      | ('bladder','esophagus','lung','skin')  | 일치 |
--   | BASELINE | Q2 | screening_analyst → SQL 실행              | ('lung','esophagus','bladder','liver') | 결과는 일치 (liver 는 Pembrolizumab 행이 없어 영향 없음), 필터는 규칙과 다름 |
--   | GROUNDED | Q2 | screening_analyst (검색 생략, 매핑 규칙 직접 적용) | ('lung','esophagus','bladder') | 일치 |
--   해석: 온톨로지 계층이 필요한 Q1 에서 차이가 드러났습니다. Q2 처럼 상식으로 풀리는 용어는 Baseline 도
--         비슷하게 답할 수 있어, 용어 매핑의 가치는 "결과 고정(재현성)" 쪽에 있습니다. 표본 1회로 정확도를 일반화하지 않습니다

-- ============================================================================
-- 🧹 이 단계까지의 정리
--   Semantic View·Agent 2종은 98_ PART A(DB 삭제)로 함께 삭제됩니다. AGENT_RUNS 는 임시 테이블(세션 종료 시 소멸)
-- ============================================================================
