/*
title: 문서 파싱 및 Snowpark 청킹
step: 05
type: sql
summary: AI_PARSE_DOCUMENT 로 신규 파일만 1회 파싱(MD5 중복 제거)하고, Snowpark Python UDTF 로 섹션 인식 청킹·하이픈 정규화를 수행해 청크 테이블에 적재하는 증분 프로시저를 만든다.
requires: 04_문서업로드_안내.md
next: 06_증분파이프라인_TriggeredTask.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-28, 실습 완주)
--   ✅ [1] 테이블 4종 생성 — 실제 실행
--   ✅ [2] Python UDTF CHUNK_TECH_DOC — 실제 실행. 입력은 **실제 AI_PARSE_DOCUMENT 출력**으로 시험
--   ✅ [3] SP_INGEST_NEW_DOCS — 실제 실행. 1회차 파싱 1건 / 2회차 0건(멱등) 을 결과 테이블로 확인
--   ✅ [5] 예외 경로 — 존재하지 않는 파일을 inbox 에 넣어 **의도적으로 실패시켜** FAILED 로그 + RAISE + INBOX 보존 확인
--   ✅ [5-1] error 객체 경로 — 잘린 PDF 로 실측. 1차 작성본은 이 파일을 **기록 없이 버렸다**(결함). 격리 테이블로 정정 후 재검증
--   ⚠️ DOCX/PPTX/스캔 이미지 PDF — 텍스트 PDF 1종으로만 확인
-- ==============================================================================

-- ==============================================================================
-- ⚙️ 설정값
--   파싱 모드 : LAYOUT (표를 마크다운 표로 보존. 섹션·표 경계를 청커가 활용)
--   청크 크기 : 최대 800자, 겹침(overlap) 1문단(최대 200자)
--   파이썬    : RUNTIME_VERSION 3.11, 외부 패키지 없음(표준 라이브러리 re 만 사용)
-- ==============================================================================

-- 💰 비용 최적화 설계 — 이 문서에서 적용하는 것
--   ① 파일은 **MD5 기준으로 한 번만** 파싱한다. 같은 내용이 다른 경로로 다시 올라와도
--      DOC_PARSED 의 결과를 재사용한다 (AI_PARSE_DOCUMENT 는 페이지 수로 과금)
--   ② 청킹은 LLM 이 아니라 **Python UDTF**(웨어하우스 컴퓨트)로 한다. 토큰 비용이 없다
--   ③ 스트림에서 읽은 변경분을 INBOX 테이블에 먼저 옮긴다. 이후 단계가 실패해도 INBOX 가
--      남아 있으므로 **재시도 시 이미 끝난 파싱을 다시 하지 않는다**
--   ④ 파싱 모드: 표·구조가 없는 순수 텍스트 문서가 대부분이라면 'OCR' 모드도 선택지다.
--      모드별 요율은 Snowflake Service Consumption Table 에서 확인하십시오 (이 자료는 측정하지 않음)

USE ROLE DOCRAG_ADMIN_RL;
USE WAREHOUSE DOCRAG_IHCHO_WH;
USE SCHEMA DOCRAG_DB.CURATED;

-- ==============================================================================
-- [1] 테이블
-- ==============================================================================
-- (a) 스트림에서 옮겨 담는 작업 대기열. 처리 완료 후 비운다
CREATE TABLE IF NOT EXISTS DOC_INBOX (
    FILE_PATH  VARCHAR,
    FILE_MD5   VARCHAR,
    ACTION     VARCHAR,            -- INSERT / DELETE
    SEEN_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = '스트림 변경분 대기열. [unstructured-doc-rag-pipeline]';

-- (b) 파싱 결과 — **MD5 가 키**. 같은 내용은 한 번만 저장·과금된다
CREATE TABLE IF NOT EXISTS DOC_PARSED (
    FILE_MD5    VARCHAR,
    FIRST_PATH  VARCHAR,           -- 처음 파싱할 때의 경로 (참고용)
    PAGE_COUNT  INTEGER,
    CONTENT     VARCHAR,
    PARSED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'AI_PARSE_DOCUMENT 결과(MD5 단위). [unstructured-doc-rag-pipeline]';

-- (b-2) 파싱 실패 격리 — 🔴 이 표가 없으면 실패 파일이 **기록 없이 사라집니다** (아래 [3] 설명)
--       MD5 가 여기 있으면 다시 파싱하지 않습니다 → 깨진 파일에 반복 과금되지 않습니다
CREATE TABLE IF NOT EXISTS DOC_PARSE_ERRORS (
    FILE_MD5      VARCHAR,
    FILE_PATH     VARCHAR,
    ERROR_MESSAGE VARCHAR,
    FAILED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = '파싱 실패 파일 격리. [unstructured-doc-rag-pipeline]';

-- (c) 청크 — **경로가 키**. 검색 서비스(07_)의 원천
CREATE TABLE IF NOT EXISTS DOC_CHUNKS (
    FILE_PATH    VARCHAR,
    FILE_MD5     VARCHAR,
    CHUNK_INDEX  INTEGER,
    SECTION      VARCHAR,
    CHUNK_TEXT   VARCHAR,
    CHAR_LEN     INTEGER,
    LOADED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = '검색용 청크. [unstructured-doc-rag-pipeline]';

-- (d) 실행 로그 — "성공 응답" 대신 이 표로 결과를 단정한다
CREATE TABLE IF NOT EXISTS PIPELINE_RUN_LOG (
    RUN_AT          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    STATUS          VARCHAR,       -- OK / OK_WITH_ERRORS / FAILED
    FILES_SEEN      INTEGER,
    FILES_PARSED    INTEGER,       -- 이번에 AI_PARSE_DOCUMENT 를 실제 호출한 파일 수 (과금 대상)
    FILES_REUSED    INTEGER,       -- 파싱 결과를 재사용한 파일 수 (과금 없음)
    FILES_FAILED    INTEGER,       -- 파싱이 error 객체를 돌려준 파일 수 (DOC_PARSE_ERRORS 로 격리)
    CHUNKS_DELETED  INTEGER,
    CHUNKS_INSERTED INTEGER,
    ERROR_MESSAGE   VARCHAR
) COMMENT = '증분 파이프라인 실행 로그. [unstructured-doc-rag-pipeline]';

-- ==============================================================================
-- [2] Snowpark Python UDTF — 섹션 인식 청커
--   왜 내장 SPLIT_TEXT_RECURSIVE_CHARACTER 대신 직접 만드는가
--     · 실제 파싱 출력을 보면(아래 [2-1]) 제목이 '# ' 마크다운 헤더가 아니라
--       "2. 정기 점검 주기" 같은 **번호 줄**로 나온다. 이 줄을 섹션 경계로 쓴다
--     · 🔴 AI_PARSE_DOCUMENT 가 한국어 PDF 에서 **하이픈 뒤에 공백을 끼워 넣는다**
--       (실측: "XR-200" → "XR- 200", "E-17" → "E- 17"). 그대로 두면 모델명·경보코드
--       키워드 검색이 빗나간다. 청커에서 되돌린다
--     · 마크다운 표(| 로 시작하는 줄)는 **쪼개지 않고 한 청크에** 둔다
--     · 각 청크 앞에 "[문서제목 > 섹션]" 을 붙여, 청크만 보고도 출처 맥락을 알게 한다
--       (LLM 으로 요약 헤더를 만드는 방법보다 토큰 비용이 없다)
-- ==============================================================================
-- ⚠️ OR REPLACE: 함수 정의만 교체됩니다 (데이터 없음). IF NOT EXISTS 로 두면 청커를 고친 뒤
--    재실행해도 **옛 정의가 그대로 남아** 수정이 반영되지 않습니다
CREATE OR REPLACE FUNCTION CHUNK_TECH_DOC(CONTENT VARCHAR, MAX_CHARS INTEGER, OVERLAP_CHARS INTEGER)
RETURNS TABLE (CHUNK_INDEX INTEGER, SECTION VARCHAR, CHUNK_TEXT VARCHAR)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'TechDocChunker'
COMMENT = '섹션 인식 기술문서 청커(Snowpark UDTF). [unstructured-doc-rag-pipeline]'
AS
$$
import re

# "2. 정기 점검 주기", "3.1 진단" 같은 번호 제목 또는 마크다운 헤더
_HEADING = re.compile(r'^(#{1,6}\s+.+|\d+(\.\d+)*\.?\s+\S.{0,40})$')
# 영문/숫자 + "- " + 영문/숫자  →  하이픈 뒤 공백 제거 (XR- 200 → XR-200)
_HYPHEN_GAP = re.compile(r'(?<=[A-Za-z0-9])-\s+(?=[A-Za-z0-9])')

class TechDocChunker:
    def process(self, content, max_chars, overlap_chars):
        # NULL 입력은 행을 만들지 않는다 (SQL NULL → Python None)
        if content is None:
            return
        max_chars = max_chars or 800
        overlap_chars = overlap_chars if overlap_chars is not None else 200

        text = _HYPHEN_GAP.sub('-', content)
        # 🔴 제목 줄 앞뒤에 빈 줄이 없는 출력도 있다 (실측: 같은 파서가 문서 A 는 "\n\n1. 개요\n\n",
        #    문서 B 는 "\n\n1. 적용 범위\n본문…" 으로 냈다). 제목 줄을 독립 블록으로 떼어 낸다
        lines = []
        for ln in text.split('\n'):
            if _HEADING.match(ln.strip()) and not ln.strip().startswith('|'):
                lines += ['', ln.strip(), '']
            else:
                lines.append(ln)
        text = '\n'.join(lines)
        blocks = [b.strip() for b in re.split(r'\n\s*\n', text) if b.strip()]
        if not blocks:
            return

        title = blocks[0].lstrip('# ').strip()
        section = title
        buf, idx = [], 0

        # 🔴 본문 없이 한 덩어리뿐인 문서(짧은 메모·표지 1장)도 버리지 않는다
        #    (1차 작성본은 이런 문서에서 청크 0건 → 검색에서 사라졌다. 실측으로 발견)
        if len(blocks) == 1:
            yield (0, title[:60], title)
            return

        def emit(sec, parts):
            body = '\n\n'.join(parts)
            return (idx, sec, f'[{title} > {sec}]\n{body}')

        for b in blocks[1:]:
            if _HEADING.match(b) and '\n' not in b:
                # 섹션이 바뀌면 이전 섹션을 내보내고 버퍼를 비운다 (섹션 간 겹침 없음)
                if buf:
                    yield emit(section, buf); idx += 1
                section, buf = b.lstrip('# ').strip(), []
                continue

            is_table = b.startswith('|')
            size = sum(len(p) for p in buf) + len(b)
            if buf and size > max_chars and not is_table:
                yield emit(section, buf); idx += 1
                last = buf[-1]
                buf = [last] if len(last) <= overlap_chars else []
            buf.append(b)

        if buf:
            yield emit(section, buf)
$$;

-- [2-1] 🔴 단위 테스트 — **실제 파이프라인 입력 형태**로 시험합니다
--   아래 입력은 04_ 에서 올린 PDF 를 LAYOUT 모드로 파싱한 실제 출력 일부입니다.
--   손으로 만든 "깨끗한" 문자열(XR-200)로 시험하면 하이픈 정규화 결함을 놓칩니다.
SELECT c.CHUNK_INDEX, c.SECTION, c.CHUNK_TEXT
FROM TABLE(CHUNK_TECH_DOC(
    'XR- 200 원심 펌프 유지보수 매뉴얼 (가상 문서)\n\n1. 개요\n\nXR- 200 은 냉각수 순환용 원심 펌프이다.\n\n3. 고장 진단\n\n모터 과열 경보(E- 17)가 발생하면 냉각 팬 필터를 청소한다.\n\n|  점검 항목 | 주기 |\n| --- | --- |\n|  진동 | 매주 |',
    800, 200)) c;
--   기대: 2행. SECTION = '1. 개요' / '3. 고장 진단'

-- 입력 형태 B — 제목 뒤 빈 줄 없음 (06_ 에서 올리는 DC-9 문서의 실제 파싱 출력 형태)
SELECT c.CHUNK_INDEX, c.SECTION
FROM TABLE(CHUNK_TECH_DOC(
    'DC- 9 냉각 운영 지침\n\n1. 적용 범위\n이 지침은 DC- 9 에 적용된다.\n\n2. 온도 기준\n급기 온도는 18도에서 27도 사이로 유지한다.',
    800, 200)) c;
--   기대: 2행. SECTION = '1. 적용 범위' / '2. 온도 기준'  (1차 작성본은 1행 — 결함이었다)
--         CHUNK_TEXT 에 'XR-200', 'E-17' (공백 없음), 표가 '3. 고장 진단' 청크 안에 통째로

-- 한 덩어리 문서 → 1행 (본문이 제목 한 줄뿐이어도 청크가 생겨야 합니다)
SELECT COUNT(*) AS SINGLE_BLOCK_ROWS FROM TABLE(CHUNK_TECH_DOC('짧은 메모 한 줄', 800, 200));   -- 1

-- NULL 입력 → 0행
-- ⚠️ 타입 없는 NULL 리터럴은 오버로드 해석에 실패합니다 (실측: Invalid argument types ... (NULL, NUMBER, NUMBER))
--    반드시 ::VARCHAR 로 캐스팅하십시오
SELECT COUNT(*) AS NULL_INPUT_ROWS FROM TABLE(CHUNK_TECH_DOC(NULL::VARCHAR, 800, 200));

-- ==============================================================================
-- [3] 증분 수집 프로시저
--   흐름: 스트림 → INBOX → (삭제분 청크 제거) → 신규 MD5 만 파싱(실패는 격리) → 청킹 → 로그 → INBOX 비움
--   EXECUTE AS OWNER: 06_ 태스크가 호출해도 소유 역할(DOCRAG_ADMIN_RL) 권한으로 동작
--   🔴 절 순서: COMMENT 는 EXECUTE AS 보다 앞에 둡니다 (뒤에 두면 생성이 실패합니다 — EDU-02 실측)
-- ==============================================================================
CREATE OR REPLACE PROCEDURE SP_INGEST_NEW_DOCS()
-- ⚠️ OR REPLACE: 프로시저 정의만 교체됩니다. 데이터 테이블에는 영향이 없습니다
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = '신규 문서 증분 파싱·청킹. [unstructured-doc-rag-pipeline]'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_seen      INTEGER DEFAULT 0;
    v_parsed    INTEGER DEFAULT 0;
    v_reused    INTEGER DEFAULT 0;
    v_deleted   INTEGER DEFAULT 0;
    v_inserted  INTEGER DEFAULT 0;
    v_failed    INTEGER DEFAULT 0;
    v_err       VARCHAR;
BEGIN
    -- (1) 스트림 소비 — DML 로 읽어야 스트림 오프셋이 전진합니다
    INSERT INTO DOCRAG_DB.CURATED.DOC_INBOX (FILE_PATH, FILE_MD5, ACTION)
        SELECT RELATIVE_PATH, MD5, METADATA$ACTION
        FROM DOCRAG_DB.RAW.DOC_STAGE_STREAM;

    SELECT COUNT(DISTINCT FILE_PATH) INTO :v_seen FROM DOCRAG_DB.CURATED.DOC_INBOX;
    IF (v_seen = 0) THEN
        RETURN 'INBOX 비어 있음 — 처리할 파일 없음';
    END IF;

    -- (2) 삭제·덮어쓰기된 경로의 기존 청크 제거 (덮어쓰기 = DELETE + INSERT 로 들어옵니다)
    DELETE FROM DOCRAG_DB.CURATED.DOC_CHUNKS
     WHERE FILE_PATH IN (SELECT FILE_PATH FROM DOCRAG_DB.CURATED.DOC_INBOX);
    v_deleted := SQLROWCOUNT;

    -- (3) 💰 아직 파싱하지 않은 MD5 만 파싱 — 같은 MD5 가 여러 경로면 1회만
    --     🔴 return_error_details=TRUE 이면 깨진 파일은 **예외가 아니라 error 객체**로 돌아옵니다
    --        (실측: 잘린 PDF → {"error": "Invalid PDF file: Failed to open stream", "value": null}).
    --        성공분만 WHERE 로 거르면 실패 파일은 기록 없이 사라지고 INBOX 도 비워집니다.
    --        그래서 결과를 임시 테이블에 먼저 받아 **성공/실패를 나눠 둘 다 기록**합니다.
    CREATE OR REPLACE TEMPORARY TABLE DOCRAG_DB.CURATED.TMP_PARSE_RESULT AS
        WITH todo AS (
            SELECT FILE_MD5, FILE_PATH
            FROM DOCRAG_DB.CURATED.DOC_INBOX
            WHERE ACTION = 'INSERT'
              AND FILE_MD5 NOT IN (SELECT FILE_MD5 FROM DOCRAG_DB.CURATED.DOC_PARSED)
              AND FILE_MD5 NOT IN (SELECT FILE_MD5 FROM DOCRAG_DB.CURATED.DOC_PARSE_ERRORS)
            QUALIFY ROW_NUMBER() OVER (PARTITION BY FILE_MD5 ORDER BY FILE_PATH) = 1
        )
        SELECT FILE_MD5, FILE_PATH,
               AI_PARSE_DOCUMENT(TO_FILE('@DOCRAG_DB.RAW.DOC_STAGE', FILE_PATH),
                                 {'mode': 'LAYOUT'}, TRUE) AS R
        FROM todo;

    INSERT INTO DOCRAG_DB.CURATED.DOC_PARSED (FILE_MD5, FIRST_PATH, PAGE_COUNT, CONTENT)
        SELECT FILE_MD5, FILE_PATH, R:metadata:pageCount::INTEGER, R:value:content::VARCHAR
        FROM DOCRAG_DB.CURATED.TMP_PARSE_RESULT
        WHERE R:value:content IS NOT NULL;
    v_parsed := SQLROWCOUNT;

    INSERT INTO DOCRAG_DB.CURATED.DOC_PARSE_ERRORS (FILE_MD5, FILE_PATH, ERROR_MESSAGE)
        SELECT FILE_MD5, FILE_PATH, COALESCE(R:error::VARCHAR, 'content 가 비어 있음')
        FROM DOCRAG_DB.CURATED.TMP_PARSE_RESULT
        WHERE R:value:content IS NULL;
    v_failed := SQLROWCOUNT;

    -- (4) 청킹 — 현재 스테이지에 존재하는(INSERT) 경로만
    INSERT INTO DOCRAG_DB.CURATED.DOC_CHUNKS (FILE_PATH, FILE_MD5, CHUNK_INDEX, SECTION, CHUNK_TEXT, CHAR_LEN)
        SELECT i.FILE_PATH, i.FILE_MD5, c.CHUNK_INDEX, c.SECTION, c.CHUNK_TEXT, LENGTH(c.CHUNK_TEXT)
        FROM (SELECT DISTINCT FILE_PATH, FILE_MD5
                FROM DOCRAG_DB.CURATED.DOC_INBOX WHERE ACTION = 'INSERT') i
        JOIN DOCRAG_DB.CURATED.DOC_PARSED p ON p.FILE_MD5 = i.FILE_MD5,
             TABLE(DOCRAG_DB.CURATED.CHUNK_TECH_DOC(p.CONTENT, 800, 200)) c;
    v_inserted := SQLROWCOUNT;

    -- 재사용 = 이번에 청크를 만든 경로 중 이번에 새로 파싱하지 않은 것
    SELECT COUNT(DISTINCT i.FILE_PATH) INTO :v_reused
      FROM DOCRAG_DB.CURATED.DOC_INBOX i
      JOIN DOCRAG_DB.CURATED.DOC_PARSED p ON p.FILE_MD5 = i.FILE_MD5
     WHERE i.ACTION = 'INSERT';
    v_reused := v_reused - v_parsed;

    INSERT INTO DOCRAG_DB.CURATED.PIPELINE_RUN_LOG
        (STATUS, FILES_SEEN, FILES_PARSED, FILES_REUSED, FILES_FAILED, CHUNKS_DELETED, CHUNKS_INSERTED)
        VALUES (IFF(:v_failed > 0, 'OK_WITH_ERRORS', 'OK'),
                :v_seen, :v_parsed, :v_reused, :v_failed, :v_deleted, :v_inserted);

    -- (5) 성공했을 때만 INBOX 를 비웁니다. 실패하면 남겨 두어 재시도 대상이 됩니다
    DELETE FROM DOCRAG_DB.CURATED.DOC_INBOX;

    RETURN 'OK seen=' || v_seen || ' parsed=' || v_parsed || ' reused=' || v_reused
        || ' failed=' || v_failed || ' chunks_del=' || v_deleted || ' chunks_ins=' || v_inserted;
EXCEPTION
    WHEN OTHER THEN
        -- 🔴 실패를 삼키지 않습니다: 로그를 남기고 **다시 던져** 태스크가 FAILED 로 기록되게 합니다
        --    변수는 콜론(:)을 붙여 바인드합니다. 빠뜨리면 핸들러 자체가 실패합니다 (EDU-03 실측)
        v_err := SQLERRM;
        INSERT INTO DOCRAG_DB.CURATED.PIPELINE_RUN_LOG (STATUS, FILES_SEEN, ERROR_MESSAGE)
            VALUES ('FAILED', :v_seen, :v_err);
        RAISE;
END;
$$;

-- ==============================================================================
-- [4] 첫 실행 — 04_ 에서 올린 1건을 처리합니다
-- ==============================================================================
CALL SP_INGEST_NEW_DOCS();          -- ← 반환 메시지는 근거가 아닙니다. 아래 쿼리로 단정합니다

SELECT * FROM PIPELINE_RUN_LOG ORDER BY RUN_AT DESC LIMIT 5;    -- STATUS=OK, FILES_PARSED=1
SELECT FILE_MD5, FIRST_PATH, PAGE_COUNT, LENGTH(CONTENT) AS CHARS FROM DOC_PARSED;
SELECT FILE_PATH, CHUNK_INDEX, SECTION, CHAR_LEN, LEFT(CHUNK_TEXT, 80) AS PREVIEW
FROM DOC_CHUNKS ORDER BY FILE_PATH, CHUNK_INDEX;

-- 하이픈 정규화가 실제 적재분에 적용되었는지 (파싱 원문에는 'XR- 200' 이 있습니다)
SELECT COUNT_IF(CONTENT ILIKE '%XR- 200%')   AS RAW_HAS_GAP  FROM DOC_PARSED;   -- 1 (원문)
SELECT COUNT_IF(CHUNK_TEXT ILIKE '%XR- 200%') AS CHUNK_HAS_GAP,                  -- 0
       COUNT_IF(CHUNK_TEXT ILIKE '%XR-200%')  AS CHUNK_FIXED  FROM DOC_CHUNKS;   -- 1 이상

-- [4-1] 멱등성 — 두 번째 호출은 아무것도 하지 않아야 합니다
CALL SP_INGEST_NEW_DOCS();          -- 'INBOX 비어 있음'
SELECT COUNT(*) AS PARSED_ROWS FROM DOC_PARSED;     -- 여전히 1

-- ==============================================================================
-- [5] 🔴 예외 경로 시험 — 핸들러가 실제로 동작하는지 **의도적으로 실패시켜** 확인합니다
--   정상 경로만 돌려서는 EXCEPTION 블록의 결함이 절대 드러나지 않습니다.
--   INBOX 에 존재하지 않는 파일을 넣으면 TO_FILE/AI_PARSE_DOCUMENT 단계가 실패합니다.
-- ==============================================================================
INSERT INTO DOC_INBOX (FILE_PATH, FILE_MD5, ACTION) VALUES ('manuals/NOT_EXISTS.pdf', 'fake-md5', 'INSERT');
CALL SP_INGEST_NEW_DOCS();          -- 오류로 끝나는 것이 정상입니다 (RAISE)
SELECT STATUS, LEFT(ERROR_MESSAGE, 120) AS ERR FROM PIPELINE_RUN_LOG
WHERE STATUS = 'FAILED' ORDER BY RUN_AT DESC LIMIT 1;           -- FAILED 1행
SELECT COUNT(*) AS INBOX_LEFT FROM DOC_INBOX;                   -- 1 (실패 시 INBOX 보존)

-- 시험용 행 제거 — 반드시 실행하십시오. 남겨 두면 06_ 태스크가 계속 실패합니다
DELETE FROM DOC_INBOX WHERE FILE_MD5 = 'fake-md5';

-- ==============================================================================
-- [5-1] 🔴 "조용한 실패" 경로 시험 — 깨진 파일은 예외 없이 error 객체로 돌아옵니다
--   (선택) 로컬에서 PDF 앞부분만 잘라 올립니다:  head -c 400 XR-200_pump_manual.pdf > truncated.pdf
--          snow stage copy ./truncated.pdf @DOCRAG_DB.RAW.DOC_STAGE/probe/ --role DOCRAG_ADMIN_RL
--   그 뒤 1~3분 기다리거나 ALTER STAGE ... REFRESH 후 아래를 실행합니다.
-- ==============================================================================
-- ALTER STAGE DOCRAG_DB.RAW.DOC_STAGE REFRESH;
-- CALL SP_INGEST_NEW_DOCS();
-- SELECT STATUS, FILES_PARSED, FILES_FAILED FROM PIPELINE_RUN_LOG ORDER BY RUN_AT DESC LIMIT 1;  -- OK_WITH_ERRORS, FAILED=1
-- SELECT FILE_PATH, ERROR_MESSAGE FROM DOC_PARSE_ERRORS;          -- Invalid PDF file: Failed to open stream
-- CALL SP_INGEST_NEW_DOCS();   -- 같은 파일을 다시 파싱하지 않습니다 (MD5 격리)
-- 시험 후 정리:
-- REMOVE @DOCRAG_DB.RAW.DOC_STAGE/probe/;
-- ALTER STAGE DOCRAG_DB.RAW.DOC_STAGE REFRESH;   -- 삭제분이 스트림에 DELETE 로 잡힙니다
-- CALL SP_INGEST_NEW_DOCS();                     -- probe 경로 청크(있다면) 제거

-- ==============================================================================
-- [6] 💰 청커를 바꾼 뒤 재청킹 — AI_PARSE_DOCUMENT 를 다시 부르지 않습니다
--   파싱 결과(DOC_PARSED)를 보관해 두었기 때문에 청킹 규칙·크기를 바꿔도
--   웨어하우스 컴퓨트만으로 청크를 다시 만들 수 있습니다. (파싱을 버렸다면 전량 재과금)
--   ⚠️ 07_ 검색 서비스가 이미 있다면 청크 교체분이 다음 갱신 때 재임베딩됩니다(토큰 과금)
-- ==============================================================================
-- 스테이지에 **현재 존재하는** 경로 기준으로 다시 만듭니다
BEGIN TRANSACTION;
DELETE FROM DOC_CHUNKS;
INSERT INTO DOC_CHUNKS (FILE_PATH, FILE_MD5, CHUNK_INDEX, SECTION, CHUNK_TEXT, CHAR_LEN)
    SELECT d.RELATIVE_PATH, d.MD5, c.CHUNK_INDEX, c.SECTION, c.CHUNK_TEXT, LENGTH(c.CHUNK_TEXT)
    FROM DIRECTORY(@DOCRAG_DB.RAW.DOC_STAGE) d
    JOIN DOC_PARSED p ON p.FILE_MD5 = d.MD5,
         TABLE(CHUNK_TECH_DOC(p.CONTENT, 800, 200)) c;
COMMIT;

SELECT FILE_PATH, CHUNK_INDEX, SECTION, CHAR_LEN FROM DOC_CHUNKS ORDER BY FILE_PATH, CHUNK_INDEX;

-- ==============================================================================
-- 🧹 리소스 정리 (이 문서에서 만든 객체만. 정본은 98_)
-- ==============================================================================
-- DROP PROCEDURE IF EXISTS DOCRAG_DB.CURATED.SP_INGEST_NEW_DOCS();
-- DROP FUNCTION  IF EXISTS DOCRAG_DB.CURATED.CHUNK_TECH_DOC(VARCHAR, INTEGER, INTEGER);
-- DROP TABLE IF EXISTS DOCRAG_DB.CURATED.PIPELINE_RUN_LOG;
-- DROP TABLE IF EXISTS DOCRAG_DB.CURATED.DOC_CHUNKS;
-- DROP TABLE IF EXISTS DOCRAG_DB.CURATED.DOC_PARSE_ERRORS;
-- DROP TABLE IF EXISTS DOCRAG_DB.CURATED.DOC_PARSED;
-- DROP TABLE IF EXISTS DOCRAG_DB.CURATED.DOC_INBOX;
