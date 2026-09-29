/*
title: 리소스 정리 (Teardown)
step: 98
type: sql
summary: 실습이 만든 계정·스키마 객체 25종을 역순으로 정리하고(일시 중단 선택지 포함), 재실행 안전 방어 블록과 정리 완료 검증 쿼리로 사전 스냅샷과 대조한다.
requires: 10_CortexAgent_구성.sql
next: 없음
*/

-- ==============================================================================
-- 💰 (1) 비용 경고 — 가장 먼저 읽으십시오
--   지속 과금되는 것 (실습을 멈춰도 계속 나갈 수 있음)
--   | 객체                         | 과금                        | 멈추는 방법                           |
--   |------------------------------|-----------------------------|---------------------------------------|
--   | **DOC_SEARCH_SVC**           | **서빙 컴퓨트(떠 있는 동안)** | AUTO_SUSPEND 1800초(07_) / SUSPEND / DROP |
--   | DOC_AGENT                    | 호출 시에만 (상시 과금 없음)  | DROP                                  |
--   | **TSK_INGEST_DOCS**          | 새 파일이 오면 WH 기동       | SUSPEND / DROP                        |
--   | **DOCRAG_WH**                | 쿼리 시 (60초 자동중지)      | SUSPEND / DROP                        |
--   | DOC_STAGE 파일·테이블·인덱스   | 스토리지                     | DROP                                  |
-- ==============================================================================

-- ==============================================================================
-- 검증 상태 (2026-09-28, 실습 완주 직후 실행)
--   ✅ PART C 전체 — 실제 실행(1회차). 모든 DROP 성공
--   ✅ PART C 전체 — **2회차 재실행** 오류 없음 (방어 블록이 "건너뜁니다" 반환)
--   ✅ PART D 검증 쿼리 — 실제 실행. DOCRAG% 객체 0행
--   ✅ [2차] DOC_AGENT · DOCRAG_USER_RL 정리 추가 — 2차 완주 후 2회 실행해 확인
--   ✅ 공식 문서 대조: DROP CORTEX SEARCH SERVICE / DROP RESOURCE MONITOR / DROP TASK
--   ⚠️ PART A 일시 중단 경로는 실행했으나, 이후 곧바로 PART C 를 실행해 장시간 중단 상태는 관찰하지 않음
-- ==============================================================================

-- ==============================================================================
-- 🔴 사용법
--   · 실행할 DROP 문은 `--▶ ` 로 주석 처리되어 있습니다. **내용을 확인한 뒤** 접두사를 지우고 실행하십시오
--   · 계정 기본 객체(COMPUTE_WH, SNOWFLAKE DB, 시스템 역할, PUBLIC)는 이 문서가 건드리지 않습니다
--   · 이 문서는 **두 번 실행해도 안전**하도록 만들었습니다 (PART C-1 방어 블록)
-- ==============================================================================

USE ROLE ACCOUNTADMIN;

-- ==============================================================================
-- PART A. (2) 일시 중단 — 삭제 없이 비용만 멈춥니다 (실습을 이어서 할 때)
-- ==============================================================================
--▶ ALTER TASK DOCRAG_DB.CURATED.TSK_INGEST_DOCS SUSPEND;
--▶ ALTER CORTEX SEARCH SERVICE DOCRAG_DB.SERVING.DOC_SEARCH_SVC SUSPEND SERVING;
--▶ ALTER CORTEX SEARCH SERVICE DOCRAG_DB.SERVING.DOC_SEARCH_SVC SUSPEND INDEXING;
--▶ ALTER WAREHOUSE DOCRAG_WH SUSPEND;
--   ⚠️ 일시 중단해도 남는 것: 스토리지(스테이지 파일·테이블·인덱스). 과금은 작지만 0 이 아닙니다
--   재개: ALTER TASK … RESUME; ALTER CORTEX SEARCH SERVICE … RESUME SERVING; RESUME INDEXING;

-- ==============================================================================
-- PART B. (5) 삭제 전 데이터 보존 (선택)
--   남길 가치가 있는 것: EVAL_RESULT(평가 이력), QUERY_LOG(질의·토큰 추정), PIPELINE_RUN_LOG
--   DB 를 지우면 함께 사라집니다. 보존하려면 **다른 DB 로 복사**한 뒤 진행하십시오 (그 DB 는 스토리지 과금)
-- ==============================================================================
--▶ CREATE TABLE <보존용_DB>.<스키마>.DOCRAG_EVAL_RESULT_BAK AS SELECT * FROM DOCRAG_DB.SERVING.EVAL_RESULT;

