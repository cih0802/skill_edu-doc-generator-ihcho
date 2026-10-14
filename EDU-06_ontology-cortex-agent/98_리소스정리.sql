/*
title: 온톨로지 실습 리소스 완전 정리
step: 98
type: sql
summary: 실습 중 생성된 모든 객체(Cortex Agent 2종, Semantic View, Cortex Search 서비스, 테이블, 뷰, 프로시저, DB, WH, ROLE)를 객체 대장과 1:1 대조하여 안전하고 멱등하게 완전 정리
requires: [08_온톨로지_그라운딩_CortexAgent_구현.sql, 90_아키텍처_심화_및_벤치마크_분석.md]
next: [99_generate_index.py]
*/

-- 검증 상태 (2026-10-14, 2차 개선 후 완주 실행)
--   ✅ PART 0 일시 중단(SUSPEND SERVING) — 실제 실행
--   ✅ PART A·B 1회차 — 성공 / 2회차 — 오류 없음 (방어 블록 "건너뜁니다" 반환)
--   ✅ PART D 3개 SHOW 모두 0행 = 02_ 사전 스냅샷과 일치

-- ============================================================================
-- 💰 (1) 비용 경고 — 가장 먼저 읽으십시오
--   | 객체                                   | 과금                                  | 멈추는 방법                 |
--   |----------------------------------------|---------------------------------------|-----------------------------|
--   | **ONTOLOGY_SEARCH_SERVICE**            | 서빙 중 지속 과금 + 1 hour 재인덱싱    | PART 0 SUSPEND / PART A     |
--   | **ONTOLOGY_*_AGENT** (2종)             | 호출 시 LLM 토큰                       | 호출하지 않으면 0 / PART A  |
--   | **EDU06_IHCHO_ONTOLOGY_WH**            | 쿼리·재인덱싱 시 (60초 자동 중지)       | PART 0 SUSPEND / PART B     |
-- ============================================================================

-- ============================================================================
-- 🔴 사용법
--   · PART A·B 의 DROP 은 주석 처리되어 있습니다. PART C-0 대상 확인 후 주석을 해제해 실행하십시오
--   · 계정 기본 객체(COMPUTE_WH, SNOWFLAKE DB, 시스템 역할, PUBLIC)는 삭제하지 않습니다
--   · 실습 WH 가 아닌 웨어하우스로 실행합니다. 실습 WH 로 실행하면 PART B 에서 세션 WH 가 삭제되어
--     2회차 실행 시 방어 블록의 RESULT_SCAN 이 "No active warehouse selected" 로 실패합니다 (EDU-05 에서 실측)
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;   -- 계정에 있는 다른 WH 로 바꿔도 됩니다. 이 문서는 이 WH 를 변경하지 않습니다

-- ============================================================================
-- (2) PART 0. 일시 중단 — 삭제 없이 비용만 멈춥니다 (실습을 이어서 할 때)
--   DB 가 없으면 이 구문은 실패합니다 (IF EXISTS 는 상위 DB 부재를 막지 못함). 그때는 건너뛰십시오
-- ============================================================================
-- ALTER CORTEX SEARCH SERVICE IF EXISTS EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE SUSPEND SERVING;
-- ALTER CORTEX SEARCH SERVICE IF EXISTS EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE SUSPEND INDEXING;
-- ALTER WAREHOUSE IF EXISTS EDU06_IHCHO_ONTOLOGY_WH SUSPEND;

-- ============================================================================
-- (5) 삭제 전 데이터 보존 (선택) — 실습 DB 밖에 보존하며 스토리지 비용이 계속 발생합니다
-- ============================================================================
-- CREATE TABLE <보존용_DB>.<스키마>.KG_FLATTENED_PROFILES_BAK AS SELECT * FROM EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.KG_FLATTENED_PROFILES;

