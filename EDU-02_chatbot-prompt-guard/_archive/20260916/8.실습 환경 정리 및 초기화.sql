-- ==============================================================================
-- 실습 8단계: 리소스 정리 및 초기화 (8.실습 환경 정리 및 초기화.sql)
-- 설명: 1~7단계 실습 과정에서 생성된 Task 일시 중지 및 삭제, Cortex Search Service,
--       Database, Warehouse, Role 등 모든 리소스를 안전하게 정리/초기화합니다.
-- ==============================================================================

-- [1] 계정 관리자 권한으로 전환
USE ROLE ACCOUNTADMIN;


-- ==============================================================================
-- [2] 실행 중인 Task 중지 및 삭제 (비용 발생 방지)
-- ==============================================================================
-- Task가 실행 중인 상태에서 데이터베이스를 삭제하기 전에 먼저 일시 중지(SUSPEND)합니다.
ALTER TASK IF EXISTS KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS SUSPEND;
DROP TASK IF EXISTS KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS;


-- ==============================================================================
-- [3] Cortex Search Service 삭제
-- ==============================================================================
DROP CORTEX SEARCH SERVICE IF EXISTS KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE;


-- ==============================================================================
-- [4] 실습용 데이터베이스 삭제 (소속된 테이블, 스테이지, 스트림, UDF/프로시저 일괄 정리)
-- ==============================================================================
-- 다음 6대 스키마 및 하위 오브젝트들이 함께 정리됩니다:
-- - BRONZE: STAGE(@DOC_STAGE), STREAM(STAGE_DOC_STREAM)
-- - SILVER: TABLE(DOCUMENT_CHUNKS), PROCEDURE(SP_PROCESS_NEW_DOCUMENTS)
-- - GOLD: 비즈니스 요약 데이터
-- - SERVING: PROCEDURE(SP_EXECUTE_GUARDED_CHAT)
-- - OPS: Serverless Task 실행 이력
-- - SECURITY: TABLE(PROMPT_GUARD_CONFIG), FUNCTION(MASK_PII_TEXT, CALCULATE_STAGE_FILE_HASH)
DROP DATABASE IF EXISTS KSM_CHATBOT_DB;


-- ==============================================================================
-- [5] 실습용 가상 웨어하우스 삭제
-- ==============================================================================
DROP WAREHOUSE IF EXISTS KSM_CHATBOT_WH;


-- ==============================================================================
-- [6] 실습용 RBAC Role 삭제
-- ==============================================================================
DROP ROLE IF EXISTS KSM_CHATBOT_USER_ROLE;
DROP ROLE IF EXISTS KSM_CHATBOT_ADMIN_ROLE;


-- ==============================================================================
-- [7] 세션 변수 정리 (선택 사항)
-- ==============================================================================
UNSET (CURRENT_USER_NAME, STRICT_GUARD_PROMPT);


-- ==============================================================================
-- [8] 삭제 완료 검증 (Verification)
-- ==============================================================================
SHOW DATABASES LIKE 'KSM_CHATBOT_DB';
SHOW WAREHOUSES LIKE 'KSM_CHATBOT_WH';
SHOW ROLES LIKE 'KSM_CHATBOT%';
