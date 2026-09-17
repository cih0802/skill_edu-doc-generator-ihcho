/*
title: 리소스 정리 (Teardown)
step: 98
type: sql
summary: 실습에서 만든 모든 객체를 역순으로 삭제하고 변경한 계정 파라미터를 원복한 뒤 사전 스냅샷과 대조해 왕복 가능성을 증명한다.
requires: 10_계정레벨_AIGuardrails_및_감사.sql
next: 96_실습후_대조.md
*/

-- ==============================================================================
-- 검증 상태 (2026-09-16, 실습 완주 후 **실제 정리 실행**):
--   ✅ ALTER TASK SUSPEND → DROP CORTEX SEARCH SERVICE → DROP TASK — 실제 실행 검증 완료
--   ✅ DROP DATABASE / WAREHOUSE / ROLE (역순) — 실제 실행 검증 완료
--   ✅ [7.1] ALTER ACCOUNT UNSET AI_SETTINGS — 실제 실행 검증 완료.
--      실습 전 미설정이었으므로 UNSET 분기가 적용되어 level 이 (없음) 으로 복귀
--   ✅ [7.2] CORTEX_ENABLED_CROSS_REGION — 변경하지 않았으므로 원복 불필요(분기 정확)
--   ✅ 정리 완료 검증 쿼리 전체 — 실제 실행 검증 완료.
--      역할 7(실습 0) / DB 5(실습 0) / Cortex Search Service 0 /
--      COMMENT 태그 '[chatbot-prompt-guard]' 잔여물 0
--   ✅ 사전 스냅샷과 대조 — **차이 없음. 왕복 가능성 실증됨**
--
-- ⚠️ 이 문서를 실행할 때 세션 웨어하우스가 실습 웨어하우스이면 DROP 이후
--    "No active warehouse selected" 오류가 난다. USE WAREHOUSE <다른 WH> 로 먼저 전환하십시오.
--    (이번 검증에서 실제로 겪은 오류입니다)
-- ==============================================================================
-- ##############################################################################
-- 💰💰💰 [1] 비용 경고 — 지금 당장 확인할 것 💰💰💰
-- ##############################################################################
-- 아래 객체는 **삭제하지 않으면 계속 비용이 발생합니다.** 급한 것부터 나열했습니다.
--
-- | 순위 | 객체                                          | 비용 성격                     |
-- |------|-----------------------------------------------|-------------------------------|
-- | 1    | OPS.TASK_INGEST_NEW_DOCUMENTS (Serverless)    | 5분마다 조건 평가 → 서버리스 크레딧 |
-- | 2    | SERVING.KSM_HQ_SEARCH_SERVICE                 | 서빙 스토리지 + 인덱스 갱신 컴퓨트 |
-- | 3    | KSM_CHATBOT_WH                                | 쿼리 실행 시 컴퓨트 크레딧     |
-- | 4    | BRONZE.DOC_STAGE 의 업로드 파일               | 스토리지                       |
-- | 5    | SILVER.DOCUMENT_CHUNKS                        | 스토리지                       |
--
-- 🔴 비용과 별개로 **계정 파라미터 변경**이 남아 있습니다. DROP 으로 사라지지 않습니다.
--    반드시 [7] 원복 절을 수행하십시오.
--
-- ⚠️ 이 문서의 DROP / ALTER 문은 모두 **주석 처리되어 있습니다.**
--    실행하려면 해당 블록의 주석을 해제하십시오. 실수로 전체 실행되는 것을 막는 장치입니다.


-- ==============================================================================
-- ⚙️ 설정값
-- ==============================================================================
--   접두사       : KSM_CHATBOT_
--   COMMENT 태그 : [chatbot-prompt-guard]
--
--   예상 소요 시간: 약 10분
-- ==============================================================================


-- ##############################################################################
-- [2] 선택 — 일시 중단 vs 완전 삭제
-- ##############################################################################
-- 실습을 이어서 할 예정이면 삭제하지 말고 **일시 중단**만 하십시오.
-- 객체와 데이터는 남고 지속 컴퓨트 비용만 멈춥니다.

