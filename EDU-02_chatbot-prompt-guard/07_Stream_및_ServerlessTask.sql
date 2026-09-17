/*
title: Stream 및 Serverless Task 파이프라인
step: 07
type: sql
summary: 스테이지 디렉터리 테이블 변경을 감지하는 Stream과 이를 소비하며 파싱 프로시저를 트리거하는 Serverless Task를 구성하고 실행 이력을 모니터링한다.
requires: 06_문서파싱_및_청킹파이프라인.sql
next: 08_CortexSearch_서비스.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-16, 실습 완주):
--   ✅ CREATE STREAM ON STAGE — 실제 실행 검증 완료
--   ✅ 스테이지 스트림이 신규 파일을 INSERT 로 감지 — 실제 실행 검증 완료
--      (2번째 PDF 업로드 + REFRESH 후 STREAM_ROWS=1, HAS_DATA=TRUE)
--   ✅ INGEST_EVENT_LOG / SP_RUN_INGEST_CYCLE 생성 — 실제 실행 검증 완료
--   ✅ CREATE TASK (서버리스 + WHEN SYSTEM$STREAM_HAS_DATA) 및 RESUME — 실제 실행 검증 완료
--   ✅ EXECUTE TASK 로 자동 실행 — **실제 실행 검증 완료. STATE=SUCCEEDED.**
--      결과: 이벤트 로그 1행(KSM_Welfare_Guide_2026.pdf:INSERT), 청크 1→2건 증가
--   ✅ 스트림 소비로 재실행이 차단되는 설계 — **실증됨.** 다음 주기 실행이
--      STATE=SKIPPED / 0040003 'Conditional expression for task evaluated to false'
--      로 기록되어 컴퓨트를 쓰지 않았다
--   ✅ RESULT_SCAN(LAST_QUERY_ID()) 로 CALL 반환값 수신 — 실제 실행 검증 완료
--
-- 🔴 정정: CREATE PROCEDURE 절 순서(COMMENT 를 EXECUTE AS 앞으로). 06_ [결함 A] 참고
--
-- ⚠️ TASK_HISTORY 의 RETURN_VALUE 는 NULL 로 나온다. 프로시저 RETURN 값은 자동으로
--    실리지 않으며 SYSTEM$SET_RETURN_VALUE 가 필요하다. [5.4] 에서 비어 있는 것은 정상이다.
-- ⚠️ 5분 CRON 에 의한 자연 발동은 미검증(EXECUTE TASK 로 트리거해 확인함)
-- ==============================================================================
-- ==============================================================================
-- ⚙️ 설정값
-- ==============================================================================
--   Stream        : KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM
--   적재 로그      : KSM_CHATBOT_DB.OPS.INGEST_EVENT_LOG
--   오케스트레이터 : KSM_CHATBOT_DB.OPS.SP_RUN_INGEST_CYCLE()
--   Task          : KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS
--   스케줄        : USING CRON */5 * * * * Asia/Seoul   (5분 주기)
--   서버리스 크기  : XSMALL
--
--   예상 소요 시간 : 약 15분 (Task 동작 관찰에 5~10분 추가)
--   💰 Serverless Task 는 실행될 때마다 크레딧이 발생합니다.
--      실습을 중단할 때는 반드시 SUSPEND 하십시오.
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA BRONZE;


-- ##############################################################################
-- [1] 스테이지 디렉터리 테이블 기반 Stream
-- ##############################################################################
-- 스테이지 스트림은 디렉터리 테이블이 활성화된 스테이지에서만 만들 수 있습니다(03_).
-- ⚠️ 스테이지 스트림은 **삽입(신규 파일)만** 추적합니다. 파일 삭제는 추적하지 않습니다.
--    따라서 파일을 지워도 DOCUMENT_CHUNKS 의 기존 청크는 자동으로 사라지지 않습니다.
-- ⚠️ 스트림에 변경이 반영되려면 디렉터리 테이블이 REFRESH 되어야 합니다.

CREATE STREAM IF NOT EXISTS KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM
    ON STAGE KSM_CHATBOT_DB.BRONZE.DOC_STAGE
    COMMENT = 'DOC_STAGE 신규 파일 감지 스트림. 실습용. [chatbot-prompt-guard]';

