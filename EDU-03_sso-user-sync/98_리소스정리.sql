/*
title: 리소스 정리 (Teardown)
step: 98
type: sql
summary: 이 실습이 만든 Snowflake 객체 전부를 역순으로 제거하고 계정을 실습 전 상태로 되돌린다. 비용 경고, 일시 중단 선택지, 계정 레벨 객체 우선순위, 정리 완료 검증까지 포함한다.
requires: 08_동기화_시나리오_검증.sql
next: 96_실습후_대조.md
*/

-- ==============================================================================
-- [98] 실습 리소스 정리 — 이 문서가 정리의 정본입니다
-- ==============================================================================
-- 각 단계 문서 말미의 `-- 🧹 리소스 정리` 주석은 중간 포기용 부분 정리입니다.
-- **전체 원상복구는 이 문서로 수행합니다.**
--
-- 검증 상태 (2026-09-16, 계정 LJ20513 에서 실제 실행):
--   ✅ PART A~F 전량 실행 — 실제 실행 검증 완료
--   ✅ 정리 후 사전 기준선과 대조 일치 — 실제 실행 검증 완료
--      사용자 1 / 역할 7 / 웨어하우스 3 / 통합 2 / KSM_% DB 0 / KSM_% 역할 0
--   ✅ PART F 검증 쿼리 전량 — 실제 실행 검증 완료 (잔여물 0 확인)
--   ✅ **재실행 안전성 — 실제 실행 검증 완료.** PART C 를 두 번 실행해
--      두 번째 실행에서 `ALTER TASK IF EXISTS` 가 상위 DB 부재로 실패하는 것을
--      재현했고, C-1 을 방어 블록으로 정정한 뒤 DB 가 없는 상태에서 정상 통과함을
--      확인했습니다 (반환: 'KSM_ENTERPRISE_DB 가 이미 없습니다...').
--
--   📌 이전 판에는 이 문서가 없었습니다. 정리 절차가
--      `7.동기화_테스트_및_검증_클린업.sql` 의 7.4 절에 `[선택 실행]` 으로 묻혀
--      있었습니다. 실질적으로 필수인데 선택으로 표기되어 있었고, 실행 가능한
--      정본이 없었습니다. 이 문서로 이관하며 `[선택 실행]` 표기를 제거했습니다.
-- ==============================================================================


-- ##############################################################################
-- PART A. 🔴 비용·보안 경고 — 먼저 읽으십시오
-- ##############################################################################
-- 이 실습은 **비용만 남기는 것이 아니라 계정 보안 상태를 바꿉니다.**
-- 아래 4개는 방치하면 비용 이상의 문제를 만듭니다.
--
-- | 대상 | 방치 시 |
-- | 서버리스 태스크 2개 (RESUME 상태) | 크레딧 지속 소모 + **계정 사용자를 자동으로
-- |                                   | DISABLED 시키는 동작이 계속됩니다** |
-- | SCIM 베어러 토큰                  | CREATE USER / CREATE ROLE / MANAGE GRANTS 로
-- |                                   | 동작하는 **유효한 자격증명**이 남습니다 |
-- | SAML 시큐리티 인티그레이션         | 계정 **로그인 페이지에 SSO 버튼**이 남습니다
-- |                                   | (더미 IdP 로 연결됨) |
-- | 계정 레벨 권한 위임               | KSM_HR_SYNC_ADMIN / AAD_PROVISIONING_ROLE 이
-- |                                   | 계정 사용자·권한을 조작할 수 있는 상태로 남습니다 |
-- | KSM_AUTH_WH 웨어하우스            | 컴퓨트 비용 |
--
-- 🔴 가장 급하면 아래 두 줄만 먼저 실행하십시오 (태스크 정지).
--    이것만으로 자동 계정 비활성화와 서버리스 크레딧이 멈춥니다.
--
-- ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS SUSPEND;
-- ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT SUSPEND;


-- ##############################################################################
-- PART B. 선택 1 — 일시 중단 (실습을 이어서 할 때)
-- ##############################################################################
-- 객체를 남기고 비용과 자동 동작만 멈춥니다.
USE ROLE ACCOUNTADMIN;

