/*
title: 문서 파싱 및 청킹 파이프라인
step: 06
type: sql
summary: AI_PARSE_DOCUMENT(LAYOUT)로 문서를 마크다운 추출하고 PII 마스킹 후 SPLIT_TEXT_RECURSIVE_CHARACTER로 청킹해 적재하는 Owner's Rights 증분 프로시저를 구축한다.
requires: 05_보안UDF_및_PII마스킹.sql
next: 07_Stream_및_ServerlessTask.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-16, 실습 완주 — 실제 PDF 로 엔드투엔드 확인):
--   ✅ CREATE TABLE DOCUMENT_CHUNKS — 실제 실행 검증 완료
--   ✅ SP_PROCESS_NEW_DOCUMENTS 생성 및 CALL — 실제 실행. '적재된 청크 개수: 1 건'
--   ✅ AI_PARSE_DOCUMENT(TO_FILE(...), {'mode':'LAYOUT'}):content —
--      **실제 실행 검증 완료.** 실제 PDF 에서 492자 마크다운 추출
--   ✅ PII 마스킹이 인덱스 대상 텍스트에 실제 적용됨 — 실제 실행 검증 완료.
--      청크에 [EMAIL_MASKED] / 010-****-5432 / 950505-******* 존재,
--      원문 이메일·주민번호 문자열은 존재하지 않음(유출 0건)
--   ✅ SPLIT_TEXT_RECURSIVE_CHARACTER 청킹 / CHUNK_TOKEN_ESTIMATE — 실제 실행 검증 완료
--   ✅ 증분 멱등성 — 실제 실행 검증 완료. 재실행 시 '적재된 청크 개수: 0 건'
--
-- 🔴 이번 실행에서 발견해 정정한 결함
--   [결함 A] CREATE PROCEDURE 절 순서 오류 → 프로시저 생성 자체가 실패했다
--     오류: syntax error line 5 at position 0 unexpected 'COMMENT'
--     원인: EXECUTE AS OWNER 뒤에 COMMENT 를 두었다.
--           COMMENT 는 EXECUTE AS 보다 앞에 와야 한다.
--     조치: [2] 에서 순서를 교정했고 교정형을 실제 실행으로 검증했다.
--     ⚠️ 07_ / 09_ 에도 동일 결함이 있어 함께 교정했다.
-- ==============================================================================
-- ==============================================================================
-- ⚙️ 설정값
-- ==============================================================================
--   대상 테이블   : KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
--   프로시저      : KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS()
--   파싱 모드     : LAYOUT (표·제목 구조를 마크다운으로 보존)
--   청크 크기     : 1000 자
--   청크 중첩     : 200 자
--   청킹 포맷     : 'markdown'
--
--   예상 소요 시간: 약 15분 (문서 파싱 시간 별도)
--   💰 AI_PARSE_DOCUMENT 는 처리한 페이지 수에 따라 크레딧이 발생합니다.
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA SILVER;


-- ##############################################################################
-- [1] 청크 저장 테이블
-- ##############################################################################
-- IF NOT EXISTS: 재실행 시 이미 적재한 청크를 보존합니다.
-- 🔴 CREATE OR REPLACE 로 바꾸면 적재된 청크가 전부 사라집니다. 쓰지 마십시오.

CREATE TABLE IF NOT EXISTS KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS (
    CHUNK_ID              VARCHAR       DEFAULT UUID_STRING() PRIMARY KEY,
    FILE_NAME             VARCHAR       NOT NULL,
    FILE_URL              VARCHAR,
    CHUNK_INDEX           INTEGER       NOT NULL,
    CHUNK_TEXT            VARCHAR       NOT NULL,
    CHUNK_TOKEN_ESTIMATE  INTEGER,
    RAW_MD5               VARCHAR,                                  -- 증분 처리 기준
    PROCESSED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'AI_PARSE_DOCUMENT 파싱 + PII 마스킹 + 재귀 청킹 결과 저장소. 실습용. [chatbot-prompt-guard]';


-- ##############################################################################
-- [2] 증분 문서 처리 프로시저 (Owner's Rights)
-- ##############################################################################
-- EXECUTE AS OWNER
--   호출자 권한이 아니라 프로시저 소유자(KSM_CHATBOT_ADMIN_ROLE) 권한으로 실행됩니다.
--   원본 스테이지(BRONZE) 접근 권한을 캡슐화하므로, 사용자 역할에게 BRONZE 권한을
--   주지 않고도 파이프라인을 트리거할 수 있습니다.
--
-- 증분 기준
--   디렉터리 테이블의 (RELATIVE_PATH, MD5) 조합이 DOCUMENT_CHUNKS 에 없는 파일만
--   처리합니다. 파일이 수정되면 MD5 가 바뀌므로 다시 처리됩니다.
--   ⚠️ 수정된 파일의 **이전 청크는 삭제되지 않습니다.** 같은 FILE_NAME 에 서로 다른
--      RAW_MD5 의 청크가 공존합니다. 최신만 검색하려면 08_ 의 서비스 정의를
--      최신 RAW_MD5 로 필터링하도록 바꾸거나, 재처리 전에 해당 파일의 기존 청크를
--      DELETE 하십시오. 실습에서는 관찰이 목적이므로 그대로 둡니다.

CREATE OR REPLACE PROCEDURE KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS()
RETURNS VARCHAR
LANGUAGE SQL
-- 🔴 절 순서 주의: COMMENT 는 EXECUTE AS 보다 앞에 와야 한다.
--    EXECUTE AS OWNER 뒤에 COMMENT 를 두면 "unexpected 'COMMENT'" 문법 오류가 난다.
COMMENT = '신규/변경 문서를 파싱·마스킹·청킹해 DOCUMENT_CHUNKS 에 적재. [chatbot-prompt-guard]'
EXECUTE AS OWNER
AS
$$
DECLARE
    V_PROCESSED_COUNT INTEGER := 0;
BEGIN
    -- 1) 디렉터리 테이블 동기화
    ALTER STAGE KSM_CHATBOT_DB.BRONZE.DOC_STAGE REFRESH;

    -- 2) 신규/변경 파일 → 파싱 → 마스킹 → 청킹 → 적재
    INSERT INTO KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS (
        FILE_NAME, FILE_URL, CHUNK_INDEX, CHUNK_TEXT,
        CHUNK_TOKEN_ESTIMATE, RAW_MD5, PROCESSED_AT
    )
    WITH NEW_FILES AS (
        -- 아직 처리되지 않았거나 MD5 가 바뀐 파일
        SELECT
            d.RELATIVE_PATH AS FILE_NAME,
            BUILD_STAGE_FILE_URL('@KSM_CHATBOT_DB.BRONZE.DOC_STAGE', d.RELATIVE_PATH) AS STAGE_URL,
            d.MD5 AS RAW_MD5
        FROM DIRECTORY(@KSM_CHATBOT_DB.BRONZE.DOC_STAGE) d
        LEFT JOIN (
            SELECT DISTINCT FILE_NAME, RAW_MD5
            FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
        ) existing
          ON  d.RELATIVE_PATH = existing.FILE_NAME
          AND d.MD5           = existing.RAW_MD5
        WHERE existing.FILE_NAME IS NULL
          AND d.SIZE > 0
    ),
    PARSED_DOCS AS (
        -- AI_PARSE_DOCUMENT — 인자는 FILE 객체다. TO_FILE 로 만든다.
        -- mode LAYOUT: 표·제목·단락 구조를 마크다운으로 보존
        -- page_split 을 쓰지 않았으므로 응답 최상위에 content 필드가 온다
        SELECT
            nf.FILE_NAME,
            nf.STAGE_URL,
            nf.RAW_MD5,
            AI_PARSE_DOCUMENT(
                TO_FILE('@KSM_CHATBOT_DB.BRONZE.DOC_STAGE', nf.FILE_NAME),
                {'mode': 'LAYOUT'}
            ):content::VARCHAR AS RAW_CONTENT
        FROM NEW_FILES nf
    ),
    SANITIZED_DOCS AS (
        -- 인덱싱 전에 PII 를 치환한다 (05_ 의 UDF)
        SELECT
            FILE_NAME, STAGE_URL, RAW_MD5,
            KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(RAW_CONTENT) AS SANITIZED_CONTENT
        FROM PARSED_DOCS
        WHERE RAW_CONTENT IS NOT NULL      -- 파싱 실패 시 NULL 이 반환된다
    ),
    CHUNKED_DOCS AS (
        -- 재귀적 문자 분할 — 문단·줄바꿈·문장 경계를 우선해 자른다
        SELECT
            sd.FILE_NAME,
            sd.STAGE_URL,
            sd.RAW_MD5,
            c.INDEX::INTEGER AS CHUNK_INDEX,
            c.VALUE::VARCHAR AS CHUNK_TEXT
        FROM SANITIZED_DOCS sd,
             LATERAL FLATTEN(
                 input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
                     sd.SANITIZED_CONTENT, 'markdown', 1000, 200
                 )
             ) c
    )
    SELECT
        FILE_NAME,
        STAGE_URL,
        CHUNK_INDEX,
        CHUNK_TEXT,
        CEIL(LENGTH(CHUNK_TEXT) / 4)  AS CHUNK_TOKEN_ESTIMATE,   -- 대략 4자 ≈ 1토큰
        RAW_MD5,
        CURRENT_TIMESTAMP()
    FROM CHUNKED_DOCS;

    V_PROCESSED_COUNT := SQLROWCOUNT;
    RETURN '적재된 청크 개수: ' || V_PROCESSED_COUNT || ' 건';
END;
$$;


-- ##############################################################################
-- [3] 수동 실행
-- ##############################################################################
-- 04_ 에서 문서를 업로드했다면 지금 실행하십시오.
-- 💰 AI_PARSE_DOCUMENT 크레딧이 발생합니다.

CALL KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS();
--   반환된 청크 개수: ______ 건

-- 업로드한 문서가 없어 0건이 나왔다면, 08_ 의 검색 서비스를 시험해 볼 수 있도록
-- 아래 샘플 청크를 삽입할 수 있습니다 (선택).
-- ⚠️ 실제 파싱 결과가 아니라 검색 동작 확인용 더미 데이터입니다.
--
-- INSERT INTO KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
--     (FILE_NAME, FILE_URL, CHUNK_INDEX, CHUNK_TEXT, CHUNK_TOKEN_ESTIMATE, RAW_MD5)
-- VALUES
-- ('SAMPLE_보안규정.md', NULL, 1,
--  '# 사내 보안 규정\n1. 모든 임직원은 2단계 인증(MFA)을 필수로 설정해야 합니다.\n' ||
--  '2. 주요 데이터베이스 접속 시 개인 계정 공유는 금지됩니다.\n' ||
--  '3. 비인가 외부 장치에서의 사내 네트워크 접속은 차단됩니다.',
--  60, 'SAMPLE'),
-- ('SAMPLE_보안규정.md', NULL, 2,
--  '# 보안 사고 대응 수칙\n사고 발생 시 즉시 정보보호팀([EMAIL_MASKED]) 또는 ' ||
--  '핫라인(010-****-5678)으로 신고합니다.\n비상 대응 절차는 15분 이내에 가동됩니다.',
--  50, 'SAMPLE');


-- ##############################################################################
-- [4] 적재 결과 검증
-- ##############################################################################

-- 4.1 파일별 청크 집계
SELECT
    FILE_NAME,
    RAW_MD5,
    COUNT(*)            AS TOTAL_CHUNKS,
    MIN(CHUNK_INDEX)    AS MIN_IDX,
    MAX(CHUNK_INDEX)    AS MAX_IDX,
    SUM(CHUNK_TOKEN_ESTIMATE) AS EST_TOKENS,
    MAX(PROCESSED_AT)   AS LAST_PROCESSED
FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
GROUP BY FILE_NAME, RAW_MD5
ORDER BY LAST_PROCESSED DESC;

-- 4.2 청크 내용 및 마스킹 반영 상태 샘플
SELECT CHUNK_ID, FILE_NAME, CHUNK_INDEX, LEFT(CHUNK_TEXT, 300) AS CHUNK_PREVIEW
FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
ORDER BY FILE_NAME, CHUNK_INDEX
LIMIT 5;

-- 4.3 🔴 마스킹 누락 점검 — 결과가 나오면 원본 PII 가 인덱싱될 상태입니다
SELECT CHUNK_ID, FILE_NAME, CHUNK_INDEX
FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
WHERE REGEXP_LIKE(CHUNK_TEXT, '.*[0-9]{6}-[1-8][0-9]{6}.*')          -- 주민번호 원본
   OR REGEXP_LIKE(CHUNK_TEXT, '.*01[016789]-[0-9]{3,4}-[0-9]{4}.*')  -- 전화번호 원본
   OR REGEXP_LIKE(CHUNK_TEXT, '.*[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}.*');
--   결과 행 수: ______ 건  (0 이어야 정상)

-- 4.4 재실행 멱등성 확인 — 다시 호출하면 0건이어야 합니다
CALL KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS();
--   두 번째 호출 결과: ______ 건  (0 이면 증분 로직 정상)


-- ##############################################################################
-- 🧹 리소스 정리 — 이 문서까지 진행한 뒤 중단하는 경우
-- ##############################################################################
-- 전체 정리는 98_리소스정리.sql 이 정본입니다.
-- 이 문서에서 만든 테이블·프로시저는 DB 를 삭제하면 함께 사라집니다.
--
-- DROP PROCEDURE IF EXISTS KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS();
-- DROP TABLE     IF EXISTS KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS;
--
-- 💾 적재한 청크만 비우고 구조는 남기려면:
-- TRUNCATE TABLE KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS;
