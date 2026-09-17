-- ==============================================================================
-- [Step 7] 동기화 시나리오 테스트 및 실습 환경 정리 (Validation & Cleanup)
-- 목적: 신규 입사, 부서 이동, 퇴사(Offboarding) 시나리오를 시뮬레이션하고 
--       자동 프로비저닝 결과를 검증한 후 환경을 정리할 수 있도록 합니다.
-- ==============================================================================
-- ==============================================================================
-- 검증 상태 (2026-09-16, 계정 LJ20513 에서 실제 실행):
--   ✅ 시나리오 1 (신규 입사 EMP_F004) — 실제 실행 검증 완료. 사용자 4명 자동 생성 확인
--   ✅ 시나리오 2 (퇴사 EMP_F001) — 실제 실행 검증 완료. disabled=true 확인
--   ❌ 시나리오 3 (자정 감사) — 원본 코드로는 **실패**했다.
--      "SQL compilation error: invalid identifier 'R.EMP_NAME'"
--      EXCEPTION 핸들러가 오류를 삼켜 정상처럼 보였고 감사 보고서는 0행이었다.
--      5번 문서 [결함 2] 로 정정했고, 수정형은 실제 실행으로 검증했다(1명 조치).
--   ✅ 7.4 정리 절차 전체 — 실제 실행 검증 완료.
--      정리 후 기준선과 대조: 사용자 1명 / 역할 7개 / 통합 2개 / KSM_ DB·WH 0건 — 일치
--
-- ⚠️ 태스크와 수동 CALL 의 경합 — 시나리오를 결정적으로 검증하려면 먼저 SUSPEND 하십시오
--    5번 [결함 1] 정정으로 스트림이 소비되므로 중복 재처리는 사라졌습니다. 다만 이제는
--    반대 방향의 경합이 생깁니다. 원장을 변경한 뒤 5분 주기 태스크가 먼저 발동하면
--    **태스크가 스트림을 소비**해 버리고, 이 문서의 수동 CALL 은
--    '스트림에 변경이 없어 처리할 건이 없습니다' 를 반환합니다.
--    계정 상태는 올바르지만 관찰하려던 반환값을 볼 수 없습니다.
--    따라서 7.0 에서 태스크를 SUSPEND 한 뒤 시나리오를 진행하십시오.
--
-- ⚠️ 7.4 는 "선택 실행" 으로 표기되어 있으나 실질적으로 **필수**입니다.
--    RESUME 된 태스크 2개와 SCIM 토큰, 계정 레벨 권한이 남습니다.
-- ==============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE KSM_AUTH_WH;
USE DATABASE KSM_ENTERPRISE_DB;
USE SCHEMA BRONZE;

-- ==============================================================================
-- 7.0 시나리오 검증 전 태스크 일시 중지 (결정적 관찰을 위해 필수)
-- ==============================================================================
-- 태스크가 먼저 스트림을 소비하면 아래 수동 CALL 이 0건을 반환해
-- 시나리오별 반환값을 관찰할 수 없습니다.
ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS SUSPEND;

-- 현재 스트림에 미소비 변경이 남아 있는지 확인합니다 (FALSE 에서 출발하는 것이 좋습니다)
SELECT SYSTEM$STREAM_HAS_DATA('KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM') AS HAS_DATA;
--   결과: ______


-- ==============================================================================
-- 7.1 [시나리오 1] 신규 현장 직원 입사 (EMP_F004 추가)
-- ==============================================================================
INSERT INTO KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER 
(EMP_ID, EMP_NAME, DEPT_NAME, FACTORY_CODE, JOB_TITLE, EMPLOYMENT_STATUS, SNOWFLAKE_ROLE, PHONE_NUMBER)
VALUES 
('EMP_F004', '정신입', '반도체 2공장 조립반', 'FACTORY_B', '조립원', 'ACTIVE', 'KSM_FACTORY_WORKER_ROLE', '010-4567-8901');

-- 스트림 변경 데이터 확인
SELECT * FROM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM;

-- 동기화 프로시저 실행 (실제 운영 시에는 Serverless Task가 자동 수행)
CALL KSM_ENTERPRISE_DB.OPS.SP_SYNC_HR_EMPLOYEES();

-- 검증: 신규 사용자 EMP_F004 계정 생성 및 역할 부여 확인
SHOW USERS LIKE 'EMP_F004';
SHOW GRANTS TO USER EMP_F004;


-- ==============================================================================
-- 7.2 [시나리오 2] 현장 직원 퇴사 발생 (EMP_F001 퇴사 처리)
-- ==============================================================================
-- 인사 DB에서 퇴사(RESIGNED)로 상태 변경
UPDATE KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER 
SET EMPLOYMENT_STATUS = 'RESIGNED',
    LAST_UPDATED_AT = CURRENT_TIMESTAMP()
WHERE EMP_ID = 'EMP_F001';

-- 스트림 변경 감지 확인
SELECT * FROM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM;

-- 동기화 프로시저 실행
CALL KSM_ENTERPRISE_DB.OPS.SP_SYNC_HR_EMPLOYEES();