-- ==============================================================================
-- PART C. (3)(4) 완전 삭제 — 역순
--   ① 실행 중인 것 정지 (태스크, 검색 서비스)       ← DB 가 있어야 하는 구문 → C-1 방어 블록
--   ② DB 삭제 (스키마·테이블·뷰·스테이지·스트림·UDTF·프로시저 전부 포함)
--   ③ 계정 레벨: 웨어하우스 → 리소스 모니터
--   ④ 역할 (마지막 — 앞 단계 객체의 소유자였으므로)
-- ==============================================================================

-- [C-0] 대상 확인 — 광범위 삭제 전에 무엇이 지워지는지 봅니다
SHOW DATABASES         LIKE 'DOCRAG%';
SHOW WAREHOUSES        LIKE 'DOCRAG%';
SHOW RESOURCE MONITORS LIKE 'DOCRAG%';
SHOW ROLES             LIKE 'DOCRAG%';
--   위 4개 결과가 모두 이 실습(COMMENT 에 [unstructured-doc-rag-pipeline])의 것인지 확인하십시오

-- [C-1] ① 실행 중인 것 정지 — 🔴 방어 블록
--   IF EXISTS 는 **상위 DB 부재를 막아주지 않습니다.** DB 가 이미 없으면
--   "Database 'DOCRAG_DB' does not exist" 로 이름 해석 단계에서 실패합니다.
--   그래서 SHOW 로 DB 존재를 먼저 확인합니다 (ACCOUNT_USAGE 뷰에 의존하지 않음)
--▶ EXECUTE IMMEDIATE $$
--▶ DECLARE
--▶     v_db INTEGER;
--▶     rs RESULTSET;
--▶ BEGIN
--▶     rs := (SHOW DATABASES LIKE 'DOCRAG_DB');
--▶     SELECT COUNT(*) INTO v_db FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--▶     IF (v_db = 0) THEN
--▶         RETURN 'DOCRAG_DB 가 이미 없습니다. C-1 을 건너뜁니다.';
--▶     END IF;
--▶     -- 태스크 정지 → 삭제 (정지하지 않고 DB 를 지우면 실행 중인 회차가 실패로 기록될 수 있습니다)
--▶     ALTER TASK IF EXISTS DOCRAG_DB.CURATED.TSK_INGEST_DOCS SUSPEND;
--▶     DROP  TASK IF EXISTS DOCRAG_DB.CURATED.TSK_INGEST_DOCS;
--▶     -- 검색 서비스 — 서빙 과금 객체라 명시적으로 먼저 지웁니다 (DROP DATABASE 로도 사라집니다)
--▶     -- Agent 는 검색 서비스를 도구로 참조합니다. 먼저 지웁니다 (DROP DATABASE 로도 사라집니다)
--▶     DROP AGENT IF EXISTS DOCRAG_DB.SERVING.DOC_AGENT;
--▶     DROP CORTEX SEARCH SERVICE IF EXISTS DOCRAG_DB.SERVING.DOC_SEARCH_SVC;
--▶     RETURN 'C-1 완료: 태스크·Agent·검색 서비스 삭제';
--▶ END;
--▶ $$;

-- [C-2] ② DB 삭제 — 아래가 함께 사라집니다 (객체 대장 (a) 5~22번)
--   스키마 RAW / CURATED / SERVING
--   스테이지 DOC_STAGE(+업로드 파일) · 스트림 DOC_STAGE_STREAM
--   테이블 DOC_INBOX / DOC_PARSED / DOC_PARSE_ERRORS / DOC_CHUNKS / PIPELINE_RUN_LOG /
--          RAG_CONFIG / ANSWER_CACHE / QUERY_LOG / EVAL_SET / EVAL_RESULT
--   뷰 V_SEARCH_SOURCE · UDTF CHUNK_TECH_DOC · 프로시저 SP_INGEST_NEW_DOCS / SP_ASK / SP_EVALUATE_RAG
--   (C-1 이 건너뛰어졌다면 Agent DOC_AGENT 도 여기서 함께 사라집니다)
--▶ DROP DATABASE IF EXISTS DOCRAG_DB;

