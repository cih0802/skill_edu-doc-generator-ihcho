/*
title: Snowpark 품질 평가 및 비용 모니터링
step: 09
type: sql
summary: Snowpark DataFrame API 로 작성한 Python 저장 프로시저가 평가셋을 SP_ASK 로 돌려 키워드·출처·거절 정확도를 채점하고, 파이프라인 로그·질의 로그·계정 사용량 뷰로 비용을 점검한다.
requires: 08_RAG_질의응답_및_캐시.sql
next: 10_CortexAgent_구성.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-28, 실습 완주)
--   ✅ EVAL_SET 생성 · SP_EVALUATE_RAG(Snowpark DataFrame) 생성·호출 — 실제 실행
--   ✅ 채점 결과를 EVAL_RESULT 테이블로 확인 (반환 메시지가 아니라 테이블로 단정)
--   ✅ [3] 파이프라인·질의 로그 집계 — 실제 실행
--   ✅ [4] ACCOUNT_USAGE 비용 뷰 3종 — 실제 실행. 작성 시점에는 실습 시작 약 40분 뒤 이미 반영되어
--        있었으나, 공식 문서상 지연이 있으므로 0행이어도 정상일 수 있습니다
--   ✅ 작성 중 발견·정정 1건: Snowpark create_dataframe 의 TIMESTAMP 타입 추론 불일치 (아래 [2])
--   ⚠️ 평가 표본은 5문항입니다. 이 점수로 모델·설정의 우열을 일반화하지 마십시오
-- ==============================================================================

-- ==============================================================================
-- ⚙️ 설정값
--   평가셋       : DOCRAG_DB.SERVING.EVAL_SET
--   평가 결과    : DOCRAG_DB.SERVING.EVAL_RESULT
--   평가 프로시저: DOCRAG_DB.SERVING.SP_EVALUATE_RAG(RUN_LABEL VARCHAR)
-- ==============================================================================

-- 💰 비용 최적화 관점의 평가
--   · 채점은 **규칙 기반**(키워드·출처 포함 여부)입니다. LLM-as-judge 를 쓰면 평가 자체가
--     문항당 LLM 호출을 추가로 만듭니다. 소규모 실습에서는 규칙 채점으로 충분합니다
--   · 평가는 캐시를 **우회하지 않습니다**. 같은 설정으로 두 번 돌리면 두 번째는 LLM 0회입니다.
--     설정(모델·TOP_K)을 바꾸면 캐시 키가 달라져 새로 호출됩니다 — 비교 평가는 그때만 과금됩니다

USE ROLE DOCRAG_ADMIN_RL;
USE WAREHOUSE DOCRAG_WH;
USE SCHEMA DOCRAG_DB.SERVING;

-- ==============================================================================
-- [1] 평가셋 — 질문, 답에 들어가야 할 키워드, 출처에 들어가야 할 파일, 거절 기대 여부
-- ==============================================================================
CREATE TABLE IF NOT EXISTS EVAL_SET (
    QID              INTEGER,
    QUESTION         VARCHAR,
    EXPECT_KEYWORDS  ARRAY,         -- 전부 포함되어야 정답
    EXPECT_SOURCE    VARCHAR,       -- 출처에 이 문자열이 있어야 함 (NULL = 확인 안 함)
    EXPECT_REFUSAL   BOOLEAN        -- "문서에서 찾을 수 없습니다" 를 기대
) COMMENT = 'RAG 평가셋. [unstructured-doc-rag-pipeline]';

-- 재실행 시 중복 방지: QID 기준 MERGE
MERGE INTO EVAL_SET t
USING (
    SELECT 1 QID, '메카니컬 씰 교체 기준은?' Q, ARRAY_CONSTRUCT('8,000') K, 'XR-200' S, FALSE R UNION ALL
    SELECT 2, '서버실 급기 온도 허용 범위는?',        ARRAY_CONSTRUCT('18', '27'),    'DC-9',   FALSE UNION ALL
    SELECT 3, 'E-17 경보 조치 방법은?',               ARRAY_CONSTRUCT('필터'),         'XR-200', FALSE UNION ALL
    SELECT 4, '칠러 1대가 멈추면 몇 분 안에 예비 칠러를 기동하나?', ARRAY_CONSTRUCT('5'), 'DC-9', FALSE UNION ALL
    SELECT 5, 'XR-200 펌프 제조사 연락처는?',          ARRAY_CONSTRUCT(),               NULL,     TRUE
) s
ON t.QID = s.QID
WHEN NOT MATCHED THEN INSERT (QID, QUESTION, EXPECT_KEYWORDS, EXPECT_SOURCE, EXPECT_REFUSAL)
                      VALUES (s.QID, s.Q, s.K, s.S, s.R);

CREATE TABLE IF NOT EXISTS EVAL_RESULT (
    RUN_LABEL     VARCHAR,
    RUN_AT        TIMESTAMP_LTZ,
    QID           INTEGER,
    MODEL         VARCHAR,
    TOP_K         VARCHAR,
    KEYWORD_OK    BOOLEAN,
    SOURCE_OK     BOOLEAN,
    REFUSAL_OK    BOOLEAN,
    PASSED        BOOLEAN,
    ANSWER        VARCHAR
) COMMENT = 'RAG 평가 결과. [unstructured-doc-rag-pipeline]';

-- ==============================================================================
-- [2] Snowpark 평가 프로시저 — DataFrame API
--   Python 핸들러는 session 을 첫 인자로 받습니다. SQL 을 문자열로 조립하지 않고
--   DataFrame(session.table / filter / select) 으로 읽고, 결과는 DataFrame.write 로 적재합니다.
--   SP_ASK 호출은 session.call — 인자를 **바인드**하므로 질문 문자열 주입 위험이 없습니다
--
--   Snowflake 의미론 주의 (pandas 와 다름)
--   · ARRAY 컬럼은 Python 에서 **JSON 문자열**로 들어옵니다 → json.loads 로 풀어야 합니다
--   · NULL 은 None 입니다. EXPECT_SOURCE 가 NULL 이면 출처 채점을 건너뜁니다
-- ==============================================================================
CREATE OR REPLACE PROCEDURE SP_EVALUATE_RAG(RUN_LABEL VARCHAR)
-- ⚠️ OR REPLACE: 프로시저 정의만 교체됩니다
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
COMMENT = 'Snowpark DataFrame 기반 RAG 평가. [unstructured-doc-rag-pipeline]'
EXECUTE AS OWNER
AS
$$
import json
from snowflake.snowpark import Row
from snowflake.snowpark.functions import col

REFUSAL = '문서에서 찾을 수 없습니다'

def run(session, run_label: str) -> str:
    cfg = {r['CONFIG_KEY']: r['CONFIG_VALUE']
           for r in session.table('DOCRAG_DB.SERVING.RAG_CONFIG').collect()}
    run_at = session.sql('SELECT CURRENT_TIMESTAMP()').collect()[0][0]

    rows = []
    for q in session.table('DOCRAG_DB.SERVING.EVAL_SET').sort(col('QID')).collect():
        answer = session.call('DOCRAG_DB.SERVING.SP_ASK', q['QUESTION']) or ''
        body, _, src = answer.partition('(출처:')      # SP_ASK 는 답 뒤에 "(출처: …)" 를 붙인다

        keywords = json.loads(q['EXPECT_KEYWORDS']) if q['EXPECT_KEYWORDS'] else []
        refused = REFUSAL in body
        if q['EXPECT_REFUSAL']:
            kw_ok, src_ok, ref_ok = None, None, refused
        else:
            kw_ok  = all(k in body for k in keywords)
            src_ok = None if q['EXPECT_SOURCE'] is None else (q['EXPECT_SOURCE'] in src)
            ref_ok = not refused
        passed = all(v for v in (kw_ok, src_ok, ref_ok) if v is not None)

        # 컬럼 순서 = EVAL_RESULT 정의 순서 (아래에서 대상 스키마를 그대로 씁니다)
        rows.append(Row(run_label, run_at, q['QID'], cfg.get('MODEL'), cfg.get('TOP_K'),
                        kw_ok, src_ok, ref_ok, passed, answer[:2000]))

    if rows:
        # 🔴 스키마를 대상 테이블에서 가져와 명시합니다. 추론에 맡기면 시간대가 붙은 datetime 이
        #    TIMESTAMP_TZ 로 추론되어 LTZ 컬럼 적재가 실패합니다 (실측:
        #    "expecting TIMESTAMP_LTZ(9) but got TIMESTAMP_TZ(9) for column RUN_AT")
        target = session.table('DOCRAG_DB.SERVING.EVAL_RESULT')
        (session.create_dataframe(rows, schema=target.schema)
                .write.mode('append').save_as_table('DOCRAG_DB.SERVING.EVAL_RESULT'))

    n_pass = sum(1 for r in rows if r[8])
    return f'{run_label}: {n_pass}/{len(rows)} passed'
$$;

-- 기준 설정(claude-haiku-4-5, TOP_K=3)으로 평가
CALL SP_EVALUATE_RAG('baseline');          -- ← 반환값은 참고용입니다

-- 결과로 단정합니다
SELECT QID, MODEL, TOP_K, KEYWORD_OK, SOURCE_OK, REFUSAL_OK, PASSED, LEFT(ANSWER, 60) AS ANSWER
FROM EVAL_RESULT WHERE RUN_LABEL = 'baseline' ORDER BY QID;

-- [2-1] (선택) 💰 더 작은 설정과 비교 — TOP_K 2 로 입력 토큰을 줄였을 때 품질이 유지되는가
-- UPDATE RAG_CONFIG SET CONFIG_VALUE = '2' WHERE CONFIG_KEY = 'TOP_K';
-- CALL SP_EVALUATE_RAG('topk2');
-- UPDATE RAG_CONFIG SET CONFIG_VALUE = '3' WHERE CONFIG_KEY = 'TOP_K';   -- 원복
-- SELECT RUN_LABEL, COUNT_IF(PASSED) AS PASSED, COUNT(*) AS TOTAL
-- FROM EVAL_RESULT GROUP BY RUN_LABEL;
--   ⚠️ TOP_K 는 캐시 키에 들어가지 않습니다. 비교 전에 TRUNCATE TABLE ANSWER_CACHE; 를 실행하십시오.
--      그렇지 않으면 baseline 의 캐시 답이 그대로 재사용되어 비교가 무의미해집니다

-- ==============================================================================
-- [3] 비용 점검 (1) — 이 실습이 직접 남긴 로그 (지연 없음)
-- ==============================================================================
-- (a) 💰 파싱 비용의 근거: 실제로 AI_PARSE_DOCUMENT 를 호출한 파일 수 vs 재사용
SELECT SUM(FILES_PARSED) AS PARSE_CALLS, SUM(FILES_REUSED) AS REUSED,
       SUM(FILES_FAILED) AS FAILED, COUNT(*) AS RUNS
FROM DOCRAG_DB.CURATED.PIPELINE_RUN_LOG;
SELECT SUM(PAGE_COUNT) AS PAGES_PARSED FROM DOCRAG_DB.CURATED.DOC_PARSED;   -- 과금 단위 = 페이지

-- (b) 💰 LLM 호출 비용의 근거: 캐시 적중률과 입력 토큰 추정치 합
SELECT COUNT(*)                            AS QUESTIONS,
       COUNT_IF(CACHE_HIT)                 AS CACHE_HITS,
       COUNT_IF(NOT CACHE_HIT)             AS LLM_CALLS,
       SUM(PROMPT_TOKENS_EST)              AS PROMPT_TOKENS_EST_TOTAL,
       ROUND(AVG(IFF(CACHE_HIT, NULL, CONTEXT_CHARS))) AS AVG_CONTEXT_CHARS
FROM QUERY_LOG;
--   출력 토큰은 이 로그에 없습니다. [4] 의 계정 사용량 뷰로 확인하십시오

-- ==============================================================================
-- [4] 비용 점검 (2) — 계정 사용량 뷰 (ACCOUNTADMIN 또는 USAGE_VIEWER 필요)
--   🔴 ACCOUNT_USAGE 는 **최대 수 시간 지연**됩니다. 실습 직후에는 0행이 정상일 수 있습니다
--   🔴 뷰가 없는 계정·에디션도 있습니다. 오류가 나면 이 절을 건너뛰십시오
-- ==============================================================================
USE ROLE ACCOUNTADMIN;

-- (a) 웨어하우스 크레딧 — 리소스 모니터 상한과 비교
SELECT WAREHOUSE_NAME, SUM(CREDITS_USED) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE WAREHOUSE_NAME = 'DOCRAG_WH' AND START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
GROUP BY 1;

-- (b) Cortex Search 서빙·임베딩 — 서비스 단위 일별
SELECT USAGE_DATE, SERVICE_NAME, CONSUMPTION_TYPE, SUM(CREDITS) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
WHERE DATABASE_NAME = 'DOCRAG_DB' AND USAGE_DATE >= DATEADD(DAY, -7, CURRENT_DATE())
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- (c) 서비스 유형별 합계 — AI 함수(파싱·생성)를 포함한 전체 그림
SELECT SERVICE_TYPE, SUM(CREDITS_USED) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD(DAY, -7, CURRENT_DATE())
GROUP BY 1 ORDER BY 2 DESC;
--   ⚠️ 이 뷰는 계정 전체 합계입니다. 이 실습만 분리해 보여주지 않습니다
--
-- 📏 작성 시점 참고값 (측정: 2026-09-28 01:15 PDT, 계정 LJ20513, 1회 측정 — 계정·데이터마다 다름)
--   조건: 1쪽 PDF 2종(+사본 1), 파싱 2회·실패 1회, 청크 6(인덱싱), 질의 14건(LLM 8회·캐시 6회)
--   | 항목                                    | 값            | 출처 뷰                              |
--   |-----------------------------------------|---------------|--------------------------------------|
--   | DOCRAG_WH 크레딧 (작성 중 재실행 포함)   | 약 0.22       | WAREHOUSE_METERING_HISTORY           |
--   | Cortex Search 임베딩                    | 약 0.00006    | CORTEX_SEARCH_DAILY_USAGE_HISTORY    |
--   | 계정 AI_FUNCTIONS 합계 (다른 사용 포함 가능) | 약 0.018  | METERING_DAILY_HISTORY               |
--   이 값은 **이번 1회 관찰**이며 비교·예산의 기준값이 아닙니다. 크레딧 대부분이 웨어하우스였던
--   이유는 작성 중 스크립트를 여러 번 재실행했기 때문입니다. 실습자는 자신의 값을 위 쿼리로 확인하십시오.

USE ROLE DOCRAG_ADMIN_RL;

-- ==============================================================================
-- 🧹 리소스 정리 (이 문서에서 만든 객체만. 정본은 98_)
-- ==============================================================================
-- DROP PROCEDURE IF EXISTS DOCRAG_DB.SERVING.SP_EVALUATE_RAG(VARCHAR);
-- DROP TABLE IF EXISTS DOCRAG_DB.SERVING.EVAL_RESULT;
-- DROP TABLE IF EXISTS DOCRAG_DB.SERVING.EVAL_SET;
