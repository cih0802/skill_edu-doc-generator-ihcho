/*
title: 문서 스테이지 및 디렉터리 테이블
step: 03
type: sql
summary: 서버측 암호화 및 디렉터리 테이블이 활성화된 내부 스테이지를 생성하고 파일 메타데이터 조회 쿼리를 확인한다.
requires: 02_환경초기화_및_RBAC구성.sql
next: 04_문서업로드_안내.md
*/

-- ==============================================================================
-- 검증 상태 (2026-09-16, 실습 완주):
--   ✅ CREATE STAGE (DIRECTORY + SNOWFLAKE_SSE) — 실제 실행 검증 완료
--   ✅ ALTER STAGE ... REFRESH — 실제 실행 검증 완료
--   ✅ DIRECTORY() 조회 — 실제 실행. 업로드 전 0행, 업로드 후 1건과
--      RELATIVE_PATH / SIZE / MD5 / BUILD_STAGE_FILE_URL 정상 반환 확인
-- ==============================================================================
-- ==============================================================================
-- ⚙️ 설정값
-- ==============================================================================
--   Stage            : KSM_CHATBOT_DB.BRONZE.DOC_STAGE
--   암호화           : SNOWFLAKE_SSE (서버측 암호화)
--   디렉터리 테이블  : ENABLE = TRUE
--   COMMENT 태그     : [chatbot-prompt-guard]
--
--   예상 소요 시간   : 약 5분
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA BRONZE;


-- ##############################################################################
-- [1] 디렉터리 테이블이 활성화된 내부 스테이지 생성
-- ##############################################################################
-- DIRECTORY = (ENABLE = TRUE)
--   스테이지 내 파일 목록과 메타데이터(크기, 최종 수정일, MD5)를 테이블처럼 조회
--   할 수 있게 합니다. 07_ 의 Stream 은 이 디렉터리 테이블을 대상으로 동작합니다.
-- ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
--   서버측 암호화. AI_PARSE_DOCUMENT 는 SSE 스테이지의 파일을 읽을 수 있습니다.
-- 💰 업로드한 문서 용량만큼 스토리지 비용이 발생합니다.

CREATE STAGE IF NOT EXISTS KSM_CHATBOT_DB.BRONZE.DOC_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'KSM 챗봇 검색용 원본 문서(PDF, DOCX 등) 적재 스테이지. 실습용. [chatbot-prompt-guard]';

-- 생성 확인
SHOW STAGES LIKE 'DOC_STAGE' IN SCHEMA KSM_CHATBOT_DB.BRONZE;


-- ##############################################################################
-- [2] 디렉터리 테이블 새로고침
-- ##############################################################################
-- 파일을 업로드하거나 삭제한 뒤에는 REFRESH 로 메타데이터를 동기화해야 합니다.
-- Snowsight UI 업로드는 자동 갱신되는 경우가 있으나, 확실하게 하려면 명시적으로 실행합니다.
-- 06_ 의 프로시저도 실행 시작 시 REFRESH 를 수행합니다.

ALTER STAGE KSM_CHATBOT_DB.BRONZE.DOC_STAGE REFRESH;


-- ##############################################################################
-- [3] 디렉터리 테이블 메타데이터 조회
-- ##############################################################################
-- 지금은 파일이 없으므로 0행이 정상입니다.
-- 파일 업로드 절차는 04_문서업로드_안내.md 에 있습니다.

SELECT
    RELATIVE_PATH  AS FILE_NAME,
    SIZE           AS FILE_SIZE_BYTES,
    LAST_MODIFIED,
    MD5,                                  -- 06_ 의 증분 처리 기준값
    ETAG,
    FILE_URL,
    BUILD_STAGE_FILE_URL('@KSM_CHATBOT_DB.BRONZE.DOC_STAGE', RELATIVE_PATH) AS STAGE_FILE_URL
FROM DIRECTORY(@KSM_CHATBOT_DB.BRONZE.DOC_STAGE);
--   조회된 파일 개수: ______ 개  (업로드 전이면 0)


-- ##############################################################################
-- 🧹 리소스 정리 — 이 문서까지 진행한 뒤 중단하는 경우
-- ##############################################################################
-- 전체 정리는 98_리소스정리.sql 이 정본입니다.
-- 이 문서에서 만든 것은 STAGE 하나이며, DB 를 삭제하면 함께 사라집니다.
-- 스테이지만 지우려면 주석을 해제하십시오. 업로드한 파일도 함께 삭제됩니다.
--
-- DROP STAGE IF EXISTS KSM_CHATBOT_DB.BRONZE.DOC_STAGE;