-- B-1. 서버리스 태스크 정지 — 크레딧 및 자동 계정 비활성화 중단
-- ⚠️ KSM_ENTERPRISE_DB 가 이미 없으면 아래는 `IF EXISTS` 에도 불구하고
--    "Database ... does not exist" 로 실패합니다. 그 경우 이미 정리된 것이므로
--    PART B 를 수행할 필요가 없습니다 (C-1 의 방어 블록 설명 참고).
ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS SUSPEND;
ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT SUSPEND;

-- B-2. 웨어하우스 정지
ALTER WAREHOUSE IF EXISTS KSM_AUTH_WH SUSPEND;

-- B-3. 상태 확인
SHOW TASKS IN SCHEMA KSM_ENTERPRISE_DB.OPS;
--   두 태스크 모두 state = suspended 여야 합니다: ______

-- 🔴 일시 중단으로도 **남는 것** — 반드시 인지하십시오
--    · SCIM 베어러 토큰은 **여전히 유효합니다.** SUSPEND 로 무효화되지 않습니다
--    · SAML 인티그레이션이 살아 있어 **로그인 페이지의 SSO 버튼이 그대로 남습니다**
--    · 계정 레벨 권한 위임(CREATE USER / MANAGE GRANTS)이 그대로 남습니다
--    · 동기화 프로시저가 만든 사용자 EMP_F*** 가 계정에 남습니다
--    → 보안 상태를 되돌리려면 PART C 의 완전 삭제가 필요합니다.
--      **이 실습은 "잠시 멈춤" 으로 안전해지지 않습니다.**


-- ##############################################################################
-- PART C. 선택 2 — 완전 삭제
-- ##############################################################################
-- 삭제 순서 (생성의 역순). 순서를 지키지 않으면 실패하는 지점을 표시했습니다.
--
--   ① 실행 중인 것 정지        태스크 SUSPEND → DROP
--   ② 스키마 레벨 자식 객체     프로시저 / 스트림 / 테이블  (③ 으로 일괄 가능)
--   ③ 부모 Database            DROP DATABASE
--   ④ 계정 레벨 인티그레이션    DROP SECURITY INTEGRATION  ← 놓치면 영구 잔존
--   ⑤ 계정 레벨 사용자          DROP USER                  ← DB DROP 으로 안 사라짐
--   ⑥ Warehouse
--   ⑦ Role (가장 마지막 — 앞 단계 실행에 이 역할들이 필요할 수 있음)
--   ⑧ 사용자 속성 원복          (이 실습은 해당 없음 — PART E 참고)
--
-- ⚠️ 상태 전이 주의: 태스크는 **RESUME 상태에서 DROP 이 거부됩니다.**
--    반드시 SUSPEND 를 먼저 실행하십시오. (2026-09-16 실행 검증)

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;   -- 삭제 대상인 KSM_AUTH_WH 를 쓰지 않도록 전환합니다


-- ------------------------------------------------------------------------------
-- C-1. ① 서버리스 태스크 정지 및 삭제
-- ------------------------------------------------------------------------------
-- 🔴 `IF EXISTS` 는 **상위 데이터베이스가 없는 경우를 막아주지 않습니다.**
--    KSM_ENTERPRISE_DB 가 이미 삭제된 상태에서 아래를 실행하면 다음으로 실패합니다.
--      Database 'KSM_ENTERPRISE_DB' does not exist or not authorized.
--    → 2026-09-16 실행 검증에서 재현했습니다. 정리 문서는 **재실행되는 것이
--      정상**이므로(중간 실패 후 재시도, 부분 정리 후 재개) 이 지점이 실질적인
--      재실행 안전성 결함입니다.
--    → 아래는 데이터베이스 존재를 먼저 확인하는 방어 블록입니다.
--
-- ⚠️ 상태 전이: 태스크는 RESUME 상태에서 DROP 이 거부되므로 SUSPEND 가 먼저입니다.

EXECUTE IMMEDIATE $$
DECLARE
    v_db_count INTEGER;
    rs RESULTSET;
BEGIN
    -- ACCOUNT_USAGE / INFORMATION_SCHEMA 뷰 존재를 가정하지 않고 SHOW 로 확인합니다.
    rs := (SHOW DATABASES LIKE 'KSM_ENTERPRISE_DB');
    SELECT COUNT(*) INTO v_db_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    IF (v_db_count = 0) THEN
        RETURN 'KSM_ENTERPRISE_DB 가 이미 없습니다. 태스크 정리를 건너뜁니다.';
    END IF;

    ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS SUSPEND;
    ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT SUSPEND;
    DROP TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS;
    DROP TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT;
    RETURN '태스크 2개 SUSPEND 및 DROP 완료';
