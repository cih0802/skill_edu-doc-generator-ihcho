/*
title: Cortex Search 서비스
step: 08
type: sql
summary: 마스킹된 청크 테이블을 기반으로 하이브리드(벡터 + 키워드) 검색 서비스를 생성하고 SEARCH_PREVIEW로 검색 품질을 확인한다.
requires: 07_Stream_및_ServerlessTask.sql
next: 09_가드동적제어_및_검증.sql
*/

-- ==============================================================================
-- 검증 상태
--
-- [2026-09-17 재검증 — 임베딩 모델 교체 후 실습 완주]
--   계정 LJ20513 / AWS_AP_NORTHEAST_1 / Enterprise
--   ✅ CREATE CORTEX SEARCH SERVICE (EMBEDDING_MODEL=snowflake-arctic-embed-l-v2.0)
--      — 실제 실행 검증 완료
--   ✅ DESCRIBE — 실제 실행. indexing_state=ACTIVE, serving_state=ACTIVE,
--      source_data_num_rows=2, refresh_mode=INCREMENTAL,
--      embedding_model=snowflake-arctic-embed-l-v2.0 확인.
--      vector_indexes 에 {"auto_embedded":true,"column":"CHUNK_TEXT",
--      "model":"snowflake-arctic-embed-l-v2.0"} 가 실제로 기록된 것을 확인
--   ✅ 변경 추적 자동 활성화 — 실증됨. 02_ [6] 소유권 이전으로 권한 오류 없이 생성됨
--   ✅ GRANT USAGE ON CORTEX SEARCH SERVICE — 실제 실행 검증 완료
--   ✅ SEARCH_PREVIEW + FLATTEN — **한국어 질의로 실제 실행 검증 완료.**
--      질의 '사내 보안 규정과 인증 절차를 알려줘' →
--        1순위 KSM_Security_Policy_2026.pdf (MFA·인증 절차 조항)
--        2순위 KSM_Welfare_Guide_2026.pdf
--      의도한 문서가 1순위로 반환됨
--   ✅ DROP CORTEX SEARCH SERVICE — 실제 실행 검증 완료
--
-- ⚠️ 미검증
--   · TARGET_LAG='1 hour' 에 의한 시간 경과 증분 갱신
--     (초기 인덱스 빌드와 즉시 검색만 확인함)
--   · 이전 판의 English-only 모델과 검색 품질을 **정량 비교하지는 않았습니다.**
--     교체 근거는 공식 문서의 언어 지원 표이며, 순위 비교 실험은 하지 않았습니다.
--     문서 2건 규모에서는 유의미한 품질 비교가 불가능합니다
-- ==============================================================================
-- ==============================================================================
-- ⚙️ 설정값
-- ==============================================================================
--   Service        : KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE
--   검색 대상 컬럼  : CHUNK_TEXT
--   ATTRIBUTES     : FILE_NAME, FILE_URL, CHUNK_INDEX
--   Warehouse      : KSM_CHATBOT_WH   (인덱스 빌드/갱신용)
--   TARGET_LAG     : 1 hour           (실습 중 즉시 반영을 보려면 '1 minute')
--   EMBEDDING_MODEL: snowflake-arctic-embed-l-v2.0   ← 🔴 Multilingual. 아래 경고 참고
--   AUTO_SUSPEND   : 3600 초
--
--   예상 소요 시간  : 약 10분 (초기 인덱스 빌드에 수 분 소요)
--   💰 인덱스 빌드·갱신 시 웨어하우스 크레딧과 서빙 스토리지 비용이 발생합니다.
--      TARGET_LAG 을 짧게 잡으면 갱신이 잦아져 비용이 늘어납니다.
--
-- 🔴🔴 임베딩 모델의 언어 지원을 반드시 확인하십시오 🔴🔴
--   이 실습의 문서와 질의는 **전부 한국어**입니다. 임베딩 모델이 한국어를
--   지원하지 않으면 SQL 은 성공하고 인덱스도 ACTIVE 가 되지만
--   **의미 검색 품질이 조용히 나빠집니다.** 오류가 나지 않으므로 알아채기 어렵습니다.
--
--   공식 문서(Vector Embeddings — Text embedding models) 기준 언어 지원:
--     | 모델                          | 차원 | 언어 지원    |
--     |-------------------------------|------|--------------|
--     | snowflake-arctic-embed-m-v1.5 |  768 | English-only |
--     | snowflake-arctic-embed-m      |  768 | English-only |
--     | e5-base-v2                    |  768 | English-only |
--     | snowflake-arctic-embed-l-v2.0 | 1024 | **Multilingual** |
--     | voyage-multilingual-2         | 1024 | **Multilingual** |
--     | nv-embed-qa-4                 | 1024 | English-only |
--
--   이 자료의 이전 판은 `snowflake-arctic-embed-m-v1.5`(English-only)를 쓰고 있었습니다.
--   문서 본문의 검증 질의([4])는 처음부터 한국어였으나, 이전 회차의 **검증 기록에
--   남은 질의는 영어**('multi-factor authentication security policy')였습니다.
--   즉 가르치는 경로(한국어)와 검증한 경로(영어)가 어긋나 있었고,
--   그래서 English-only 모델의 부적합이 드러나지 않았습니다.
--   → `snowflake-arctic-embed-l-v2.0` 으로 교체하고, 재검증은 본문과 같은
--     **한국어 질의로만** 수행했습니다.
--
--   2026-09-17 `SHOW CORTEX BASE MODELS` 실행 결과 이 모델은 GA 이며
--   in_region_availability 에 AWS_AP_NORTHEAST_1 이 포함되어 있어
--   **크로스 리전 설정 없이** 이 리전에서 바로 쓸 수 있습니다.
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA SERVING;


