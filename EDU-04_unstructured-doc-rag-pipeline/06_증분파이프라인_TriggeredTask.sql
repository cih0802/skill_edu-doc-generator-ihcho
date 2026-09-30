/*
title: 증분 파이프라인 (Triggered Task)
step: 06
type: sql
summary: 스케줄 없이 스트림에 데이터가 들어올 때만 도는 Triggered Task 로 SP_INGEST_NEW_DOCS 를 자동 실행하고, 신규 문서 적재·중복 사본 파싱 재사용을 결과 테이블로 확인한다.
requires: 05_파싱_및_Snowpark청킹.sql
next: 07_CortexSearch_서비스.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-28, 실습 완주)
--   ✅ CREATE TASK ... WHEN SYSTEM$STREAM_HAS_DATA (SCHEDULE 없음) — 실제 실행
--   ✅ 업로드 → AUTO_REFRESH → 태스크 **자동 발동** 을 TASK_HISTORY 와 PIPELINE_RUN_LOG 로 확인
--   ✅ 같은 내용 파일을 다른 경로에 올렸을 때 FILES_REUSED=1 / DOC_PARSED 행 수 불변 확인
--   ⚠️ 장시간 무이벤트 상태의 비용 0 — 공식 문서 서술("이벤트 전에는 컴퓨트를 쓰지 않는다")에 근거. 측정하지 않음
-- ==============================================================================

-- ==============================================================================
-- ⚙️ 설정값
--   태스크 : DOCRAG_DB.CURATED.TSK_INGEST_DOCS
--   실행   : DOCRAG_IHCHO_WH (사용자 관리 웨어하우스 — 02_ 리소스 모니터의 통제 범위 안)
-- ==============================================================================

-- 💰 비용 최적화 설계 — 왜 Triggered Task 인가
--   | 방식                         | 유휴 시                            |
--   |------------------------------|------------------------------------|
--   | SCHEDULE='5 MINUTE' + WHEN   | 5분마다 WHEN 조건을 평가           |
--   | **Triggered (WHEN 만)**      | 공식 문서: 이벤트 전까지 컴퓨트 미사용 |
--   · 서버리스(TARGET_COMPLETION_INTERVAL) 대신 **웨어하우스**를 지정한 이유:
--     리소스 모니터(02_)는 웨어하우스 크레딧만 통제합니다. 이 WH 로 돌려야 상한이 걸립니다.
--     서버리스로 바꾸면 모니터 밖에서 과금됩니다 (선택은 운영 정책에 따릅니다)
--   · 공식 문서: Triggered Task 는 기본 **최대 30초에 1회** 실행됩니다. 여러 파일이 몰려도
--     한 번의 실행에서 묶여 처리되므로 파일마다 웨어하우스가 깨어나지 않습니다

USE ROLE DOCRAG_ADMIN_RL;
USE WAREHOUSE DOCRAG_IHCHO_WH;
USE SCHEMA DOCRAG_DB.CURATED;

-- ==============================================================================
-- [1] Triggered Task — SCHEDULE 을 넣지 않습니다
-- ==============================================================================
CREATE TASK IF NOT EXISTS TSK_INGEST_DOCS
    WAREHOUSE = DOCRAG_IHCHO_WH
    COMMENT   = '신규 문서 감지 시 증분 파싱·청킹. [unstructured-doc-rag-pipeline]'
    WHEN SYSTEM$STREAM_HAS_DATA('DOCRAG_DB.RAW.DOC_STAGE_STREAM')
AS
    CALL DOCRAG_DB.CURATED.SP_INGEST_NEW_DOCS();

-- 태스크는 SUSPENDED 로 생성됩니다. RESUME 해야 동작합니다
ALTER TASK TSK_INGEST_DOCS RESUME;

SHOW TASKS LIKE 'TSK_INGEST_DOCS' IN SCHEMA DOCRAG_DB.CURATED;   -- state = started, schedule = NULL

-- ==============================================================================
-- [2] (로컬) 두 번째 문서 + 중복 사본 업로드 — 04_ 와 같은 방법
--   snow stage copy ./DC-9_cooling_guide.pdf @DOCRAG_DB.RAW.DOC_STAGE/guides/  --role DOCRAG_ADMIN_RL
--   snow stage copy ./XR-200_pump_manual.pdf @DOCRAG_DB.RAW.DOC_STAGE/archive/ --role DOCRAG_ADMIN_RL
--     ↑ 이미 처리한 매뉴얼과 **같은 파일**을 다른 폴더에 올립니다. 파싱이 다시 일어나면 안 됩니다
--
--   이후 아무것도 하지 않고 기다립니다. AUTO_REFRESH(1~3분) → 스트림 → 태스크 자동 실행.
--   급하면 ALTER STAGE DOCRAG_DB.RAW.DOC_STAGE REFRESH; 를 실행하십시오.
-- ==============================================================================

-- ==============================================================================
-- [3] 자동 실행 확인 — "태스크가 성공했다" 가 아니라 **결과 테이블**로 단정합니다
-- ==============================================================================
-- (a) 태스크 이력 — 자동 실행이 있었는지
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
FROM TABLE(DOCRAG_DB.INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'TSK_INGEST_DOCS'))
ORDER BY SCHEDULED_TIME DESC LIMIT 5;
--   ⚠️ STATE=SUCCEEDED 만으로는 부족합니다. (b)~(d) 를 반드시 확인하십시오

-- (b) 실행 로그 — 이번 실행에서 무엇을 했는지
SELECT RUN_AT, STATUS, FILES_SEEN, FILES_PARSED, FILES_REUSED, FILES_FAILED, CHUNKS_INSERTED
FROM PIPELINE_RUN_LOG ORDER BY RUN_AT DESC LIMIT 3;
--   기대: FILES_SEEN=2, FILES_PARSED=1 (DC-9), FILES_REUSED=1 (archive/XR-200 사본)

-- (c) 💰 파싱 결과는 MD5 단위 — 사본은 새 행을 만들지 않습니다
SELECT FILE_MD5, FIRST_PATH, PAGE_COUNT FROM DOC_PARSED ORDER BY PARSED_AT;

-- (d) 청크는 경로 단위 — 사본 경로에도 청크가 있어야 검색됩니다
SELECT FILE_PATH, COUNT(*) AS CHUNKS FROM DOC_CHUNKS GROUP BY FILE_PATH ORDER BY FILE_PATH;
--   기대: archive/XR-200… 3 / guides/DC-9… N / manuals/XR-200… 3

-- ==============================================================================
-- [4] 트러블슈팅
--   | 증상                                    | 확인                                                |
--   |-----------------------------------------|-----------------------------------------------------|
--   | TASK_HISTORY 가 비어 있다               | DIRECTORY() 에 파일이 보이는가 (AUTO_REFRESH 지연)  |
--   | STATE=FAILED                            | ERROR_MESSAGE + PIPELINE_RUN_LOG STATUS='FAILED'    |
--   | 태스크는 도는데 청크가 안 늘어난다      | DOC_PARSE_ERRORS (깨진 파일 격리)                   |
--   | 실패 후 INBOX 에 행이 남아 있다         | 원인 해결 후 CALL SP_INGEST_NEW_DOCS(); 수동 실행   |
--     ↑ 태스크는 **스트림**에 새 데이터가 올 때만 깨어납니다. INBOX 잔여분만으로는 다시 돌지 않습니다
-- ==============================================================================

-- ==============================================================================
-- 🧹 리소스 정리 (이 문서에서 만든 객체만. 정본은 98_)
--   일시 중단만 하려면: ALTER TASK DOCRAG_DB.CURATED.TSK_INGEST_DOCS SUSPEND;
-- ==============================================================================
-- ALTER TASK IF EXISTS DOCRAG_DB.CURATED.TSK_INGEST_DOCS SUSPEND;
-- DROP  TASK IF EXISTS DOCRAG_DB.CURATED.TSK_INGEST_DOCS;