-- [C-3] ③ 계정 레벨 — 웨어하우스 먼저, 그다음 리소스 모니터
--   🔴 현재 세션이 DOCRAG_WH 를 쓰고 있다면 먼저 바꿉니다. 사용 중인 WH 를 지우면 후속 문장이 실패합니다
--      (COMPUTE_WH 는 계정 기본 WH 입니다. 없거나 권한이 없으면 가진 WH 로 바꾸십시오)
--▶ USE WAREHOUSE COMPUTE_WH;
--▶ DROP WAREHOUSE IF EXISTS DOCRAG_WH;
--▶ DROP RESOURCE MONITOR IF EXISTS DOCRAG_RM;

-- [C-4] ④ 역할 — 마지막
--   DROP ROLE 은 이 역할에 부여된 권한(CORTEX_USER 데이터베이스 역할, EXECUTE TASK ON ACCOUNT,
--   WH·DB 권한)과 **사용자에게 준 GRANT ROLE** 을 함께 회수합니다 (대장 (b))
--   이 역할이 소유한 객체는 C-2 에서 이미 사라졌습니다
--▶ DROP ROLE IF EXISTS DOCRAG_USER_RL;     -- 10_ 소비자 역할 (사용자에게 준 GRANT ROLE 도 회수)
--▶ DROP ROLE IF EXISTS DOCRAG_ADMIN_RL;

-- ==============================================================================
-- PART D. (7) 정리 완료 검증 — "지웠다" 가 아니라 "없음을 확인했다" 로 끝냅니다
--   SHOW 는 즉시 반영됩니다. ACCOUNT_USAGE 는 수 시간 지연되므로 여기서 쓰지 않습니다
-- ==============================================================================
SHOW DATABASES         LIKE 'DOCRAG%';   -- 0행
SHOW WAREHOUSES        LIKE 'DOCRAG%';   -- 0행
SHOW RESOURCE MONITORS LIKE 'DOCRAG%';   -- 0행
SHOW ROLES             LIKE 'DOCRAG%';   -- 0행

-- 태그로 한 번 더 — 이름을 바꿔 만든 것이 있어도 잡습니다
SHOW WAREHOUSES;
SELECT "name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[unstructured-doc-rag-pipeline]%';   -- 0행
SHOW DATABASES;
SELECT "name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" ILIKE '%[unstructured-doc-rag-pipeline]%';   -- 0행

-- 사전 스냅샷(02_ [0]) 과 대조 — 같은 쿼리를 다시 실행해 빈칸의 값과 비교합니다
SHOW DATABASES;          --   정리 후 데이터베이스 수: ______  (실습 전과 같아야 함)
SHOW WAREHOUSES;         --   정리 후 웨어하우스 목록: ______  (실습 전과 같아야 함)
SHOW ROLES;              --   정리 후 역할 수: ______          (실습 전과 같아야 함)
SHOW RESOURCE MONITORS;  --   정리 후 리소스 모니터 목록: ______
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
--   이 실습은 변경하지 않았습니다. 값이 실습 전 기록과 같아야 합니다

-- ==============================================================================
-- PART E. (6) 외부 리소스 정리
--   | 대상                               | 위치        | 정리                         |
--   |------------------------------------|-------------|------------------------------|
--   | 샘플 PDF (XR-200 / DC-9 / truncated) | 실습자 로컬 | 직접 삭제                    |
--   이 실습은 외부 시스템 설정(IAM, 방화벽, 소스 DB)을 바꾸지 않습니다. 누적형 외부 리소스는 없습니다
-- ==============================================================================

-- ==============================================================================
-- (8) 정리 체크리스트 — 비용 발생 항목은 굵게
--   [ ] **DOC_SEARCH_SVC 삭제** (C-1)            [ ] **TSK_INGEST_DOCS 삭제** (C-1)
--   [ ] DOCRAG_DB 삭제 (C-2)                     [ ] **DOCRAG_WH 삭제** (C-3)
--   [ ] DOCRAG_RM 삭제 (C-3)                     [ ] DOCRAG_ADMIN_RL · DOCRAG_USER_RL 삭제 (C-4)
--   [ ] DOC_AGENT 삭제 (C-1)
--   [ ] PART D 전부 0행                          [ ] 사전 스냅샷과 수량 일치
--   [ ] 로컬 샘플 PDF 삭제                       [ ] (9) 이 문서를 한 번 더 실행해 오류 없음 확인
-- ==============================================================================
