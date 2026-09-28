/*
title: Cortex Search 서비스
step: 07
type: sql
summary: 중복 사본을 제외한 청크로 하이브리드(벡터+키워드) Cortex Search 서비스를 만들고, 긴 TARGET_LAG·AUTO_SUSPEND 로 인덱싱·서빙 비용을 줄인 뒤 한국어 질의로 검색 품질을 확인한다.
requires: 06_증분파이프라인_TriggeredTask.sql
next: 08_RAG_질의응답_및_캐시.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-28, 실습 완주)
--   ✅ CREATE CORTEX SEARCH SERVICE (EMBEDDING_MODEL, AUTO_SUSPEND=1800, TARGET_LAG='1 day') — 실제 실행
--   ✅ SEARCH_PREVIEW 한국어 질의 · 모델명/경보코드 키워드 질의 · ATTRIBUTES 필터 — 실제 실행
--   ✅ 원천 뷰의 중복 사본 제거 — 원천 행 수 + 대표 경로(원본 우선)로 확인. 1차 작성본 결함 1건 정정
--   ⚠️ AUTO_SUSPEND 의 실제 중지·자동 재개 — 30분 무질의가 필요해 관찰하지 않음 (공식 문서 근거)
--   ⚠️ TARGET_LAG='1 day' 의 시간 경과 자동 갱신 — 시간 경과가 필요해 미관찰. 수동 REFRESH 로 대체 확인
-- ==============================================================================

-- ==============================================================================
-- ⚙️ 설정값
--   원천 뷰      : DOCRAG_DB.SERVING.V_SEARCH_SOURCE
--   검색 서비스  : DOCRAG_DB.SERVING.DOC_SEARCH_SVC
--   임베딩 모델  : snowflake-arctic-embed-l-v2.0   ← 🔴 Multilingual (한국어 지원)
--   TARGET_LAG   : 1 day      (문서가 하루 몇 건 들어오는 운영 가정. 실습 중에는 수동 REFRESH)
--   AUTO_SUSPEND : 1800 초    (공식 문서상 최솟값 = 30분)
-- ==============================================================================

-- 💰 Cortex Search 비용 구성 — 공식 문서 기준 (요율은 Service Consumption Table 참고)
--   | 항목              | 발생 시점                          | 이 문서의 절감 수단                 |
--   |-------------------|------------------------------------|-------------------------------------|
--   | 임베딩 토큰       | 신규·변경 행을 인덱싱할 때        | 중복 사본 제외(뷰), 청크 재생성 최소화 |
--   | 인덱싱 WH 컴퓨트  | 갱신(REFRESH) 시                   | XS 웨어하우스, 긴 TARGET_LAG         |
--   | 서빙 컴퓨트       | 서비스가 **떠 있는 동안** 지속    | **AUTO_SUSPEND**, 실습 후 SUSPEND/DROP |
--   | 스토리지          | 인덱스 보관                        | 실습 후 DROP                          |
--   🔴 서빙 비용은 질의가 없어도 발생합니다. AUTO_SUSPEND 기본값은 NULL(비활성)입니다.
--      지정하지 않으면 서비스를 지울 때까지 계속 과금됩니다.
--
-- 💰 임베딩 모델 선택
--   · snowflake-arctic-embed-m-v1.5 는 더 작지만 **English-only** 입니다. 한국어 코퍼스에
--     쓰면 오류 없이 검색 품질만 나빠집니다. 비용만 보고 고르지 마십시오.
--   · 모델을 나중에 바꾸면 전체 재임베딩(재과금)이 필요합니다. 처음에 정하십시오.

USE ROLE DOCRAG_ADMIN_RL;
USE WAREHOUSE DOCRAG_WH;
USE SCHEMA DOCRAG_DB.SERVING;

-- ==============================================================================
-- [1] 검색 원천 뷰 — 💰 같은 내용(MD5)의 사본은 한 경로만 인덱싱합니다
--   사본까지 인덱싱하면 임베딩 토큰이 배로 들고, 검색 결과 상위가 같은 문장으로 채워져
--   RAG 컨텍스트에 쓸모 있는 청크가 줄어듭니다.
--   대표 경로 = DOC_PARSED.FIRST_PATH (그 내용을 **처음 파싱한** 경로)
--     단, 그 경로가 삭제되어 청크가 없으면 남은 경로 중 이름순 첫 번째로 대체합니다
--   🔴 1차 작성본은 "LOADED_AT 이 가장 이른 경로" 를 썼습니다. 05_ [6] 재청킹 후 모든 행의
--      LOADED_AT 이 같아져 동률이 되었고, 이름순 타이브레이크로 **사본(archive/)** 이
--      대표가 되었습니다(실측). 적재 시각은 재처리로 바뀌는 값이라 기준으로 쓰지 않습니다
-- ==============================================================================
CREATE OR REPLACE VIEW V_SEARCH_SOURCE
-- ⚠️ OR REPLACE: 뷰 정의만 교체됩니다 (데이터 없음)
COMMENT = '검색 원천(중복 사본 제외). [unstructured-doc-rag-pipeline]'
AS
SELECT c.FILE_PATH, c.CHUNK_INDEX, c.SECTION, c.CHUNK_TEXT,
       SPLIT_PART(c.FILE_PATH, '/', 1) AS DOC_FOLDER
FROM DOCRAG_DB.CURATED.DOC_CHUNKS c
LEFT JOIN DOCRAG_DB.CURATED.DOC_PARSED p ON p.FILE_MD5 = c.FILE_MD5
QUALIFY c.FILE_PATH = FIRST_VALUE(c.FILE_PATH)
        OVER (PARTITION BY c.FILE_MD5
              ORDER BY IFF(c.FILE_PATH = p.FIRST_PATH, 0, 1), c.FILE_PATH);

SELECT COUNT(*) AS ALL_CHUNKS FROM DOCRAG_DB.CURATED.DOC_CHUNKS;   -- 사본 포함
SELECT COUNT(*) AS INDEXED_CHUNKS, COUNT(DISTINCT FILE_PATH) AS FILES FROM V_SEARCH_SOURCE;  -- 사본 제외
SELECT DISTINCT FILE_PATH FROM V_SEARCH_SOURCE ORDER BY 1;   -- manuals/… 와 guides/… (archive/ 없음)

-- ==============================================================================
-- [2] 검색 서비스
--   · IF NOT EXISTS: 재실행 시 기존 인덱스를 보존합니다
--     정의(ON/ATTRIBUTES/쿼리)를 바꿔야 하면 DROP 후 재생성하십시오 (전체 재임베딩 = 재과금)
--   · 🔴 서비스의 원천 쿼리에 스트림·UDF 등 제약이 있습니다. 여기서는 단순 뷰 SELECT 입니다
-- ==============================================================================
CREATE CORTEX SEARCH SERVICE IF NOT EXISTS DOC_SEARCH_SVC
    ON CHUNK_TEXT
    ATTRIBUTES FILE_PATH, SECTION, DOC_FOLDER
    WAREHOUSE       = DOCRAG_WH
    TARGET_LAG      = '1 day'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
    AUTO_SUSPEND    = 1800
    COMMENT         = '기술문서 하이브리드 검색. [unstructured-doc-rag-pipeline]'
AS
    SELECT CHUNK_TEXT, FILE_PATH, SECTION, DOC_FOLDER
    FROM DOCRAG_DB.SERVING.V_SEARCH_SOURCE;

DESCRIBE CORTEX SEARCH SERVICE DOC_SEARCH_SVC;
--   확인: indexing_state / serving_state = ACTIVE, source_data_num_rows = 위 INDEXED_CHUNKS

-- ==============================================================================
-- [3] 검색 품질 확인 — 한국어 의미 질의 / 코드 키워드 질의 / 필터
-- ==============================================================================
-- (a) 의미 질의 — 문장이 달라도 관련 청크가 나와야 합니다
SELECT r.value:SECTION::VARCHAR AS SECTION, r.value:FILE_PATH::VARCHAR AS FILE_PATH,
       LEFT(r.value:CHUNK_TEXT::VARCHAR, 80) AS PREVIEW
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'DOCRAG_DB.SERVING.DOC_SEARCH_SVC',
    '{"query": "펌프 베어링 기름은 언제 갈아야 하나요?", "columns": ["CHUNK_TEXT","FILE_PATH","SECTION"], "limit": 3}'
)):results)) r;
--   기대: 1순위 '2. 정기 점검 주기' (manuals/XR-200)

-- (b) 코드 키워드 질의 — 05_ 하이픈 정규화가 여기서 효과를 냅니다
SELECT r.value:SECTION::VARCHAR AS SECTION, r.value:FILE_PATH::VARCHAR AS FILE_PATH
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'DOCRAG_DB.SERVING.DOC_SEARCH_SVC',
    '{"query": "C-42 경보", "columns": ["FILE_PATH","SECTION"], "limit": 3}'
)):results)) r;
--   기대: 1순위 '3. 비상 절차' (DC-9)

-- (c) ATTRIBUTES 필터 — 특정 폴더로 범위를 좁힙니다
SELECT r.value:FILE_PATH::VARCHAR AS FILE_PATH, r.value:SECTION::VARCHAR AS SECTION
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'DOCRAG_DB.SERVING.DOC_SEARCH_SVC',
    '{"query": "온도 기준", "columns": ["FILE_PATH","SECTION"], "filter": {"@eq": {"DOC_FOLDER": "guides"}}, "limit": 3}'
)):results)) r;
--   기대: guides/ 경로만

-- ==============================================================================
-- [4] 신규 문서 반영 — TARGET_LAG 를 기다리지 않고 수동으로 갱신
--   💰 수동 갱신도 인덱싱 비용이 발생합니다. 필요할 때만 실행하십시오
-- ==============================================================================
ALTER CORTEX SEARCH SERVICE DOC_SEARCH_SVC REFRESH;
--   반환 statistics 를 보십시오. 변경이 없으면 'No new data' 입니다.
--   💰 실측(2026-09-28): 위 [1] 뷰의 대표 경로 규칙을 바꾼 뒤 REFRESH 하자
--      {"insertedRows":6,"deletedRows":6} — **원천 행이 바뀐 만큼 전부 재임베딩**되었습니다.
--      원천 뷰·청크 규칙은 서비스를 만들기 전에 확정하는 것이 비용상 유리합니다.
--   ⚠️ 뷰 정의를 바꿔도 서비스는 다음 갱신 전까지 **옛 인덱스로 답합니다** (실측)

-- ==============================================================================
-- [5] 비용 제어 — 실습을 멈출 때
--   서빙만 멈춤(질의 불가, 서빙 비용 중지):  ALTER CORTEX SEARCH SERVICE DOC_SEARCH_SVC SUSPEND SERVING;
--   인덱싱만 멈춤(갱신 중지):                ALTER CORTEX SEARCH SERVICE DOC_SEARCH_SVC SUSPEND INDEXING;
--   재개:                                    ALTER CORTEX SEARCH SERVICE DOC_SEARCH_SVC RESUME SERVING;
-- ==============================================================================

-- ==============================================================================
-- 🧹 리소스 정리 (이 문서에서 만든 객체만. 정본은 98_)
-- ==============================================================================
-- DROP CORTEX SEARCH SERVICE IF EXISTS DOCRAG_DB.SERVING.DOC_SEARCH_SVC;
-- DROP VIEW IF EXISTS DOCRAG_DB.SERVING.V_SEARCH_SOURCE;
