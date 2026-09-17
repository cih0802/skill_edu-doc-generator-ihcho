-- ==============================================================================
-- 실습 2단계: 문서 스테이지 및 디렉터리 테이블 설정 (2.문서 스테이지 및 디렉터리 테이블 설정.sql)
-- 설명: 비정형 문서(PDF 등)를 안전하게 보관하고 실시간 변경을 추적하기 위한
--       디렉터리 테이블 활성화 내부 스테이지 생성 및 메타데이터 조회
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA BRONZE;

-- [1] 암호화 및 디렉터리 테이블이 활성화된 내부 스테이지 생성
-- DIRECTORY = (ENABLE = TRUE) : 스테이지 내 파일 목록 및 메타데이터를 테이블 형태로 쿼리 가능하게 함
-- ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') : 서버 측 암호화 적용 (보안 준수)
CREATE OR REPLACE STAGE KSM_CHATBOT_DB.BRONZE.DOC_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'KSM 챗봇 검색용 원본 문서(PDF, DOCX 등) 적재 스테이지';

-- [2] 스테이지 디렉터리 테이블 수동 새로고침 (파일 업로드 후 동기화 시 사용)
ALTER STAGE KSM_CHATBOT_DB.BRONZE.DOC_STAGE REFRESH;

-- [3] 디렉터리 테이블 메타데이터 조회 쿼리 확인
-- FILE_NAME, SIZE, LAST_MODIFIED, MD5, FILE_URL 등의 메타데이터 확인
SELECT 
    RELATIVE_PATH AS FILE_NAME,
    SIZE AS FILE_SIZE_BYTES,
    LAST_MODIFIED,
    MD5,
    ETAG,
    FILE_URL,
    BUILD_STAGE_FILE_URL('@KSM_CHATBOT_DB.BRONZE.DOC_STAGE', RELATIVE_PATH) AS STAGE_FILE_URL
FROM DIRECTORY(@KSM_CHATBOT_DB.BRONZE.DOC_STAGE);

-- [4] 실습용 파일 업로드 안내 (Snowsight UI 또는 SnowSQL/CLI)
-- Snowsight UI: Data > Databases > KSM_CHATBOT_DB > BRONZE > Stages > DOC_STAGE > [+ Files] 버튼으로 PDF 업로드
-- 업로드 후 아래 명령어로 파일이 정상 반영되었는지 확인합니다:
-- ALTER STAGE KSM_CHATBOT_DB.BRONZE.DOC_STAGE REFRESH;
-- SELECT * FROM DIRECTORY(@KSM_CHATBOT_DB.BRONZE.DOC_STAGE);