-- ##############################################################################
-- [0] 선행 조건 확인 — 청크가 없으면 검색할 것이 없습니다
-- ##############################################################################
SELECT COUNT(*) AS CHUNK_COUNT FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS;
--   청크 개수: ______ 건  (0 이면 06_ 로 돌아가십시오)


-- ##############################################################################
-- [1] Cortex Search Service 생성
-- ##############################################################################
-- ON              : 의미 검색 대상 텍스트 컬럼
-- ATTRIBUTES      : 결과 필터링·반환에 쓰는 메타데이터 컬럼
-- TARGET_LAG      : 원본 테이블 변경이 인덱스에 반영되는 목표 지연
-- EMBEDDING_MODEL : 벡터 변환 모델 (생략하면 기본 모델)
-- AUTO_SUSPEND    : 유휴 시 서빙 컴퓨트 자동 중지 (비용 절감)
--
-- ⚠️ Cortex Search 는 원본 테이블에 변경 추적(CHANGE_TRACKING)을 요구합니다.
--    서비스 생성자가 테이블 소유자이면 Snowflake 가 자동으로 활성화합니다.
--    권한이 부족하면 오류가 나므로, 02_ [6] 소유권 이전이 완료되었는지 확인하십시오.
--
-- IF NOT EXISTS: 재실행 시 기존 서비스와 이미 빌드된 인덱스를 보존합니다.
--    정의(ON/ATTRIBUTES/쿼리)를 바꿔 재배포해야 하면 CREATE OR REPLACE 를 쓰십시오.
--    ⚠️ OR REPLACE 는 인덱스를 처음부터 다시 빌드하므로 크레딧이 다시 발생합니다.

CREATE CORTEX SEARCH SERVICE IF NOT EXISTS KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE
    ON CHUNK_TEXT
    ATTRIBUTES FILE_NAME, FILE_URL, CHUNK_INDEX
    WAREHOUSE = KSM_CHATBOT_WH
    TARGET_LAG = '1 hour'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
    AUTO_SUSPEND = 3600
    COMMENT = 'KSM HQ 사내 문서 하이브리드 검색 서비스. 실습용. [chatbot-prompt-guard]'
AS (
    SELECT
        CHUNK_ID,
        FILE_NAME,
        FILE_URL,
        CHUNK_INDEX,
        CHUNK_TEXT
    FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS
);