END;
$$;
--   반환값: ______


-- ------------------------------------------------------------------------------
-- C-2. ②③ 데이터베이스 삭제 (스키마 레벨 객체 일괄 제거)
-- ------------------------------------------------------------------------------
-- 🔴 이 한 줄로 아래가 모두 사라집니다. 보존이 필요하면 PART D 를 먼저 보십시오.
--    · 스키마 6종 (BRONZE / SILVER / GOLD / SERVING / OPS / SECURITY)
--    · HR_EMPLOYEE_MASTER, HR_SYNC_AUDIT_LOG, HR_STREAM_BUFFER,
--      HR_SECURITY_AUDIT_REPORT, FACTORY_EQUIPMENT_MANUALS
--    · HR_EMPLOYEE_STREAM
--    · SP_SYNC_HR_EMPLOYEES, SP_AUDIT_DORMANT_AND_RESIGNED_USERS
DROP DATABASE IF EXISTS KSM_ENTERPRISE_DB;


-- ------------------------------------------------------------------------------
-- C-3. ④ 계정 레벨 시큐리티 인티그레이션 삭제 — 놓치면 계정에 영구 잔존
-- ------------------------------------------------------------------------------
-- 🔴 AAD_SCIM_INTEGRATION 의 DROP 이 **SCIM 베어러 토큰을 무효화합니다.**
--    이 줄을 건너뛰면 유효한 자격증명이 계정에 남습니다.
-- 🔴 ENTRA_ID_SAML_INTEGRATION 의 DROP 이 **로그인 페이지의 SSO 버튼을 제거합니다.**
DROP SECURITY INTEGRATION IF EXISTS ENTRA_ID_SAML_INTEGRATION;
DROP SECURITY INTEGRATION IF EXISTS AAD_SCIM_INTEGRATION;
DROP SECURITY INTEGRATION IF EXISTS MOBILE_APP_OAUTH_INTEGRATION;


-- ------------------------------------------------------------------------------
-- C-4. ⑤ 실습이 만든 사용자 삭제 — DB DROP 으로는 사라지지 않습니다
-- ------------------------------------------------------------------------------
-- 앞의 두 사용자는 문서가 명시적으로 만든 것이고,
-- EMP_F*** 는 **동기화 프로시저가 실행 중에 만든 것**입니다.
DROP USER IF EXISTS KSM_OFFICE_SAMPLE_USER;
DROP USER IF EXISTS KSM_MOBILE_CHATBOT_SVC_USER;

DROP USER IF EXISTS EMP_F001;
DROP USER IF EXISTS EMP_F002;
DROP USER IF EXISTS EMP_F003;
DROP USER IF EXISTS EMP_F004;
DROP USER IF EXISTS EMP_F005;

-- ⚠️ 인사 원장에 다른 사번을 추가했다면 그 사번의 사용자도 생성되었습니다.
--    아래로 잔여물을 먼저 확인하십시오. 목록에 남은 것을 개별 DROP 하십시오.
SHOW USERS LIKE 'EMP_F%';
--   남은 사용자: ______  (없어야 합니다)


-- ------------------------------------------------------------------------------
-- C-5. ⑥ 웨어하우스 삭제
-- ------------------------------------------------------------------------------
DROP WAREHOUSE IF EXISTS KSM_AUTH_WH;


-- ------------------------------------------------------------------------------
-- C-6. ⑦ 역할 삭제 — 계정 레벨 권한 위임이 함께 소멸합니다
-- ------------------------------------------------------------------------------
-- 🔴 KSM_HR_SYNC_ADMIN 과 AAD_PROVISIONING_ROLE 은
--    CREATE USER / CREATE ROLE / MANAGE GRANTS ON ACCOUNT 을 보유합니다.
--    역할을 남기면 계정 사용자·권한을 조작할 수 있는 경로가 남습니다.
--    별도 REVOKE 는 필요하지 않습니다 — 역할 DROP 시 부여된 권한도 함께 사라집니다.
DROP ROLE IF EXISTS KSM_HR_SYNC_ADMIN;
DROP ROLE IF EXISTS AAD_PROVISIONING_ROLE;
DROP ROLE IF EXISTS KSM_OFFICE_USER_ROLE;
DROP ROLE IF EXISTS KSM_FACTORY_WORKER_ROLE;
DROP ROLE IF EXISTS KSM_MOBILE_CHATBOT_SERVICE_ROLE;