-- ── 옵션 A: 일시 중단 (실습 계속 예정) ──────────────────────────────────────
-- USE ROLE KSM_CHATBOT_ADMIN_ROLE;
-- ALTER TASK IF EXISTS KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS SUSPEND;
-- ALTER WAREHOUSE IF EXISTS KSM_CHATBOT_WH SUSPEND;
-- ALTER CORTEX SEARCH SERVICE KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE
--     SET TARGET_LAG = '7 days';   -- 갱신 빈도를 낮춤
--
-- ⚠️ 일시 중단으로도 남는 비용과 부작용:
--    · Search Service 의 서빙 스토리지 비용은 계속 발생합니다
--    · DOC_STAGE 파일과 DOCUMENT_CHUNKS 의 스토리지 비용은 계속 발생합니다
--    · 🔴 [7] 의 **계정 파라미터 변경은 그대로 남습니다.** 계정 전체에 영향을
--      주므로, 실습을 며칠 이상 중단한다면 [7] 원복만이라도 수행하십시오

-- ── 옵션 B: 완전 삭제 ───────────────────────────────────────────────────────
--   [3] 부터 [8] 까지 순서대로 진행하십시오.


-- ##############################################################################
-- [3] 데이터 보존 선택 — 삭제 전에 결정하십시오
-- ##############################################################################
-- 실습 결과를 남기고 싶다면 삭제 전에 내보내십시오. 아래는 조회 전용입니다.

-- 3.1 청크 데이터 확인 (필요하면 결과를 CSV 로 내려받으십시오)
-- SELECT * FROM KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS ORDER BY FILE_NAME, CHUNK_INDEX;

-- 3.2 적재 이벤트 로그
-- SELECT * FROM KSM_CHATBOT_DB.OPS.INGEST_EVENT_LOG ORDER BY DETECTED_AT DESC;

-- 3.3 보존 시 비용
--   · 테이블만 남기고 DB 를 유지하면 스토리지 비용이 계속 발생합니다
--   · 청크 텍스트에는 마스킹된 문서 내용이 들어 있습니다. 보존 정책을 확인하십시오
--   · 보존하려면 [5] 의 DROP DATABASE 를 실행하지 말고, 개별 객체만 삭제하십시오
--
--   보존 결정: ☐ 전부 삭제   ☐ DOCUMENT_CHUNKS 보존   ☐ 기타: __________


-- ##############################################################################
-- [4] 삭제 대상 확인 — DROP 전에 무엇이 지워질지 봅니다
-- ##############################################################################
-- 광범위 삭제(DROP DATABASE) 앞에 반드시 실행하십시오.

USE ROLE ACCOUNTADMIN;

-- 4.1 접두사로 식별되는 계정 레벨 객체
SHOW DATABASES  LIKE 'KSM_CHATBOT%';
SHOW WAREHOUSES LIKE 'KSM_CHATBOT%';
SHOW ROLES      LIKE 'KSM_CHATBOT%';

-- 4.2 COMMENT 태그로 잔여물 광역 검색 (접두사를 놓친 객체 탐지)
SHOW WAREHOUSES;
SELECT "name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[chatbot-prompt-guard]%';

SHOW DATABASES;
SELECT "name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[chatbot-prompt-guard]%';

SHOW ROLES;
SELECT "name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[chatbot-prompt-guard]%';

-- 4.3 Task 와 Search Service
SHOW TASKS IN ACCOUNT;
SELECT "database_name", "schema_name", "name", "state"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" ILIKE 'TASK_INGEST_NEW_DOCUMENTS';

SHOW CORTEX SEARCH SERVICES IN ACCOUNT;

--   삭제 대상이 실습에서 만든 것뿐인지 확인: ☐ 확인
--   🔴 실습이 만들지 않은 객체가 목록에 있으면 진행을 중단하십시오.


