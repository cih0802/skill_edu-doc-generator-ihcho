/*
title: RAG 질의응답 및 답변 캐시
step: 08
type: sql
summary: Cortex Search 상위 k개 청크를 근거로 AI_COMPLETE 가 출처 포함 답변을 생성하는 RAG 프로시저를 만들고, 설정 테이블(모델·k·최대 토큰)과 질문 해시 캐시로 LLM 호출 비용을 통제한다.
requires: 07_CortexSearch_서비스.sql
next: 09_Snowpark_품질평가_및_비용모니터링.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-28, 실습 완주)
--   ✅ 설정 테이블·캐시·질의 로그 테이블 — 실제 실행
--   ✅ SP_ASK — 실제 실행. 단일 문서 질문 / 두 문서에 걸친 질문 / 문서에 없는 질문 3종
--   ✅ 캐시 적중 — 같은 질문(공백·대소문자 달리) 2회차에서 CACHE_HIT=TRUE, LLM 미호출을 로그로 확인
--   ✅ 작성 중 발견·정정 4건: 연산자 우선순위, VALUES 내 함수, 캐시 응답 출처 누락, 캐시/로그 기록 순서
--   ✅ AI_COUNT_TOKENS 로 입력 토큰 추정 기록 — 실제 실행
--   ⚠️ LLM 출력은 비결정적입니다. 아래 기대 답변은 이번 실행의 관찰이며 항상 같다고 보장하지 않습니다
-- ==============================================================================

-- ==============================================================================
-- ⚙️ 설정값 (RAG_CONFIG 테이블로 관리 — 코드 수정 없이 바꿉니다)
--   MODEL          : claude-haiku-4-5   ← 🔴 고정값이 아닙니다. 02_ [0.5] 수명 게이트를 따르십시오
--   TOP_K          : 3                  (검색 청크 수 = 입력 토큰의 대부분)
--   MAX_TOKENS     : 400                (출력 토큰 상한)
--   CACHE_TTL_HOURS: 24                 (문서가 바뀌면 캐시는 자동 무효화 — 아래 [2] 설명)
-- ==============================================================================

-- 💰 비용 최적화 설계 — LLM 비용은 (입력 토큰 + 출력 토큰) × 모델 요율
--   ① 입력 토큰 통제: TOP_K 를 작게, 청크를 짧게(05_ 800자). 컨텍스트가 곧 비용입니다
--   ② 출력 토큰 통제: max_tokens 상한 + "간결하게" 지침
--   ③ 호출 자체를 줄임: 같은 질문은 캐시에서 답합니다 (LLM 0회)
--   ④ 모델 선택: 작은 모델로 충분한지 09_ 평가로 판단하십시오. 큰 모델이 늘 나은 것은 아닙니다
--   ⑤ temperature 0: 같은 입력에 같은 경향의 답 → 캐시 재사용이 의미를 가집니다

USE ROLE DOCRAG_ADMIN_RL;
USE WAREHOUSE DOCRAG_WH;
USE SCHEMA DOCRAG_DB.SERVING;

-- ==============================================================================
-- [1] 설정·캐시·로그 테이블
-- ==============================================================================
CREATE TABLE IF NOT EXISTS RAG_CONFIG (
    CONFIG_KEY   VARCHAR,
    CONFIG_VALUE VARCHAR
) COMMENT = 'RAG 런타임 설정. [unstructured-doc-rag-pipeline]';

-- MERGE 로 넣어 재실행해도 중복 행이 생기지 않게 합니다
MERGE INTO RAG_CONFIG t
USING (SELECT * FROM VALUES
        ('MODEL', 'claude-haiku-4-5'),
        ('TOP_K', '3'),
        ('MAX_TOKENS', '400'),
        ('CACHE_TTL_HOURS', '24')) s(K, V)
ON t.CONFIG_KEY = s.K
WHEN NOT MATCHED THEN INSERT (CONFIG_KEY, CONFIG_VALUE) VALUES (s.K, s.V);

CREATE TABLE IF NOT EXISTS ANSWER_CACHE (
    QUESTION_HASH VARCHAR,          -- 정규화한 질문 + 모델 + 코퍼스 버전의 해시
    QUESTION      VARCHAR,
    ANSWER        VARCHAR,
    SOURCES       VARCHAR,
    CREATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'RAG 답변 캐시. [unstructured-doc-rag-pipeline]';

CREATE TABLE IF NOT EXISTS QUERY_LOG (
    ASKED_AT       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    QUESTION       VARCHAR,
    MODEL          VARCHAR,
    CACHE_HIT      BOOLEAN,
    CONTEXT_CHARS  INTEGER,
    PROMPT_TOKENS_EST INTEGER,      -- AI_COUNT_TOKENS 추정치 (캐시 적중 시 NULL = LLM 미호출)
    SOURCES        VARCHAR,
    ANSWER         VARCHAR
) COMMENT = 'RAG 질의 로그. [unstructured-doc-rag-pipeline]';

-- ==============================================================================
-- [2] RAG 프로시저
--   캐시 키에 "코퍼스 버전" 을 넣는 이유: 문서가 추가·삭제되면 같은 질문이라도 답이 달라져야
--   합니다. 코퍼스 버전 = 청크 테이블의 (행 수, 최신 적재 시각) → 바뀌면 캐시가 자연히 빗나갑니다
--
--   🔴 SEARCH_PREVIEW 두 번째 인자는 함수 표현식을 받지 않습니다 — VARCHAR 변수로 만들어 넘깁니다
--   🔴 TO_JSON 은 VARIANT 를 받습니다 — TO_VARIANT 로 감싸야 합니다 (질문의 따옴표도 안전하게 이스케이프)
--   🔴 AI_COMPLETE(model, messages[], options) 는 **VARCHAR** 를 돌려줍니다
--      (구 SNOWFLAKE.CORTEX.COMPLETE 는 OBJECT 를 돌려줘 :choices[0] 추출이 필요했습니다. 혼용 금지)
--      위 세 가지는 EDU-02 에서 실측으로 확인된 함정입니다
-- ==============================================================================
CREATE OR REPLACE PROCEDURE SP_ASK(QUESTION VARCHAR)
-- ⚠️ OR REPLACE: 프로시저 정의만 교체됩니다
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = '기술문서 RAG 질의응답(캐시 포함). [unstructured-doc-rag-pipeline]'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_model     VARCHAR;
    v_top_k     VARCHAR;
    v_max_tok   INTEGER;
    v_ttl       INTEGER;
    v_norm      VARCHAR;
    v_hash      VARCHAR;
    v_cached    VARCHAR;
    v_req       VARCHAR;
    v_context   VARCHAR;
    v_sources   VARCHAR;
    v_system    VARCHAR;
    v_tokens    INTEGER;
    v_answer    VARCHAR;
    v_ctx_len   INTEGER;
BEGIN
    SELECT MAX(IFF(CONFIG_KEY = 'MODEL',           CONFIG_VALUE, NULL)),
           MAX(IFF(CONFIG_KEY = 'TOP_K',           CONFIG_VALUE, NULL)),
           MAX(IFF(CONFIG_KEY = 'MAX_TOKENS',      CONFIG_VALUE, NULL))::INTEGER,
           MAX(IFF(CONFIG_KEY = 'CACHE_TTL_HOURS', CONFIG_VALUE, NULL))::INTEGER
      INTO :v_model, :v_top_k, :v_max_tok, :v_ttl
      FROM DOCRAG_DB.SERVING.RAG_CONFIG;

    -- TOP_K 는 JSON 문자열에 숫자로 결합됩니다. 숫자가 아니면 거부합니다 (설정값 주입 방어)
    IF (NOT RLIKE(:v_top_k, '[1-9][0-9]?')) THEN
        RETURN '설정 오류: TOP_K 는 1~99 정수여야 합니다';
    END IF;

    -- (1) 캐시 조회 — 공백·대소문자만 다른 질문은 같은 질문으로 봅니다
    v_norm := LOWER(REGEXP_REPLACE(TRIM(:QUESTION), '\\s+', ' '));
    SELECT SHA2(:v_norm || '|' || :v_model || '|' || COUNT(*) || '|' || COALESCE(MAX(LOADED_AT)::VARCHAR, ''))
      INTO :v_hash
      FROM DOCRAG_DB.CURATED.DOC_CHUNKS;

    -- 🔴 캐시 응답에도 출처를 붙입니다. 1차 작성본은 ANSWER 만 돌려줘 캐시 적중 시
    --    **출처 줄이 사라졌습니다**(실측). 같은 질문인데 근거 표시가 달라지면 안 됩니다
    SELECT MAX(ANSWER), MAX(SOURCES) INTO :v_cached, :v_sources
      FROM DOCRAG_DB.SERVING.ANSWER_CACHE
     WHERE QUESTION_HASH = :v_hash
       AND CREATED_AT >= DATEADD(HOUR, -:v_ttl, CURRENT_TIMESTAMP());

    IF (v_cached IS NOT NULL) THEN
        INSERT INTO DOCRAG_DB.SERVING.QUERY_LOG (QUESTION, MODEL, CACHE_HIT, SOURCES, ANSWER)
            VALUES (:QUESTION, :v_model, TRUE, :v_sources, :v_cached);
        RETURN v_cached || '\n\n(출처: ' || COALESCE(v_sources, '없음') || ') [캐시]';
    END IF;

    -- (2) 검색 — 상위 TOP_K 청크
    v_req := '{"query": ' || TO_JSON(TO_VARIANT(:QUESTION))
          || ', "columns": ["CHUNK_TEXT","FILE_PATH","SECTION"], "limit": ' || v_top_k || '}';

    -- 🔴 괄호 필수: '||' 가 '+' 보다 먼저 결합되어 '[출처 0' + 1 을 계산하려다 실패합니다
    --    (실측: Numeric value '[출처 0' is not recognized)
    SELECT LISTAGG('[출처 ' || (r.index + 1) || '] ' || r.value:CHUNK_TEXT::VARCHAR, '\n\n'),
           LISTAGG(DISTINCT r.value:FILE_PATH::VARCHAR || '#' || r.value:SECTION::VARCHAR, ' ; ')
      INTO :v_context, :v_sources
      FROM TABLE(FLATTEN(input => PARSE_JSON(
               SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCRAG_DB.SERVING.DOC_SEARCH_SVC', :v_req)
           ):results)) r;

    -- (3) 생성 — 컨텍스트 밖의 내용은 답하지 않도록 지시
    v_system := '당신은 설비 기술문서 도우미입니다. 아래 <문서> 의 내용만 근거로 한국어로 간결하게 답하십시오.\n'
        || '- 답의 근거가 된 [출처 N] 번호를 문장 끝에 표시하십시오.\n'
        || '- 문서에 없는 내용이면 추측하지 말고 정확히 "문서에서 찾을 수 없습니다." 라고만 답하십시오.\n'
        || '<문서>\n' || COALESCE(v_context, '') || '\n</문서>';

    SELECT AI_COUNT_TOKENS('ai_complete', :v_model, :v_system || :QUESTION) INTO :v_tokens;

    SELECT AI_COMPLETE(
               :v_model,
               [ {'role': 'system', 'content': :v_system},
                 {'role': 'user',   'content': :QUESTION} ],
               {'temperature': 0, 'max_tokens': :v_max_tok}
           ) INTO :v_answer;

    -- (4) 캐시·로그 — 로그를 먼저 씁니다. 캐시를 먼저 쓰면 로그 INSERT 가 실패했을 때
    --     "기록 없는 캐시" 가 남아 다음 호출이 원인 모를 캐시 적중이 됩니다 (작성 중 실측)
    -- 🔴 VALUES 절에는 함수 호출을 쓸 수 없습니다 (실측: Invalid expression [LENGTH(:v_context)] in VALUES clause)
    --    변수에 먼저 계산해 둡니다
    v_ctx_len := LENGTH(:v_context);
    INSERT INTO DOCRAG_DB.SERVING.QUERY_LOG
        (QUESTION, MODEL, CACHE_HIT, CONTEXT_CHARS, PROMPT_TOKENS_EST, SOURCES, ANSWER)
        VALUES (:QUESTION, :v_model, FALSE, :v_ctx_len, :v_tokens, :v_sources, :v_answer);
    INSERT INTO DOCRAG_DB.SERVING.ANSWER_CACHE (QUESTION_HASH, QUESTION, ANSWER, SOURCES)
        VALUES (:v_hash, :QUESTION, :v_answer, :v_sources);

    RETURN v_answer || '\n\n(출처: ' || COALESCE(v_sources, '없음') || ')';
END;
$$;

-- ==============================================================================
-- [3] 질의 — 세 종류를 시험합니다
-- ==============================================================================
-- 🔴 실습을 다시 할 때는 캐시·로그를 먼저 비우십시오. 이전 실행의 캐시가 남아 있으면
--    (a) 가 첫 호출인데도 캐시 적중으로 나옵니다 (작성 중 실측: 실패한 실행이 캐시만 남겼다)
TRUNCATE TABLE ANSWER_CACHE;
TRUNCATE TABLE QUERY_LOG;

-- (a) 단일 문서
CALL SP_ASK('XR-200 펌프 진동이 기준을 넘으면 어떻게 해야 하나요?');
--   관찰: 4.5 mm/s 초과 시 운전 중지·정렬 점검, [출처] 표시

-- (b) 두 문서에 걸친 질문 — C-42(DC-9 지침) → XR-200(펌프 매뉴얼)
CALL SP_ASK('C-42 경보가 뜨면 먼저 무엇을 확인하고, 그 설비의 윤활유 교체 주기는?');
--   관찰: 두 파일이 모두 출처에 나와야 합니다

-- (c) 문서에 없는 질문 — 지어내지 않아야 합니다
CALL SP_ASK('XR-200 펌프의 구매 가격은 얼마인가요?');
--   관찰: "문서에서 찾을 수 없습니다."

-- (d) 💰 캐시 적중 — (a) 와 공백·대소문자만 다른 질문
CALL SP_ASK('  xr-200 펌프   진동이 기준을 넘으면 어떻게 해야 하나요?  ');

-- 결과로 단정합니다 — CACHE_HIT=TRUE 인 행은 PROMPT_TOKENS_EST 가 NULL(=LLM 미호출)
SELECT ASKED_AT, LEFT(QUESTION, 30) AS Q, CACHE_HIT, CONTEXT_CHARS, PROMPT_TOKENS_EST, SOURCES
FROM QUERY_LOG ORDER BY ASKED_AT;

-- ==============================================================================
-- [4] 설정 변경 예 — 코드 수정 없이 모델·k 를 바꿉니다
--   UPDATE RAG_CONFIG SET CONFIG_VALUE = '2'   WHERE CONFIG_KEY = 'TOP_K';
--   UPDATE RAG_CONFIG SET CONFIG_VALUE = 'llama3.1-8b' WHERE CONFIG_KEY = 'MODEL';
--     ↑ 리전 내 GA 모델(크로스 리전 불필요). 한국어 품질은 09_ 평가로 확인하십시오
--   모델을 바꾸면 캐시 키가 달라져 기존 캐시는 쓰이지 않습니다 (의도된 동작)
-- ==============================================================================

-- ==============================================================================
-- 🧹 리소스 정리 (이 문서에서 만든 객체만. 정본은 98_)
-- ==============================================================================
-- DROP PROCEDURE IF EXISTS DOCRAG_DB.SERVING.SP_ASK(VARCHAR);
-- DROP TABLE IF EXISTS DOCRAG_DB.SERVING.QUERY_LOG;
-- DROP TABLE IF EXISTS DOCRAG_DB.SERVING.ANSWER_CACHE;
-- DROP TABLE IF EXISTS DOCRAG_DB.SERVING.RAG_CONFIG;
