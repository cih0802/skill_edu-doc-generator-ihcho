-- ==============================================================================
-- 실습 5단계: Stream 및 Serverless Task 파이프라인 (5.Stream 및 Serverless Task 파이프라인.sql)
-- 설명: 스테이지 디렉터리 테이블의 파일 변경(추가/수정)을 Stream으로 실시간 감지하고,
--       Serverless Task를 통해 자동으로 파싱 및 청킹 프로시저를 트리거하는 파이프라인 구축
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA BRONZE;

-- [1] 스테이지 디렉터리 테이블 기반 Stream 생성 (BRONZE 스키마)
-- 스테이지에 새로운 파일이 업로드되거나 변경되면 스트림에 변경 레코드가 기록됨
CREATE OR REPLACE STREAM KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM 
    ON STAGE KSM_CHATBOT_DB.BRONZE.DOC_STAGE
    COMMENT = 'DOC_STAGE 내부 파일의 실시간 생성/변경 사항 감지 스트림';

-- 스트림 상태 및 변경 데이터 확인 쿼리
SELECT * FROM KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM;


-- ==============================================================================
-- [2] Serverless Task 정의 (스케줄링 및 자동화 - OPS 스키마)
-- ==============================================================================
USE SCHEMA OPS;

-- 2.1 디렉터리 테이블 자동 새로고침 및 변경 감지 Task (5분 주기 검사)
-- Serverless Task: WAREHOUSE 지정을 생략하고 USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE를 지정하여 서버리스 컴퓨팅 활용
CREATE OR REPLACE TASK KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    SCHEDULE = 'USING CRON */5 * * * * Asia/Seoul' -- 5분마다 변경 사항 확인
    COMMENT = '스트림에 신규 파일이 감지되었을 때 문서 파싱/청킹 프로시저 자동 실행'
    WHEN SYSTEM$STREAM_HAS_DATA('KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM')
AS
    CALL KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS();


-- ==============================================================================
-- [3] Task 활성화 및 운영 관리
-- ==============================================================================

-- 3.1 Task 활성화 (생성 직후에는 기본적으로 SUSPENDED 상태임)
ALTER TASK KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS RESUME;

-- 3.2 Task 상태 확인
SHOW TASKS IN SCHEMA KSM_CHATBOT_DB.OPS;

-- 3.3 Task 수동 강제 실행 (테스트용)
EXECUTE TASK KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS;

-- 3.4 Task 실행 이력 및 에러 로그 모니터링
SELECT 
    NAME,
    STATE,
    SCHEDULED_TIME,
    COMPLETED_TIME,
    ERROR_CODE,
    ERROR_MESSAGE,
    RETURN_VALUE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'TASK_INGEST_NEW_DOCUMENTS',
    SCHEDULED_TIME_RANGE_START => DATEADD('HOUR', -1, CURRENT_TIMESTAMP())
))
ORDER BY SCHEDULED_TIME DESC;

-- 3.5 실습 종료 또는 일시 중지 시 Task 비활성화
-- ALTER TASK KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS SUSPEND;