-- 현재 스트림에 쌓인 변경 확인 (조회는 오프셋을 전진시키지 않습니다)
SELECT * FROM KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM;
--   감지된 변경 행 수: ______ 건

-- 조건 함수 확인 — Task 의 WHEN 이 평가하는 값입니다
SELECT SYSTEM$STREAM_HAS_DATA('KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM') AS HAS_DATA;
--   결과: ______  (TRUE 면 Task 가 실행 대상으로 판정합니다)


-- ##############################################################################
-- [2] 적재 이벤트 로그 — 스트림을 소비(DML)하는 대상
-- ##############################################################################
USE SCHEMA OPS;

CREATE TABLE IF NOT EXISTS KSM_CHATBOT_DB.OPS.INGEST_EVENT_LOG (
    EVENT_ID        VARCHAR       DEFAULT UUID_STRING(),
    RELATIVE_PATH   VARCHAR,
    FILE_SIZE       NUMBER,
    FILE_LAST_MODIFIED VARCHAR,
    STREAM_ACTION   VARCHAR,                                  -- METADATA$ACTION
    DETECTED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'STAGE_DOC_STREAM 소비 기록. 스트림 오프셋 전진의 근거. 실습용. [chatbot-prompt-guard]';


-- ##############################################################################
-- [3] 오케스트레이션 프로시저 — 스트림 소비 후 파싱 실행
-- ##############################################################################
-- Task 본문은 단일 문장만 가질 수 있으므로 두 동작을 프로시저로 묶습니다.
--   1) 스트림을 INSERT 로 소비 → 오프셋 전진 → WHEN 조건이 FALSE 로 내려간다
--   2) 06_ 의 파싱·청킹 프로시저 호출
-- 순서가 중요합니다. 소비를 먼저 하면 다음 주기에 불필요한 재실행이 없습니다.

CREATE OR REPLACE PROCEDURE KSM_CHATBOT_DB.OPS.SP_RUN_INGEST_CYCLE()
RETURNS VARCHAR
LANGUAGE SQL
-- 🔴 절 순서 주의: COMMENT 는 EXECUTE AS 보다 앞에 와야 한다.
COMMENT = '스트림 소비 + 문서 파싱 파이프라인 1회 실행. [chatbot-prompt-guard]'
EXECUTE AS OWNER
AS
$$
DECLARE
    V_EVENTS  INTEGER := 0;
    V_RESULT  VARCHAR;
BEGIN
    -- 1) 스트림 소비 — DML 이므로 오프셋이 전진한다
    INSERT INTO KSM_CHATBOT_DB.OPS.INGEST_EVENT_LOG
        (RELATIVE_PATH, FILE_SIZE, FILE_LAST_MODIFIED, STREAM_ACTION)
    SELECT
        RELATIVE_PATH,
        SIZE,
        TO_VARCHAR(LAST_MODIFIED),
        METADATA$ACTION
    FROM KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM;

    V_EVENTS := SQLROWCOUNT;

    -- 2) 파싱·마스킹·청킹 파이프라인 실행
    CALL KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS();
    V_RESULT := (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

    RETURN '스트림 소비 ' || V_EVENTS || ' 건 / ' || V_RESULT;
END;
$$;


-- ##############################################################################
-- [4] Serverless Task
-- ##############################################################################
-- WAREHOUSE 를 지정하지 않고 USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE 를 주면
-- Snowflake 관리형 서버리스 컴퓨트로 실행됩니다.
-- WHEN 조건이 FALSE 면 실행이 SKIPPED 로 기록되고 컴퓨트를 쓰지 않습니다.

CREATE TASK IF NOT EXISTS KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    SCHEDULE = 'USING CRON */5 * * * * Asia/Seoul'
    COMMENT = '신규 문서 감지 시 파싱/청킹 파이프라인 자동 실행. 실습용. [chatbot-prompt-guard]'
    WHEN SYSTEM$STREAM_HAS_DATA('KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM')
AS
    CALL KSM_CHATBOT_DB.OPS.SP_RUN_INGEST_CYCLE();


-- ##############################################################################
-- [5] Task 활성화 및 운영
-- ##############################################################################
-- 💰 여기서 RESUME 하면 5분마다 조건을 평가합니다. 실습을 마치면 SUSPEND 하십시오.

-- 5.1 활성화 (생성 직후 상태는 suspended 입니다)
ALTER TASK KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS RESUME;

-- 5.2 상태 확인
SHOW TASKS IN SCHEMA KSM_CHATBOT_DB.OPS;

SELECT "name", "state", "schedule", "condition"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--   state 가 started 이어야 정상

-- 5.3 즉시 1회 실행 (스케줄을 기다리지 않고 테스트)
--     ⚠️ EXECUTE TASK 는 스케줄과 무관하게 1회 실행을 트리거합니다.
--        WHEN 조건은 실행 시점에 평가되며, FALSE 면 결과가 SKIPPED 로 기록됩니다.
--        조건과 무관하게 파이프라인만 시험하려면 프로시저를 직접 호출하십시오:
--          CALL KSM_CHATBOT_DB.OPS.SP_RUN_INGEST_CYCLE();
EXECUTE TASK KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS;

-- 5.4 실행 이력 및 오류 확인
SELECT
    NAME,
    STATE,                 -- SUCCEEDED / FAILED / SKIPPED
    SCHEDULED_TIME,
    COMPLETED_TIME,
    ERROR_CODE,
    ERROR_MESSAGE,
    RETURN_VALUE
FROM TABLE(KSM_CHATBOT_DB.INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'TASK_INGEST_NEW_DOCUMENTS',
    SCHEDULED_TIME_RANGE_START => DATEADD('HOUR', -1, CURRENT_TIMESTAMP())
))
ORDER BY SCHEDULED_TIME DESC;
--   가장 최근 STATE: ______________