-- ##############################################################################
-- [5] 역순 삭제 — ① 실행 중인 것 → ⑥ Role
-- ##############################################################################
-- 순서를 지키지 않으면 의존성 때문에 실패합니다.
-- 실행하려면 아래 블록의 주석을 해제하십시오.

-- ── ① 실행 중인 것 정지 ─────────────────────────────────────────────────────
-- Task 는 실행 중 상태에서 DROP 하면 진행 중인 실행이 남을 수 있으므로 먼저 SUSPEND 합니다.
-- ALTER TASK IF EXISTS KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS SUSPEND;
--
--   ⚠️ 실패 시 확인: Task 가 실행 중이면 SUSPEND 가 즉시 반영되지 않을 수 있습니다.
--      SHOW TASKS 로 state 가 suspended 가 된 것을 확인한 뒤 다음으로 넘어가십시오.

-- ── ② 계정 레벨 서비스 객체 삭제 ────────────────────────────────────────────
-- Cortex Search Service 는 DB 삭제로도 함께 사라지지만, 서빙 리소스를 먼저
-- 해제하기 위해 명시적으로 삭제합니다.
-- DROP CORTEX SEARCH SERVICE IF EXISTS KSM_CHATBOT_DB.SERVING.KSM_HQ_SEARCH_SERVICE;

-- ── ③ 자식 객체 삭제 (선택 — DB 를 지우면 불필요) ───────────────────────────
-- DB 를 통째로 삭제하면 아래는 실행할 필요가 없습니다.
-- [3] 에서 DB 보존을 선택한 경우에만 개별 삭제하십시오.
--
-- DROP TASK      IF EXISTS KSM_CHATBOT_DB.OPS.TASK_INGEST_NEW_DOCUMENTS;
-- DROP PROCEDURE IF EXISTS KSM_CHATBOT_DB.OPS.SP_RUN_INGEST_CYCLE();
-- DROP PROCEDURE IF EXISTS KSM_CHATBOT_DB.SERVING.SP_EXECUTE_GUARDED_CHAT(VARCHAR);
-- DROP PROCEDURE IF EXISTS KSM_CHATBOT_DB.SILVER.SP_PROCESS_NEW_DOCUMENTS();
-- DROP FUNCTION  IF EXISTS KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(VARCHAR);
-- DROP FUNCTION  IF EXISTS KSM_CHATBOT_DB.SECURITY.CALCULATE_STAGE_FILE_HASH(STRING);
-- DROP TABLE     IF EXISTS KSM_CHATBOT_DB.SECURITY.PROMPT_GUARD_CONFIG;
-- DROP TABLE     IF EXISTS KSM_CHATBOT_DB.OPS.INGEST_EVENT_LOG;
-- DROP TABLE     IF EXISTS KSM_CHATBOT_DB.SILVER.DOCUMENT_CHUNKS;
-- DROP STREAM    IF EXISTS KSM_CHATBOT_DB.BRONZE.STAGE_DOC_STREAM;
-- REMOVE @KSM_CHATBOT_DB.BRONZE.DOC_STAGE;          -- 업로드 파일 삭제
-- DROP STAGE     IF EXISTS KSM_CHATBOT_DB.BRONZE.DOC_STAGE;

-- ── ④ 부모 객체 삭제 — Database ─────────────────────────────────────────────
-- 아래 하나로 6대 스키마와 그 안의 모든 테이블·스테이지·스트림·함수·프로시저·Task 가
-- 함께 삭제됩니다. [4] 에서 대상을 확인했는지 다시 확인하십시오.
-- 🔴 업로드한 원본 문서도 함께 사라집니다.
--
-- DROP DATABASE IF EXISTS KSM_CHATBOT_DB;

-- ── ⑤ Warehouse 삭제 ───────────────────────────────────────────────────────
-- DROP WAREHOUSE IF EXISTS KSM_CHATBOT_WH;
--
--   ⚠️ 실패 시 확인: 다른 세션이 이 웨어하우스를 쓰고 있으면 실패할 수 있습니다.
--      SHOW WAREHOUSES 로 running / queued 가 0인지 확인하십시오.