-- ##############################################################################
-- [2] 서비스 상태 확인
-- ##############################################################################
-- 초기 인덱스 빌드가 끝나기 전에는 검색 결과가 비어 있을 수 있습니다.
-- 상태가 ACTIVE 가 될 때까지 기다린 뒤 [4] 를 실행하십시오.

DESCRIBE CORTEX SEARCH SERVICE KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE;
--   서비스 상태: ______________
--   인덱싱된 행 수: ______

SHOW CORTEX SEARCH SERVICES IN SCHEMA KSM_CHATBOT_DB.SERVING;


-- ##############################################################################
-- [3] 사용자 역할에 검색 권한 부여
-- ##############################################################################
GRANT USAGE ON CORTEX SEARCH SERVICE KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE
    TO ROLE KSM_CHATBOT_USER_ROLE;


-- ##############################################################################
-- [4] 검색 테스트
-- ##############################################################################
-- 질의어는 업로드한 문서 내용에 맞게 바꾸십시오.

-- 4.1 기본 의미 검색
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE',
    '{
        "query": "사내 보안 규정과 인증 절차를 알려줘",
        "columns": ["CHUNK_TEXT", "FILE_NAME", "CHUNK_INDEX"],
        "limit": 3
     }'
) AS SEARCH_RESULT;
--   1순위로 반환된 파일명: ______________________
--   질문과 관련 있는 내용이 반환되었는가: ☐ 예  ☐ 아니오

-- 4.2 결과를 표 형태로 펼쳐 보기
SELECT
    r.value:FILE_NAME::VARCHAR    AS FILE_NAME,
    r.value:CHUNK_INDEX::INTEGER  AS CHUNK_INDEX,
    LEFT(r.value:CHUNK_TEXT::VARCHAR, 200) AS CHUNK_PREVIEW
FROM TABLE(FLATTEN(
    input => PARSE_JSON(
        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE',
            '{
                "query": "사내 보안 규정과 인증 절차를 알려줘",
                "columns": ["CHUNK_TEXT", "FILE_NAME", "CHUNK_INDEX"],
                "limit": 5
             }'
        )
    ):results
)) r;

-- 4.3 ATTRIBUTES 기반 필터 검색 — 특정 파일로 범위를 좁힙니다
--     FILE_NAME 값을 실제 업로드한 파일명으로 바꾸십시오.
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE',
    '{
        "query": "보고 절차",
        "columns": ["CHUNK_TEXT", "FILE_NAME"],
        "filter": {"@eq": {"FILE_NAME": "SAMPLE_보안규정.md"}},
        "limit": 3
     }'
) AS FILTERED_RESULT;

-- 4.4 🔴 인덱스에 PII 가 들어가지 않았는지 확인
--     05_ 의 마스킹이 06_ 에서 정상 적용되었다면 원본 PII 가 검색되지 않아야 합니다.
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE',
    '{"query": "주민등록번호 휴대전화번호 이메일 주소", "columns": ["CHUNK_TEXT"], "limit": 5}'
) AS PII_CHECK_RESULT;
--   반환된 청크에 마스킹되지 않은 실제 번호/이메일이 있는가: ☐ 없음  ☐ 있음
--   있으면 06_ [4.3] 점검 쿼리로 원인을 확인하십시오.


-- ##############################################################################
-- 🧹 리소스 정리 — 이 문서까지 진행한 뒤 중단하는 경우
-- ##############################################################################
-- 전체 정리는 98_리소스정리.sql 이 정본입니다.
-- 💰 Cortex Search Service 는 서빙 스토리지와 갱신 컴퓨트 비용이 지속 발생합니다.
--    실습을 오래 중단할 때는 삭제를 권장합니다.
--
-- DROP CORTEX SEARCH SERVICE IF EXISTS KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE;
--
-- 갱신 빈도만 낮춰 비용을 줄이려면 (삭제하지 않음):
-- ALTER CORTEX SEARCH SERVICE KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE
--     SET TARGET_LAG = '7 days';