-- ##############################################################################
-- PART D. 삭제 전 데이터 보존 선택지
-- ##############################################################################
-- 실습 결과를 남기고 싶으면 C-2 의 DROP DATABASE **전에** 아래를 수행하십시오.
-- ⚠️ 보존하면 **스토리지 비용이 계속 발생합니다.**
--
-- 보존 가치가 있는 것은 감사 이력 2종입니다.
--
-- USE ROLE ACCOUNTADMIN;
-- CREATE DATABASE IF NOT EXISTS KSM_KEEP_DB
--   COMMENT = '실습 결과 보존용. 실습용. [sso-user-sync]';
-- CREATE SCHEMA IF NOT EXISTS KSM_KEEP_DB.ARCHIVE;
--
-- CREATE TABLE IF NOT EXISTS KSM_KEEP_DB.ARCHIVE.HR_SYNC_AUDIT_LOG AS
--   SELECT * FROM KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG;
-- CREATE TABLE IF NOT EXISTS KSM_KEEP_DB.ARCHIVE.HR_SECURITY_AUDIT_REPORT AS
--   SELECT * FROM KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT;
--
-- 🔴 보존해도 되는 것 / 안 되는 것
--    보존 가능 : 감사 로그 테이블, 인사 원장 테이블 (데이터일 뿐입니다)
--    보존 금지 : 시큐리티 인티그레이션, 계정 레벨 권한을 가진 역할, EMP_F*** 사용자
--                → 이것들은 **보안 상태**이므로 남기면 안 됩니다
--
-- ⚠️ KSM_KEEP_DB 를 만들었다면 그것도 대장 밖의 객체가 됩니다.
--    더 필요하지 않을 때 DROP DATABASE KSM_KEEP_DB 로 제거하십시오.


-- ##############################################################################
-- PART E. 외부 리소스 및 속성 변경 — 이 실습의 해당 범위
-- ##############################################################################
-- E-1. 기존 객체의 속성 변경 (대장 (b))
--   **이 실습은 기존 Snowflake 객체의 속성을 변경하지 않습니다.**
--   따라서 원복 대상이 없습니다.
--
--   🔴 단 하나의 예외가 03_ 문서에 **주석 상태**로 존재합니다.
--      ALTER USER <사용자> SET SSO_LOGIN_ONLY = TRUE
--      → 이것은 **로그인 경로 변경**이며 더미 IdP 상태에서 활성화하면
--        해당 사용자가 로그인할 수 없게 됩니다(계정 잠금).
--        주석을 유지하는 것이 안전하며, 만약 실행했다면 아래로 원복하십시오.
--
-- ALTER USER <사용자명> UNSET SSO_LOGIN_ONLY;
--   (실습 전 값이 명시적 FALSE 였다면 SET SSO_LOGIN_ONLY = FALSE 로 원복)
--
-- E-2. Snowflake 외부 리소스
--   이 실습은 Snowflake 안에서만 수행되며 **외부 시스템을 변경하지 않습니다.**
--   더미 인증서·공개키를 사용하므로 Azure Portal 이나 모바일 백엔드에
--   실제 설정을 만들지 않습니다.
--
--   ⚠️ 다만 실습을 확장해 **실제 Entra ID 테넌트와 연결했다면** 아래가 남습니다.
--      · Entra ID 의 Snowflake Enterprise App (SAML 설정)
--      · Entra ID 프로비저닝 탭에 등록한 SCIM URL 과 토큰
--      · 모바일 백엔드에 배포한 RSA 키페어
--      → Snowflake 정리로는 되돌아가지 않습니다. Azure Portal 에서 직접 제거하십시오.
--
-- E-3. 발급한 자격증명의 사본
--   04_ 에서 SCIM 토큰을 발급했습니다. 인티그레이션 DROP 으로 토큰은 무효화되지만,
--   **토큰을 복사해 다른 곳(메모, 티켓, 채팅)에 붙여 두었다면 그 사본을 폐기하십시오.**
--   ⚠️ 토큰을 SELECT 했다면 **쿼리 이력에 남습니다.** 이력은 삭제할 수 없습니다.


