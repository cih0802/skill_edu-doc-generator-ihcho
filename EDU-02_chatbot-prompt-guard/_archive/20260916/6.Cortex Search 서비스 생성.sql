-- ==============================================================================
-- 실습 6단계: Cortex Search 서비스 생성 (6.Cortex Search 서비스 생성.sql)
-- 설명: 전처리 및 마스킹이 완료된 청크 테이블(DOCUMENT_CHUNKS)을 기반으로
--       의미 기반 벡터 검색 및 하이브리드 키워드 검색 인덱스를 자동 생성하는 Cortex Search Service 구축
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA SERVING;

-- [1] Cortex Search Service 생성 (SERVING 스키마)
-- ON : 검색 대상이 되는 텍스트 컬럼 지정 (CHUNK_TEXT)
-- ATTRIBUTES : 필터링 및 메타데이터 반환용 컬럼 지정 (FILE_NAME, FILE_URL 등)
-- WAREHOUSE : 인덱스 생성 및 지속적 동기화에 사용할 가상 웨어하우스
-- TARGET_LAG : 원본 테이블 변경 후 인덱스 반영 주기 ('1 minute', '1 hour' 등)
-- EMBEDDING_MODEL : 벡터 변환 모델 ('snowflake-arctic-embed-m-v1.5' 등)
CREATE OR REPLACE CORTEX SEARCH SERVICE KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE
    ON CHUNK_TEXT
    ATTRIBUTES FILE_NAME, FILE_URL, CHUNK_INDEX
    WAREHOUSE = KSM_CHATBOT_WH
    TARGET_LAG = '1 hour'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-m-v1.5'
    COMMENT = 'KSM HQ 사내 문서 검색을 위한 Cortex Search 하이브리드 인덱스 서비스'
AS (
    SELECT 
        CHUNK_ID,
        FILE_NAME,
        FILE_URL,
        CHUNK_INDEX,
        CHUNK_TEXT
    FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
);

-- [2] 서비스 상태 및 설정 메타데이터 확인
DESCRIBE CORTEX SEARCH SERVICE KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE;
SHOW CORTEX SEARCH SERVICES IN SCHEMA KSM_CHATBOT_DB.SERVING;

-- [3] 사용자 역할(USER_ROLE)에 Search Service 사용 권한 부여
GRANT USAGE ON CORTEX SEARCH SERVICE KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE 
    TO ROLE KSM_CHATBOT_USER_ROLE;

-- [4] Cortex Search 서비스 검색 테스트 (Snowflake Cortex Search Preview 함수 활용)
-- 질의어 '보안 규정' 또는 '사내 복지' 등으로 의미 검색 테스트 실행
SELECT 
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE',
        '{
            "query": "사내 보안 규정 및 가이드라인에 대해 알려줘",
            "columns": ["CHUNK_TEXT", "FILE_NAME", "CHUNK_INDEX"],
            "limit": 3
        }'
    ) AS SEARCH_RESULT;
