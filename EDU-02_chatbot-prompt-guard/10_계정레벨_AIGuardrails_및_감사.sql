/*
title: 계정 레벨 Cortex AI Guardrails 및 감사
step: 10
type: sql
summary: 계정 파라미터 AI_SETTINGS로 Cortex AI Guardrails(프롬프트 인젝션 탐지)를 활성화하고 차단 이력을 감사한다. 기존 계정 속성을 변경하므로 실습 전 값 기록과 원복이 필수다.
requires: 09_가드동적제어_및_검증.sql
next: 98_리소스정리.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-16, 계정 LJ20513 / Enterprise, **실습 완주**):
--   ✅ [1] 실습 전 값 기록 — 실제 실행. AI_SETTINGS = 빈 값 / level 없음(미설정),
--      CORTEX_ENABLED_CROSS_REGION = ANY_REGION (level=ACCOUNT)
--      → 이미 활성이므로 [2.1] 은 건너뜀(불필요한 변경을 만들지 않았다)
--   ✅ [2.2] ALTER ACCOUNT SET AI_SETTINGS — **실제 실행 검증 완료.**
--      문서의 YAML 형태가 그대로 동작한다
--   ✅ [2.3] 변경 확인 — 실제 실행. level 이 (없음) → ACCOUNT 로 전환됨을 확인
--   ✅ [4.1] 뷰 컬럼 목록 조회 — 실제 실행 검증 완료
--   ✅ [4.2] 감사 쿼리(TOKENS / TOKEN_CREDITS / GUARDRAIL_RESULTS) — 실제 실행 검증 완료.
--      0행 반환. ACCOUNT_USAGE 지연 + 적용 대상 클라이언트 미사용으로 예상된 결과다
--   ✅ 98_ [7.1] 원복 — **실제 실행 검증 완료.** ALTER ACCOUNT UNSET AI_SETTINGS 로
--      실습 전 상태(빈 값 / level 없음)와 동일하게 복구됨을 확인
--
-- ⚠️ [3] 인젝션 탐지의 실제 관찰은 미검증. 적용 대상이 CoCo / CoWork / Cortex Agents 이며
--    이 실습은 Cortex Agent 를 만들지 않는다. 계정 설정과 감사 경로만 확인했다
-- ==============================================================================
-- ==============================================================================
-- 🔴🔴🔴 경고 — 이 문서는 기존 계정 속성을 변경합니다 🔴🔴🔴
-- ==============================================================================
-- 이 문서에서 수행하는 변경은 **신규 객체 생성이 아닙니다.**
-- 따라서 DROP 으로 되돌아가지 않으며, 98_ 의 원복 절을 실행해야만 복구됩니다.
--
--   변경 대상 1: ALTER ACCOUNT SET AI_SETTINGS
--   변경 대상 2: ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION  (필요한 경우만)
--
-- 두 값 모두 **계정 전체에 영향을 미칩니다.** 공유 계정에서는 다른 사용자의
-- 워크로드에 영향을 줄 수 있으므로, 실습 전용 계정이 아니면 계정 관리자와 협의하십시오.
--
-- ✋ 진행하기 전에 02_ [0.2]·[0.3] 에서 실습 전 값을 기록했는지 확인하십시오.
--    기록하지 않았다면 지금 아래 [1] 을 먼저 실행하십시오.
-- ==============================================================================


-- ==============================================================================
-- ⚙️ 설정값 / 전제 조건
-- ==============================================================================
--   변경 파라미터  : AI_SETTINGS (계정)
--   필요 권한      : ACCOUNTADMIN
--   필요 Edition   : Enterprise Edition 이상
--   필요 전제      : CORTEX_ENABLED_CROSS_REGION 이 DISABLED 가 아니어야 함
--                    (ANY_REGION / AWS_US / AWS_EU / AWS_JP / AWS_APJ / AWS_GLOBAL)
--   제외 계정      : Gov / VPS / Sovereign 계정은 지원되지 않음
--
--   예상 소요 시간 : 약 10분
--   💰 Guardrails 는 스캔한 토큰 수에 따라 크레딧이 발생합니다.
-- ==============================================================================

USE ROLE ACCOUNTADMIN;


-- ##############################################################################
-- [1] 🔴 실습 전 값 기록 — 이 값 없이는 원복할 수 없습니다
-- ##############################################################################
-- 02_ 에서 이미 기록했다면 건너뛰어도 됩니다. 기록이 없으면 반드시 지금 실행하십시오.

-- 1.1 AI_SETTINGS 실습 전 값
SHOW PARAMETERS LIKE 'AI_SETTINGS' IN ACCOUNT;

SELECT "key", "value", "default", "level"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--   실습 전 AI_SETTINGS "value" : ______________________________________
--   실습 전 "level"             : ______________  (비어 있으면 계정 미설정)
--
--   🔴 원복 분기 판정 — 98_ 에서 사용합니다. 지금 체크하십시오.
--     ☐ 경우 1) 이미 원하는 guardrails 설정이 되어 있다 → 변경 자체를 건너뛴다
--     ☐ 경우 2) 비어 있음 / 미설정                     → 98_ 에서 UNSET
--     ☐ 경우 3) 다른 값이 설정되어 있다                → 98_ 에서 그 값으로 SET
--        경우 3이면 YAML 전문을 그대로 아래에 보관하십시오:
--   ______________________________________________________________________
--   ______________________________________________________________________

-- 1.2 CORTEX_ENABLED_CROSS_REGION 실습 전 값
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;

SELECT "key", "value", "default", "level"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--   실습 전 값: ______________  (제품 기본값은 DISABLED)
--
--   💡 값이 이미 DISABLED 가 아니라면 [2.1] 변경을 **건너뛰어도 됩니다.**
--      불필요한 변경을 만들지 않는 것이 원복보다 낫습니다.
--     ☐ 이미 활성 → [2.1] 건너뜀 (98_ 에서도 이 파라미터는 손대지 않음)
--     ☐ DISABLED  → [2.1] 수행 필요 (98_ 에서 DISABLED 로 원복)


-- ##############################################################################
-- [2] 계정 파라미터 변경
-- ##############################################################################

-- ── 2.1 크로스 리전 추론 활성화 (필요한 경우만) ──────────────────────────────
-- 🔴 기존 계정 속성 변경입니다. DROP 으로 되돌아가지 않습니다.
--    [1.2] 에서 "이미 활성"으로 체크했다면 이 블록을 실행하지 마십시오.
-- 실행하려면 주석을 해제하십시오.
--
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
--
-- 리전 그룹을 좁히려면 'AWS_JP' 또는 'AWS_APJ' 등을 쓰십시오.
-- 값을 좁히면 사용 가능한 모델이 줄어들 수 있습니다.

-- ── 2.2 🔴 Cortex AI Guardrails 활성화 ──────────────────────────────────────
-- 기존 계정 속성 변경입니다. 반드시 [1.1] 기록을 마친 뒤 실행하십시오.
-- 실행하려면 주석을 해제하십시오.
--
-- ALTER ACCOUNT SET AI_SETTINGS = $$
--   guardrails:
--     advanced_prompt_injection:
--       - enabled: true
-- $$;

-- ── 2.3 변경 결과 확인 ──────────────────────────────────────────────────────
SHOW PARAMETERS LIKE 'AI_SETTINGS' IN ACCOUNT;

SELECT "key", "value", "level"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
--   변경 후 "level" 이 ACCOUNT 로 바뀌었는지 확인: ☐ 확인


-- ##############################################################################
-- [3] 동작 확인 — 어디서 관찰할 수 있는가
-- ##############################################################################
-- 🔴 09_ 의 SQL 챗봇(SNOWFLAKE.CORTEX.COMPLETE)에서는 이 기능이 동작하지 않습니다.
--    적용 대상이 아니기 때문입니다. 아래 경로 중 하나에서 관찰하십시오.
--
-- | 클라이언트          | 관찰 위치                                                  |
-- |---------------------|------------------------------------------------------------|
-- | CoCo (Cortex Code)  | 대화 로그(Conversation history)의 탐지 기록                |
-- | Snowflake CoWork    | Snowsight » AI & ML » Agents » 해당 에이전트 Observability  |
-- | Cortex Agents       | 위와 동일 (Agent monitoring / trace)                       |
--
-- 실습에서 인젝션 탐지를 직접 보려면 Cortex Agent 를 만들어 질의해야 하며,
-- 이는 이 실습의 범위를 넘습니다. 여기서는 계정 설정과 감사 경로만 확인합니다.


-- ##############################################################################
-- [4] Guardrails 감사 — 차단 이력 및 토큰/크레딧 소비
-- ##############################################################################
-- ⚠️ ACCOUNT_USAGE 뷰는 최대 2~3시간 지연됩니다. 방금 발생한 이벤트는 보이지 않습니다.
--    즉시 확인이 필요하면 [3] 의 클라이언트별 로그를 쓰십시오.

-- 4.1 사용 가능한 컬럼 확인 — 뷰 스키마는 변경될 수 있습니다
SELECT COLUMN_NAME, DATA_TYPE
FROM SNOWFLAKE.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'ACCOUNT_USAGE'
  AND TABLE_NAME   = 'CORTEX_AI_GUARDRAILS_USAGE_HISTORY'
ORDER BY COLUMN_NAME;

-- 4.2 최근 72시간 동안 플래그된 요청
--     GUARDRAILS_SIGNAL = TRUE : 인젝션 가능성으로 플래그된 요청
SELECT
    USAGE_TIME,
    USER_NAME,
    AGENTIC_SOURCE,          -- 어느 클라이언트에서 발생했는지
    GUARDRAILS_SIGNAL,
    GUARDRAIL_RESULTS,       -- 탐지 상세
    TOKENS,                  -- 스캔한 토큰 수
    TOKEN_CREDITS,           -- 토큰 기준 크레딧
    REQUEST_ID
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_GUARDRAILS_USAGE_HISTORY
WHERE GUARDRAILS_SIGNAL = TRUE
  AND USAGE_TIME >= DATEADD('hour', -72, CURRENT_TIMESTAMP())
ORDER BY USAGE_TIME DESC
LIMIT 100;
--   조회된 차단 이력: ______ 건  (Agent 사용 이력이 없으면 0건이 정상)

-- 4.3 전체 스캔 활동 및 비용 집계
SELECT
    DATE_TRUNC('day', USAGE_TIME) AS USAGE_DAY,
    AGENTIC_SOURCE,
    COUNT(*)                            AS REQUESTS,
    SUM(IFF(GUARDRAILS_SIGNAL, 1, 0))   AS FLAGGED,
    SUM(TOKENS)                         AS TOKENS_SCANNED,
    SUM(TOKEN_CREDITS)                  AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_GUARDRAILS_USAGE_HISTORY
WHERE USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1 DESC;


-- ##############################################################################
-- 🧹 리소스 정리 — 🔴 이 문서의 변경은 DROP 으로 되돌아가지 않습니다
-- ##############################################################################
-- 전체 정리는 98_리소스정리.sql 이 정본이며, 원복 분기 절이 거기에 있습니다.
-- 이 문서까지 진행한 뒤 중단하는 경우, [1] 에서 기록한 값에 따라 아래 중 하나만
-- 실행하십시오. 잘못된 분기를 고르면 계정 설정이 실습 전과 달라집니다.
--
-- 경우 1) 실습 전에도 이미 이 guardrails 설정이었다 → 할 일 없음
--
-- 경우 2) 실습 전이 비어 있음/미설정이었다
-- ALTER ACCOUNT UNSET AI_SETTINGS;
--
-- 경우 3) 실습 전에 다른 YAML 이 설정되어 있었다
-- ALTER ACCOUNT SET AI_SETTINGS = $$
-- <[1.1] 에 보관한 실습 전 YAML 전문을 그대로 붙여넣으십시오>
-- $$;
--
-- CORTEX_ENABLED_CROSS_REGION — [2.1] 을 실행했을 때만 원복합니다.
-- 건너뛰었다면 아래를 실행하지 마십시오. 계정 설정을 실습 전보다 나쁘게 만듭니다.
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'DISABLED';