-- ##############################################################################
-- PART F. 정리 완료 검증 — "삭제했다" 가 아니라 "없음을 확인했다"
-- ##############################################################################
-- 아래는 모두 **조회 전용**입니다. 실습 리소스가 없는 상태에서 실행해도 안전합니다.
USE ROLE ACCOUNTADMIN;

-- F-1. 접두사 기반 잔여물 검사 — 모두 0행이어야 합니다
SHOW DATABASES  LIKE 'KSM_%';
--   결과 행 수: ______  (0 이어야 합니다. KSM_KEEP_DB 를 의도적으로 남겼다면 1)

SHOW WAREHOUSES LIKE 'KSM_%';
--   결과 행 수: ______  (0)

SHOW ROLES LIKE 'KSM_%';
--   결과 행 수: ______  (0)

SHOW ROLES LIKE 'AAD_%';
--   결과 행 수: ______  (0 — AAD_PROVISIONING_ROLE 이 남지 않았는지)

SHOW USERS LIKE 'EMP_F%';
--   결과 행 수: ______  (0)

SHOW USERS LIKE 'KSM_%';
--   결과 행 수: ______  (0)

-- F-2. 시큐리티 인티그레이션 — 실습 객체 3종이 없어야 합니다
SHOW INTEGRATIONS;
--   ENTRA_ID_SAML_INTEGRATION    존재? ______  (없어야 합니다)
--   AAD_SCIM_INTEGRATION         존재? ______  (없어야 합니다)
--   MOBILE_APP_OAUTH_INTEGRATION 존재? ______  (없어야 합니다)
--
-- ⚠️ 이 계정에 원래 있던 인티그레이션은 남아 있는 것이 정상입니다.
--    95_실습전_기준선.md 에 기록한 목록과 대조하십시오.

-- F-3. 태스크 잔여 검사
SHOW TASKS IN ACCOUNT;
--   TASK_SYNC_HR_TO_SNOWFLAKE_USERS / TASK_DAILY_MIDNIGHT_HR_AUDIT
--   존재? ______  (없어야 합니다)

-- F-4. 기준선 대조 — 95_ 에 기록한 값과 비교하십시오
SHOW DATABASES;
--   현재 개수: ______   / 실습 전 개수(95_ 기록): ______   → 일치? ______
SHOW WAREHOUSES;
--   현재 개수: ______   / 실습 전 개수(95_ 기록): ______   → 일치? ______
SHOW ROLES;
--   현재 개수: ______   / 실습 전 개수(95_ 기록): ______   → 일치? ______
SHOW USERS;
--   현재 개수: ______   / 실습 전 개수(95_ 기록): ______   → 일치? ______
SHOW INTEGRATIONS;
--   현재 개수: ______   / 실습 전 개수(95_ 기록): ______   → 일치? ______

-- F-5. 정리 체크리스트
-- [ ] **태스크 2개 — SUSPEND + DROP 완료 (자동 계정 비활성화 중단)**
-- [ ] **AAD_SCIM_INTEGRATION — DROP 완료 (SCIM 토큰 무효화)**
-- [ ] **ENTRA_ID_SAML_INTEGRATION — DROP 완료 (로그인 페이지 원복)**
-- [ ] MOBILE_APP_OAUTH_INTEGRATION — DROP 완료
-- [ ] DATABASE KSM_ENTERPRISE_DB — DROP 완료
-- [ ] **WAREHOUSE KSM_AUTH_WH — DROP 완료 (컴퓨트 비용)**
-- [ ] 사용자 KSM_OFFICE_SAMPLE_USER / KSM_MOBILE_CHATBOT_SVC_USER — DROP 완료
-- [ ] **사용자 EMP_F*** 전량 — DROP 완료 (프로시저가 만든 것)**
-- [ ] **역할 5종 — DROP 완료 (계정 레벨 권한 위임 소멸)**
-- [ ] 발급한 SCIM 토큰 사본 폐기 완료
-- [ ] 95_실습전_기준선.md 와 대조해 차이 없음 확인 → 96_실습후_대조.md 에 기록
-- [ ] (실제 Entra ID 를 연결했다면) Azure Portal 측 설정 제거 완료

SELECT '정리 완료: 위 F-1 ~ F-4 결과를 96_실습후_대조.md 에 기록하십시오.' AS STATUS;