-- ── ⑥ Role 삭제 (가장 마지막) ───────────────────────────────────────────────
-- 앞 단계 실행에 이 Role 의 권한이 필요할 수 있으므로 마지막에 지웁니다.
-- Role 을 삭제하면 이 Role 에 부여했던 모든 권한(계정 레벨 EXECUTE TASK,
-- SNOWFLAKE.CORTEX_USER, 사용자에게 부여한 Role)도 함께 사라집니다.
--
-- DROP ROLE IF EXISTS KSM_CHATBOT_USER_ROLE;
-- DROP ROLE IF EXISTS KSM_CHATBOT_ADMIN_ROLE;


-- ##############################################################################
-- [6] 세션 변수 정리
-- ##############################################################################
-- 세션 변수는 세션 종료 시 사라지므로 선택 사항입니다.
-- UNSET V_EXEC_USER;


-- ##############################################################################
-- [7] 🔴 계정 파라미터 원복 — DROP 으로 되돌아가지 않는 변경
-- ##############################################################################
-- 이 절을 건너뛰면 실습 전 상태로 복구되지 않습니다.
-- 02_ [0.2]·[0.3] 또는 10_ [1] 에서 기록한 실습 전 값에 따라 **하나만** 고르십시오.

-- ── 7.1 AI_SETTINGS ────────────────────────────────────────────────────────
-- 기록한 실습 전 값: ______________________________________
--
-- 경우 1) 10_ [2.2] 를 실행하지 않았다 → 할 일 없음
-- 경우 2) 실습 전에도 이미 같은 guardrails 설정이었다 → 할 일 없음
-- 경우 3) 실습 전이 비어 있음 / 미설정이었다
-- ALTER ACCOUNT UNSET AI_SETTINGS;
--
-- 경우 4) 실습 전에 다른 YAML 이 설정되어 있었다
-- ALTER ACCOUNT SET AI_SETTINGS = $$
-- <기록해 둔 실습 전 YAML 전문을 그대로 붙여넣으십시오>
-- $$;

-- ── 7.2 CORTEX_ENABLED_CROSS_REGION ────────────────────────────────────────
-- 기록한 실습 전 값: ______________________
--
-- 🔴 10_ [2.1] 을 **실행하지 않았다면 아래를 실행하지 마십시오.**
--    실습이 바꾸지 않은 설정을 되돌리면 계정 상태가 실습 전보다 나빠집니다.
--
-- 경우 1) 10_ [2.1] 을 건너뛰었다 (이미 활성이었다) → 할 일 없음
-- 경우 2) 실습 전이 DISABLED 였고 [2.1] 로 바꿨다
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'DISABLED';
--
-- 경우 3) 실습 전이 다른 리전 그룹이었고 [2.1] 로 ANY_REGION 으로 넓혔다
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = '<기록한 원래 값>';

-- ── 7.3 원복 확인 ──────────────────────────────────────────────────────────
SHOW PARAMETERS LIKE 'AI_SETTINGS' IN ACCOUNT;
SELECT "key", "value", "level" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--   실습 전 기록값과 같은가: ☐ 예  ☐ 아니오 (아니오면 7.1 재확인)

SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
SELECT "key", "value", "level" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--   실습 전 기록값과 같은가: ☐ 예  ☐ 아니오 (아니오면 7.2 재확인)


-- ##############################################################################
-- [8] 정리 완료 검증 — "삭제했다"가 아니라 "없음을 확인했다"
-- ##############################################################################
-- 아래 쿼리는 **실습 리소스가 없는 상태에서 실제로 실행해 0행을 확인했습니다.**

-- 8.1 접두사 기반 — 모두 결과 없음이어야 정상
SHOW DATABASES  LIKE 'KSM_CHATBOT%';   -- 0행
SHOW WAREHOUSES LIKE 'KSM_CHATBOT%';   -- 0행
SHOW ROLES      LIKE 'KSM_CHATBOT%';   -- 0행