-- 검증: EMP_F001 계정이 DISABLED = true 상태로 즉각 차단되었는지 확인
SHOW USERS LIKE 'EMP_F001';


-- ==============================================================================
-- 7.2-1 [시나리오 2-2] 인사 원장에서 행이 삭제된 경우 (하드 삭제 오프보딩)
-- ==============================================================================
-- 퇴사를 '상태 변경' 이 아니라 '레코드 삭제' 로 처리하는 조직을 위한 경로입니다.
-- 순수 DELETE 는 스트림에 METADATA$ACTION='DELETE' 1행만 남기므로,
-- INSERT 행만 보는 로직으로는 잡히지 않습니다 (5번 [결함 3]).
DELETE FROM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER WHERE EMP_ID = 'EMP_F003';

-- 스트림에 DELETE 액션 1행만 생긴 것을 확인합니다
SELECT EMP_ID, METADATA$ACTION AS ACT, METADATA$ISUPDATE AS ISUPD
FROM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM;
--   ACT = ______ / ISUPD = ______   (DELETE / FALSE 를 기대합니다)

CALL KSM_ENTERPRISE_DB.OPS.SP_SYNC_HR_EMPLOYEES();

-- 검증: EMP_F003 계정이 차단되었는지 확인합니다
SHOW USERS LIKE 'EMP_F003';
--   disabled = ______   (true 를 기대합니다)

-- 감사 로그에 하드 삭제 경로로 기록되었는지 확인합니다
SELECT EMP_ID, ACTION_TYPE, STATUS
FROM KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG
WHERE EMP_ID = 'EMP_F003' ORDER BY LOG_ID;
--   ACTION_TYPE 에 DISABLE_USER_HARD_DELETE 가 있어야 합니다


-- ==============================================================================
-- 7.2-2 [확인] 스트림 소비로 재실행이 차단되는지 (5번 [결함 1] 정정 확인)
-- ==============================================================================
-- 방금 소비했으므로 곧바로 다시 호출하면 처리할 건이 없어야 합니다.
CALL KSM_ENTERPRISE_DB.OPS.SP_SYNC_HR_EMPLOYEES();
--   반환: ______   ('스트림에 변경이 없어 처리할 건이 없습니다' 를 기대합니다)

SELECT SYSTEM$STREAM_HAS_DATA('KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM') AS HAS_DATA;
--   결과: ______   (FALSE 를 기대합니다)

-- 감사 로그가 중복 누적되지 않았는지 확인합니다
SELECT EMP_ID, COUNT(*) AS ROWS_PER_EMP
FROM KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG GROUP BY EMP_ID ORDER BY EMP_ID;


-- ==============================================================================
-- 7.3 [시나리오 3] 매일 자정 퇴사자 잔존 점검 및 보안 감사 프로시저 수동 실행
-- ==============================================================================
CALL KSM_ENTERPRISE_DB.OPS.SP_AUDIT_DORMANT_AND_RESIGNED_USERS();

-- 감사 보고서 및 로그 확인
SELECT * FROM KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT ORDER BY REPORTED_AT DESC;
SELECT * FROM KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG ORDER BY LOG_ID DESC;

SHOW USERS LIKE 'EMP_F%';


-- ==============================================================================
-- 7.4 [선택 실행] 실습 리소스 정리 및 초기화 (Cleanup)
-- ==============================================================================
-- 1. Serverless Task 일시 중지 및 삭제 (비용 발생 방지)
ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS SUSPEND;
DROP TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS;

ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT SUSPEND;
DROP TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT;

-- 2. Security Integration 삭제
DROP SECURITY INTEGRATION IF EXISTS ENTRA_ID_SAML_INTEGRATION;
DROP SECURITY INTEGRATION IF EXISTS AAD_SCIM_INTEGRATION;
DROP SECURITY INTEGRATION IF EXISTS MOBILE_APP_OAUTH_INTEGRATION;

-- 3. 실습용 테스트 사용자 삭제
DROP USER IF EXISTS KSM_OFFICE_SAMPLE_USER;
DROP USER IF EXISTS KSM_MOBILE_CHATBOT_SVC_USER;
DROP USER IF EXISTS EMP_F001;
DROP USER IF EXISTS EMP_F002;
DROP USER IF EXISTS EMP_F003;
DROP USER IF EXISTS EMP_F004;

-- 4. 실습용 데이터베이스 및 웨어하우스 삭제
DROP DATABASE IF EXISTS KSM_ENTERPRISE_DB;
DROP WAREHOUSE IF EXISTS KSM_AUTH_WH;

-- 5. 실습용 역할(Role) 삭제
DROP ROLE IF EXISTS KSM_HR_SYNC_ADMIN;
DROP ROLE IF EXISTS AAD_PROVISIONING_ROLE;
DROP ROLE IF EXISTS KSM_OFFICE_USER_ROLE;
DROP ROLE IF EXISTS KSM_FACTORY_WORKER_ROLE;
DROP ROLE IF EXISTS KSM_MOBILE_CHATBOT_SERVICE_ROLE;

SELECT 'Cleanup Completed: All resources removed successfully' AS STATUS;