-- 5.5 스트림 소비가 실제로 일어났는지 확인 — 구 설계의 무한 재실행 결함 회귀 방지
SELECT COUNT(*) AS LOGGED_EVENTS FROM KSM_CHATBOT_DB.OPS.INGEST_EVENT_LOG;
SELECT SYSTEM$STREAM_HAS_DATA('KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM') AS HAS_DATA_AFTER_RUN;
--   실행 후 HAS_DATA 가 FALSE 여야 정상입니다.
--   TRUE 로 남아 있으면 스트림이 소비되지 않은 것이며 Task 가 계속 재실행됩니다.


-- ##############################################################################
-- [6] 증상별 트러블슈팅
-- ##############################################################################
-- | 증상                          | 원인                              | 조치                                |
-- |-------------------------------|-----------------------------------|-------------------------------------|
-- | STATE 가 계속 SKIPPED         | 스트림에 변경이 없음              | 파일 업로드 후 스테이지 REFRESH     |
-- | 매 주기 실행되나 청크 0건     | 스트림은 소비되나 신규 파일 없음  | 정상 동작                           |
-- | 무한 재실행 + HAS_DATA TRUE   | 스트림 소비 누락                  | SP_RUN_INGEST_CYCLE 사용 여부 확인  |
-- | 권한 오류로 FAILED            | EXECUTE MANAGED TASK 권한 없음    | 02_ [7.3] 재실행                    |
-- | AI_PARSE_DOCUMENT 오류        | 리전 미지원 또는 파일 형식        | 02_ [0.1] 리전 확인, PDF로 재시도   |


-- ##############################################################################
-- 🧹 리소스 정리 — 이 문서까지 진행한 뒤 중단하는 경우
-- ##############################################################################
-- 전체 정리는 98_리소스정리.sql 이 정본입니다.
--
-- 💰 비용만 멈추려면 (삭제하지 않고 실습을 이어서 할 수 있습니다):
-- ALTER TASK KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS SUSPEND;
--
-- 이 문서에서 만든 것을 지우려면 주석을 해제하십시오. Task 는 SUSPEND 후 DROP 합니다.
-- ALTER TASK IF EXISTS KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS SUSPEND;
-- DROP TASK      IF EXISTS KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS;
-- DROP PROCEDURE IF EXISTS KSM_CHATBOT_DB.OPS.SP_RUN_INGEST_CYCLE();
-- DROP TABLE     IF EXISTS KSM_CHATBOT_DB.OPS.INGEST_EVENT_LOG;
-- DROP STREAM    IF EXISTS KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM;