-- 8.2 태그 기반 광역 검색 — 접두사를 놓친 잔여물 탐지
--     ⚠️ ACCOUNT_USAGE 뷰를 쓰지 않습니다. 계정에 따라 없을 수 있고 2~3시간 지연됩니다.
--        즉시 확인에는 SHOW + RESULT_SCAN 이 정확합니다.
SHOW WAREHOUSES;
SELECT "name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[chatbot-prompt-guard]%';   -- 0행

SHOW DATABASES;
SELECT "name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[chatbot-prompt-guard]%';   -- 0행

SHOW ROLES;
SELECT "name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[chatbot-prompt-guard]%';   -- 0행

-- 8.3 Task / Search Service 잔여 확인
SHOW TASKS IN ACCOUNT;
SELECT "database_name", "name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" ILIKE 'TASK_INGEST_NEW_DOCUMENTS';     -- 0행

SHOW CORTEX SEARCH SERVICES IN ACCOUNT;             -- 실습 서비스 없음

-- 8.4 사전 스냅샷과 대조 — 왕복 가능성 증명
--     02_ [1] 또는 95_실습전_기준선.md 에 기록한 값과 비교하십시오.
SHOW DATABASES;    --   실습 후 개수: ______  (실습 전과 같아야 함)
SHOW WAREHOUSES;   --   실습 후 개수: ______  (실습 전과 같아야 함)
SHOW ROLES;        --   실습 후 목록이 실습 전과 같은가: ☐ 예  ☐ 아니오

-- 상세 대조 기록은 96_실습후_대조.md 에 남기십시오.


-- ##############################################################################
-- [9] 정리 체크리스트
-- ##############################################################################
-- 비용이 발생하는 항목을 굵게 표시했습니다.
--
--   ☐ **OPS.TASK_INGEST_NEW_DOCUMENTS 삭제 (또는 SUSPEND)**   ← 서버리스 크레딧
--   ☐ **SERVING.KSM_HQ_SEARCH_SERVICE 삭제**                   ← 서빙 스토리지 + 컴퓨트
--   ☐ **KSM_CHATBOT_WH 삭제 (또는 SUSPEND)**                   ← 컴퓨트 크레딧
--   ☐ **BRONZE.DOC_STAGE 업로드 파일 삭제**                     ← 스토리지
--   ☐ **SILVER.DOCUMENT_CHUNKS 삭제**                          ← 스토리지
--   ☐ OPS.INGEST_EVENT_LOG 삭제
--   ☐ SECURITY.PROMPT_GUARD_CONFIG 삭제
--   ☐ BRONZE.STAGE_DOC_STREAM 삭제
--   ☐ 프로시저 3종 삭제 (SP_PROCESS_NEW_DOCUMENTS / SP_RUN_INGEST_CYCLE / SP_EXECUTE_GUARDED_CHAT)
--   ☐ 함수 2종 삭제 (MASK_PII_TEXT / CALCULATE_STAGE_FILE_HASH)
--   ☐ KSM_CHATBOT_DB 삭제 (6대 스키마 포함)
--   ☐ KSM_CHATBOT_USER_ROLE 삭제
--   ☐ KSM_CHATBOT_ADMIN_ROLE 삭제
--   ☐ 🔴 **AI_SETTINGS 원복** ([7.1])                          ← DROP 으로 안 됨
--   ☐ 🔴 **CORTEX_ENABLED_CROSS_REGION 원복** ([7.2], 변경했을 때만)  ← DROP 으로 안 됨
--   ☐ [8] 검증 쿼리 전부 0행 확인
--   ☐ 사전 스냅샷과 대조 완료 (96_실습후_대조.md 기록)
--
-- 외부 리소스: 이 실습은 Snowflake 외부에 리소스를 만들지 않습니다.
--   단, 04_ 에서 사내 시스템 자동 동기화를 구성했다면 그 배치·자격증명을 별도로
--   정리하십시오. 실습 범위에서는 수동 업로드만 다루므로 해당 항목이 없습니다.
