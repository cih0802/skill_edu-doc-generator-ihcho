-- ==============================================================================
-- 실습 4단계: 문서 파싱 및 청킹 파이프라인 (4.문서 파싱 및 청킹 파이프라인.sql)
-- 설명: AI_PARSE_DOCUMENT를 통한 비정형 문서 레이아웃 OCR 파싱,
--       PII 마스킹 적용, SPLIT_TEXT_RECURSIVE_CHARACTER를 통한 청킹 및
--       보안 통제를 위한 Owner's Rights 저장 프로시저 구축
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA SILVER;

-- [1] 파싱 및 청킹 결과 저장 테이블 생성 (SILVER 스키마)
CREATE OR REPLACE TABLE KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS (
    CHUNK_ID VARCHAR DEFAULT UUID_STRING() PRIMARY KEY,
    FILE_NAME VARCHAR NOT NULL,
    FILE_URL VARCHAR NOT NULL,
    CHUNK_INDEX INTEGER NOT NULL,
    CHUNK_TEXT VARCHAR NOT NULL,
    CHUNK_TOKEN_ESTIMATE INTEGER,
    RAW_MD5 VARCHAR,
    PROCESSED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'AI_PARSE_DOCUMENT 및 재귀적 문자 청킹, PII 마스킹이 완료된 청크 저장소';

-- [2] Owner's Rights(정의자 권한) 기반 증분 문서 처리 저장 프로시저 생성
-- EXECUTE AS OWNER : 호출자의 권한 대신 프로시저 소유자의 권한으로 실행되어
--                    원본 스테이지 접근 권한을 캡슐화하고 데이터 보안을 강화함
CREATE OR REPLACE PROCEDURE KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    V_PROCESSED_COUNT INTEGER := 0;
BEGIN
    -- 1. 스테이지 디렉터리 테이블 새로고침 (BRONZE)
    ALTER STAGE KSM_CHATBOT_DB.BRONZE.DOC_STAGE REFRESH;

    -- 2. 신규/미처리 파일 대상 AI_PARSE_DOCUMENT 실행 -> PII 마스킹 -> 청킹 분할 및 적재
    INSERT INTO KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS (
        FILE_NAME,
        FILE_URL,
        CHUNK_INDEX,
        CHUNK_TEXT,
        CHUNK_TOKEN_ESTIMATE,
        RAW_MD5,
        PROCESSED_AT
    )
    WITH NEW_FILES AS (
        -- 아직 처리되지 않았거나 MD5 해시가 변경된 파일 조회
        SELECT 
            d.RELATIVE_PATH AS FILE_NAME,
            BUILD_STAGE_FILE_URL('@KSM_CHATBOT_DB.BRONZE.DOC_STAGE', d.RELATIVE_PATH) AS STAGE_URL,
            d.MD5 AS RAW_MD5
        FROM DIRECTORY(@KSM_CHATBOT_DB.BRONZE.DOC_STAGE) d
        LEFT JOIN (
            SELECT DISTINCT FILE_NAME, RAW_MD5 
            FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
        ) existing 
        ON d.RELATIVE_PATH = existing.FILE_NAME AND d.MD5 = existing.RAW_MD5
        WHERE existing.FILE_NAME IS NULL
          AND d.SIZE > 0
    ),
    PARSED_DOCS AS (
        -- AI_PARSE_DOCUMENT를 통해 레이아웃 보존 OCR 및 마크다운 텍스트 추출
        -- mode => 'LAYOUT' : 표, 제목, 단락 구조를 마크다운 형식으로 파싱
        SELECT 
            nf.FILE_NAME,
            nf.STAGE_URL,
            nf.RAW_MD5,
            AI_PARSE_DOCUMENT(
                '@KSM_CHATBOT_DB.BRONZE.DOC_STAGE', 
                nf.FILE_NAME, 
                {'mode': 'LAYOUT'}
            ):content::VARCHAR AS RAW_CONTENT
        FROM NEW_FILES nf
    ),
    SANITIZED_DOCS AS (
        -- PII 마스킹 UDF 적용 (SECURITY.MASK_PII_TEXT)
        SELECT 
            FILE_NAME,
            STAGE_URL,
            RAW_MD5,
            KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(RAW_CONTENT) AS SANITIZED_CONTENT
        FROM PARSED_DOCS
        WHERE RAW_CONTENT IS NOT NULL
    ),
    CHUNKED_DOCS AS (
        -- 재귀적 문자 분할(SPLIT_TEXT_RECURSIVE_CHARACTER)을 통한 의미 단위 청킹
        -- chunk_size: 1000자, overlap: 200자
        SELECT 
            sd.FILE_NAME,
            sd.STAGE_URL,
            sd.RAW_MD5,
            c.INDEX::INTEGER AS CHUNK_INDEX,
            c.VALUE::VARCHAR AS CHUNK_TEXT
        FROM SANITIZED_DOCS sd,
        LATERAL FLATTEN(
            input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
                sd.SANITIZED_CONTENT, 
                'markdown', 
                1000, 
                200
            )
        ) c
    )
    SELECT 
        FILE_NAME,
        STAGE_URL,
        CHUNK_INDEX,
        CHUNK_TEXT,
        LENGTH(CHUNK_TEXT) / 4 AS CHUNK_TOKEN_ESTIMATE,
        RAW_MD5,
        CURRENT_TIMESTAMP()
    FROM CHUNKED_DOCS;

    V_PROCESSED_COUNT := SQLROWCOUNT;
    RETURN '성공적으로 처리 완료된 청크 개수: ' || V_PROCESSED_COUNT || ' 건';
END;
$$;

-- [3] 수동 실행 및 결과 확인 (테스트)
-- CALL KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS();

-- [3.1] (선택) PDF 파일 업로드 전 실습용 샘플 청크 데이터 수동 삽입
INSERT INTO KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS (
    FILE_NAME, FILE_URL, CHUNK_INDEX, CHUNK_TEXT, CHUNK_TOKEN_ESTIMATE, RAW_MD5
) VALUES 
(
    'KSM_Security_Policy_2026.pdf',
    'https://snowflake.stage/ksm/security_2026.pdf',
    1,
    '# KSM 사내 보안 규정 (2026년도)\n1. 모든 임직원은 2단계 인증(MFA)을 필수적으로 설정해야 합니다.\n2. 사내 주요 데이터베이스 접속 시 개인 계정 공유는 엄격히 금지됩니다.\n3. 비인가 외부 장치에서의 사내 네트워크 접속은 차단됩니다.',
    120,
    'a1b2c3d4e5'
),
(
    'KSM_Security_Policy_2026.pdf',
    'https://snowflake.stage/ksm/security_2026.pdf',
    2,
    '# 긴급 보안 사고 대응 수칙\n보안 사고 발생 시 즉시 정보보호팀([EMAIL_MASKED]) 또는 핫라인(010-****-5678)으로 신고해야 합니다.\n비상 대응 절차는 상황 발생 15분 이내에 가동됩니다.',
    100,
    'a1b2c3d4e5'
);

-- [4] 청킹 적재 상태 검증 쿼리
SELECT 
    FILE_NAME, 
    COUNT(*) AS TOTAL_CHUNKS, 
    MIN(CHUNK_INDEX) AS MIN_IDX, 
    MAX(CHUNK_INDEX) AS MAX_IDX,
    MAX(PROCESSED_AT) AS LAST_PROCESSED
FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
GROUP BY FILE_NAME;

-- 개별 청크 내용 및 마스킹 상태 샘플 확인
SELECT CHUNK_ID, FILE_NAME, CHUNK_INDEX, CHUNK_TEXT 
FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
LIMIT 5;
