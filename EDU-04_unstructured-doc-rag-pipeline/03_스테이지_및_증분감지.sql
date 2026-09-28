/*
title: 문서 스테이지 및 증분 감지
step: 03
type: sql
summary: 서버 측 암호화 + 디렉터리 테이블 AUTO_REFRESH 내부 스테이지를 만들고, 디렉터리 테이블 위에 스트림을 걸어 "새로 들어온 파일만" 감지하는 기반을 만든다.
requires: 02_환경준비_및_비용가드.sql
next: 04_문서업로드_안내.md
*/

-- ==============================================================================
-- 검증 상태 (2026-09-28, 실습 완주)
--   ✅ CREATE STAGE (SNOWFLAKE_SSE, DIRECTORY AUTO_REFRESH) — 실제 실행
--   ✅ CREATE STREAM ON STAGE — 실제 실행. 업로드 후 스트림에 행이 잡히는 것을 확인(04_ 참고)
-- ==============================================================================

-- ==============================================================================
-- ⚙️ 설정값
--   스테이지 : DOCRAG_DB.RAW.DOC_STAGE
--   스트림   : DOCRAG_DB.RAW.DOC_STAGE_STREAM
-- ==============================================================================

USE ROLE DOCRAG_ADMIN_RL;
USE WAREHOUSE DOCRAG_WH;
USE SCHEMA DOCRAG_DB.RAW;

-- ==============================================================================
-- [1] 문서 스테이지
--   · ENCRYPTION = SNOWFLAKE_SSE : AI_PARSE_DOCUMENT 가 내부 스테이지 파일을 읽으려면
--     서버 측 암호화가 필요합니다. (클라이언트 측 암호화 스테이지는 지원되지 않습니다)
--     이 속성은 **생성 후 변경할 수 없습니다.**
--   · DIRECTORY AUTO_REFRESH = TRUE : 업로드하면 디렉터리 테이블이 자동으로 갱신됩니다.
--     💰 자동 갱신 등록은 소량의 서버리스 비용이 발생할 수 있습니다
--        (INFORMATION_SCHEMA.AUTO_REFRESH_REGISTRATION_HISTORY 로 확인)
-- ==============================================================================
CREATE STAGE IF NOT EXISTS DOC_STAGE
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY  = (ENABLE = TRUE AUTO_REFRESH = TRUE)
    COMMENT    = '원본 기술문서(PDF/DOCX/PPTX) 스테이지. [unstructured-doc-rag-pipeline]';

-- ==============================================================================
-- [2] 디렉터리 테이블 스트림 — 증분 처리의 핵심
--   스트림은 "마지막 소비 이후 추가·변경·삭제된 파일" 만 돌려줍니다.
--   💰 이미 파싱한 파일을 다시 파싱하지 않게 하는 첫 번째 장치입니다.
--      (두 번째 장치는 05_ 의 MD5 중복 제거)
-- ==============================================================================
CREATE STREAM IF NOT EXISTS DOC_STAGE_STREAM
    ON STAGE DOC_STAGE
    COMMENT = '신규 문서 감지 스트림. [unstructured-doc-rag-pipeline]';

-- ==============================================================================
-- [3] 확인
-- ==============================================================================
SHOW STAGES  LIKE 'DOC_STAGE'        IN SCHEMA DOCRAG_DB.RAW;   -- directory_enabled = Y
SHOW STREAMS LIKE 'DOC_STAGE_STREAM' IN SCHEMA DOCRAG_DB.RAW;   -- source_type = Stage
SELECT SYSTEM$STREAM_HAS_DATA('DOCRAG_DB.RAW.DOC_STAGE_STREAM') AS HAS_DATA;  -- 아직 FALSE

-- ==============================================================================
-- 🧹 리소스 정리 (이 문서에서 만든 객체만. 정본은 98_)
-- ==============================================================================
-- DROP STREAM IF EXISTS DOCRAG_DB.RAW.DOC_STAGE_STREAM;
-- DROP STAGE  IF EXISTS DOCRAG_DB.RAW.DOC_STAGE;