-- ============================================================================
-- PART C-0. 대상 확인 — COMMENT 가 'EDU-06' 로 시작하는지 확인합니다
-- ============================================================================
SHOW DATABASES LIKE 'EDU06_IHCHO_%';
SHOW WAREHOUSES LIKE 'EDU06_IHCHO_%';
SHOW ROLES LIKE 'EDU06_IHCHO_%';

-- ============================================================================
-- (3)(4)(9) PART A. 스키마 레벨 객체 + DB — 재실행 안전 방어 블록
--   순서: ① Agent(검색 서비스·Semantic View 를 참조) → ② Cortex Search → ③ DB(나머지 전체)
--   상태 전이 불필요: Agent·Cortex Search·Semantic View 는 DROP 으로 바로 삭제됩니다 (DB 삭제로도 함께 삭제)
--   ACCOUNT_USAGE / INFORMATION_SCHEMA 뷰 대신 SHOW + RESULT_SCAN 으로 존재를 확인합니다
-- ============================================================================
-- EXECUTE IMMEDIATE $$
-- DECLARE
--     n INT;
-- BEGIN
--     SHOW DATABASES LIKE 'EDU06_IHCHO_ONTOLOGY_DB';
--     SELECT COUNT(*) INTO :n FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--     IF (n = 0) THEN
--         RETURN 'EDU06_IHCHO_ONTOLOGY_DB 가 이미 없습니다. 이 절을 건너뜁니다.';
--     END IF;
--     DROP AGENT IF EXISTS EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_GROUNDED_AGENT;
--     DROP AGENT IF EXISTS EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_BASELINE_AGENT;
--     DROP CORTEX SEARCH SERVICE IF EXISTS EDU06_IHCHO_ONTOLOGY_DB.PUBLIC.ONTOLOGY_SEARCH_SERVICE;
--     DROP DATABASE IF EXISTS EDU06_IHCHO_ONTOLOGY_DB;
--     RETURN 'EDU06_IHCHO_ONTOLOGY_DB 삭제 완료';
-- END;
-- $$;

-- ============================================================================
-- PART B. 계정 레벨 컴퓨트 및 역할 (역할은 가장 마지막. 사용자에 대한 역할 부여도 함께 사라집니다)
-- ============================================================================
-- DROP WAREHOUSE IF EXISTS EDU06_IHCHO_ONTOLOGY_WH;
-- DROP ROLE IF EXISTS EDU06_IHCHO_ONTOLOGY_ROLE;

-- ============================================================================
-- (6) 외부 리소스: 없음 (이 실습은 Snowflake 밖에 아무것도 만들지 않습니다)
-- ============================================================================

-- ============================================================================
-- (7) PART D. 잔여 객체 0건 검증 — 02_ [0.0] 사전 스냅샷과 대조
--   기대: 3개 SHOW 모두 0행 (사전 스냅샷에 있던 객체는 그대로)
-- ============================================================================
SHOW DATABASES LIKE 'EDU06_IHCHO_%';
SHOW WAREHOUSES LIKE 'EDU06_IHCHO_%';
SHOW ROLES LIKE 'EDU06_IHCHO_%';

-- ============================================================================
-- (8) 정리 체크리스트 (01_ 객체 대장과 1:1)
--   [ ] **ONTOLOGY_GROUNDED_AGENT / ONTOLOGY_BASELINE_AGENT** ............ PART A
--   [ ] **ONTOLOGY_SEARCH_SERVICE** ....................................... PART A
--   [ ] EDU06_IHCHO_ONTOLOGY_DB (KG_NODE, KG_EDGE, SCREENING_VIABILITY, V_CELL_LINE_SUMMARY,
--       SP_GET_ANCESTORS, SP_EXPAND_COHORT, KG_FLATTENED_PROFILES, SEM_SCREENING_VIABILITY) .. PART A
--   [ ] **EDU06_IHCHO_ONTOLOGY_WH** ....................................... PART B
--   [ ] EDU06_IHCHO_ONTOLOGY_ROLE ......................................... PART B
-- ============================================================================
