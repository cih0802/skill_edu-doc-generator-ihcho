/*
title: 사용자·권한 자동 동기화 프로시저 및 태스크
step: 06
type: sql
summary: 스트림을 소비해 계정을 생성·갱신·차단하는 동기화 프로시저와 자정 감사 프로시저를 만들고 서버리스 태스크로 스케줄한다. 결함 3건의 정정형이 반영되어 있다.
requires: 05_현장직_인사DB_테이블_및_스트림.sql
next: 07_모바일앱_External_OAuth_설정.sql
*/

-- ==============================================================================
-- [Step 06] 인사 DB 기반 사용자/권한 자동 동기화 프로시저 및 태스크 (Automated Provisioning & Audit)
-- 목적: 1) Stream에 감지된 인사 변경사항(입사, 부서이동, 퇴사)을 분석하여 Snowflake 계정을 실시간 자동 관리합니다.
--       2) 매일 자정(00:00 KST)에 퇴사자/미사용 계정 잔존 여부를 전수 점검하는 자동 감사(Audit) 파이프라인과
--          Cortex Automation 스케줄링 등록을 수행합니다.
-- ==============================================================================
-- 검증 상태
--
-- [2026-09-17 재검증 — 🔴 결함 3건을 새로 발견해 정정함]
--   계정 LJ20513 / AWS_AP_NORTHEAST_1 / Enterprise 에서 실제 실행
--
--   🔴 [결함 4] SP_AUDIT 에 식별자 검증 게이트가 없었다 → ✅ 정정
--     06.1 SP_SYNC 에는 RLIKE 게이트가 있는데 06.3 SP_AUDIT 에는 없었다.
--     같은 자료가 같은 주입 위험에 대해 한쪽만 방어하고 있었다.
--     정정 검증 — 인사 원장에 주입형 사번을 넣고 CALL 한 실측 결과:
--       'EMP_F0X3 SET DEFAULT_ROLE=ACCOUNTADMIN --' → REJECTED_UNSAFE_IDENTIFIER
--                                                     / ACTION_TAKEN = SKIPPED
--       'OBrien-X' (하이픈)                        → REJECTED_UNSAFE_IDENTIFIER
--       'EMP_F001','EMP_F002' (정상)               → AUTO_DISABLED
--     CALL 후 SHOW USERS LIKE 'EMP_F%' → **0행**. 주입으로 생성된 계정 없음
--
--   🔴 [결함 5] `SQLERRM` 을 콜론 없이 써서 감사 로그 INSERT 자체가 실패했다 → ✅ 정정
--     06.1 SP_SYNC 의 핸들러가 `VALUES (..., SQLERRM)` 이었다.
--     실측 오류: SQL compilation error: invalid identifier 'SQLERRM'
--     즉 "실패를 감사 로그에 남긴다"는 방어 설계가 **전혀 동작하지 않았다.**
--     정정: `:SQLERRM` 으로 바인드. 별도 익명 블록으로 검증한 결과
--     `:SQLERRM` 은 정상 기록됨(예: 'Division by zero' 행이 실제로 INSERT 됨)
--     ⚠️ 정상 경로 실행으로는 절대 드러나지 않는 결함이다. 핸들러를 실행시켜야 한다
--
--   🔴 [결함 6] SP_AUDIT 이 실패를 어디에도 기록하지 않았다 → ✅ 정정
--     이전 판은 오류를 문자열로 RETURN 만 했다. 자정 자동 실행이므로 아무도
--     그 문자열을 보지 않는다. 감사 테이블 INSERT 를 추가했다
--
--   ⚠️ [발견된 사각지대 — 정정 대상이 아니라 한계] EXCEPTION 핸들러가
--     `DECLARE` 절 커서의 테이블 부재를 잡지 못한다. 실측: HR_EMPLOYEE_MASTER 를
--     이름 변경한 뒤 CALL → 'Table … does not exist' 가 그대로 올라오고
--     감사 테이블 FAILED 행 **0건**. 문서에 이 사실을 명시했다
--
--   ✅ SP_SYNC_HR_EMPLOYEES / SP_AUDIT 재생성 — 실제 실행 검증 완료
--   ✅ 정리 후 잔여물 0 — SHOW DATABASES/USERS LIKE 패턴 검색으로 확인
--
-- [이전 회차(2026-09-16) 검증 — 그대로 유효]
--   ✅ SP_SYNC_HR_EMPLOYEES(정정형) 생성 및 CALL — 실제 실행 검증 완료
--      1회차: '스트림 3행 소비 / 직원 3명 처리 / 0명 보류', 사용자 3명 생성
--   ✅ 스트림 소비로 재실행이 차단되는 설계 — 실제 실행 검증 완료
--      2회차 CALL: '스트림에 변경이 없어 처리할 건이 없습니다',
--      SYSTEM$STREAM_HAS_DATA = FALSE, 감사 로그 3행 유지(중복 0)
--   ✅ 순수 DELETE 오프보딩 — 실제 실행 검증 완료
--      EMP_F003 행 DELETE → CALL → SHOW USERS: disabled = true,
--      감사 로그 ACTION_TYPE = DISABLE_USER_HARD_DELETE
--   ✅ UPDATE(DELETE+INSERT 쌍)을 하드 삭제로 오판하지 않음 — 실제 실행 검증 완료
--      EMP_F001 → RESIGNED : DISABLE_USER_OFFBOARDING (disabled = true)
--      EMP_F002 → 부서만 변경(ACTIVE 유지) : SYNC_ACTIVE_USER (disabled = false 유지)
--   ✅ 부서이동이 DISPLAY_NAME 에 반영됨 — 실제 실행 검증 완료
--   ✅ 미정의 상태 방어 — EMPLOYMENT_STATUS = 'ON_LEAVE' → SKIPPED_UNKNOWN_STATUS
--   ✅ TASK_SYNC_HR_TO_SNOWFLAKE_USERS EXECUTE TASK — 실제 실행 검증 완료
--      1회차 STATE = SUCCEEDED (EMP_F004 생성, EMP_F005 보류)
--      2회차 STATE = SKIPPED / ERROR_CODE 0040003
--      'Conditional expression for task evaluated to false' → 컴퓨트 미사용
--
-- 🔴 이전 판에서 발견되어 정정한 결함 1~3 (모두 실제 실행으로 재현 및 정정 확인)
--
--   [결함 1] 스트림이 소비되지 않아 태스크가 같은 건을 영구 반복 처리했다 → ✅ 정정
--     원인. 프로시저가 스트림을 커서 SELECT 로만 읽었다. Snowflake Stream 의 offset 은
--           **그 Stream 을 소비하는 DML** 안에서만 전진한다. 조회는 offset 을 움직이지 않는다.
--     구 판 재현: CALL 2회 → 매번 '4건 처리', SYSTEM$STREAM_HAS_DATA 계속 TRUE,
--           HR_SYNC_AUDIT_LOG 4행 → 8행 중복 누적(EMP_F002 2행).
--     정정. 아래 06.0 의 버퍼 테이블에 INSERT ... SELECT FROM <stream> 으로 **먼저 소비**한 뒤
--           버퍼를 배치 단위로 처리한다. 소비를 처리보다 앞에 두는 것이 요점이다.
--     정정 검증: 2회차 CALL 이 0건, HAS_DATA = FALSE, 태스크 2회차가 SKIPPED.
--
--   [결함 2] 자정 감사 프로시저가 항상 실패했다 (조용한 실패) → ✅ 정정
--     구: INSERT ... VALUES (..., '... (' || r.EMP_NAME || ')', ...)
--     오류: SQL compilation error: invalid identifier 'R.EMP_NAME'
--     커서 루프 레코드 필드는 SQL 문 안에서 직접 참조할 수 없다. 지역 변수에 담아
--     `:변수` 로 바인드해야 한다.
--     ⚠️ 위 [결함 5] 는 이것과 **같은 뿌리**의 별개 사례다. 결함 2 를 고칠 때
--        `SQLERRM` 도 같은 규칙을 따라야 했는데 놓쳤다
--
--   [결함 3] 인사 원장에서 행이 DELETE 되면 계정이 차단되지 않았다 → ✅ 정정
--     원인. 커서가 WHERE METADATA$ACTION = 'INSERT' 로 필터했다. 순수 DELETE 는
--           스트림에 DELETE 액션 1행만 남기므로 무시되어 계정이 활성 잔존했다.
--     정정. 아래 06.1 은 버퍼를 EMP_ID 로 집계해 **INSERT 행이 하나도 없는 사번**을
--           하드 삭제(오프보딩)로 판정한다.
--
-- 📌 스트림 액션 실측 (05_ 에서 확인)
--     INSERT → INSERT 1행 (ISUPDATE=FALSE)
--     UPDATE → DELETE + INSERT 2행 (ISUPDATE=TRUE)
--     DELETE → DELETE 1행 (ISUPDATE=FALSE)
--   이 표가 결함 3 정정 로직(= INSERT 행 존재 여부로 하드 삭제를 판별)의 근거다.
--
-- ⚠️ 미검증: Cortex Automation(06.5) 등록은 CLI 영역이므로 이 세션 범위 외.
-- ⚠️ 미검증: 5분 주기 자연 발동. EXECUTE TASK 로 트리거해 확인했다.
-- ⚠️ 미검증: 2026-09-17 재검증에서는 스트림·태스크 전체 시나리오를 다시 돌리지
--    않았습니다. 이번 개선이 건드린 것은 두 프로시저의 게이트·핸들러이므로
--    그 부분만 집중 재검증했습니다. 위 2026-09-16 결과가 유효합니다.
-- ==============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE KSM_AUTH_WH;
USE DATABASE KSM_ENTERPRISE_DB;
USE SCHEMA OPS;

-- ==============================================================================
-- 06.0 스트림 소비 버퍼 테이블 (OPS 스키마) — [결함 1] 정정의 핵심
-- ==============================================================================
-- 스트림 offset 을 전진시키는 DML 의 대상이다. 이 테이블이 없으면
-- 프로시저는 스트림을 소비할 수 없고 태스크가 같은 건을 영구 재처리한다.
-- 배치별 소비 이력이 남으므로 "무엇이 언제 소비되었는가"의 감사 근거도 된다.

CREATE OR REPLACE TABLE KSM_ENTERPRISE_DB.OPS.HR_STREAM_BUFFER (
    BATCH_ID          VARCHAR(64)   NOT NULL COMMENT '1회 CALL 이 소비한 묶음 식별자 (UUID)',
    EMP_ID            VARCHAR(50)   COMMENT '사번',
    EMP_NAME          VARCHAR(100)  COMMENT '성명',
    DEPT_NAME         VARCHAR(100)  COMMENT '소속 부서',
    EMPLOYMENT_STATUS VARCHAR(20)   COMMENT '재직 상태',
    SNOWFLAKE_ROLE    VARCHAR(100)  COMMENT '매핑될 Snowflake 역할',
    ACTION_TYPE       VARCHAR(20)   COMMENT 'METADATA$ACTION — INSERT 또는 DELETE',
    IS_UPDATE         BOOLEAN       COMMENT 'METADATA$ISUPDATE — UPDATE 로 인한 쌍이면 TRUE',
    CONSUMED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() COMMENT '소비 시각'
)
COMMENT = 'HR_EMPLOYEE_STREAM 소비 버퍼. 스트림 offset 전진의 근거. 실습용. [sso-user-sync]';

-- ==============================================================================
-- 06.1 인사 동기화 저장 프로시저 (OPS 스키마) — [결함 1]·[결함 3] 정정형
-- ==============================================================================
-- 처리 순서
--   1) 스트림을 버퍼로 INSERT → **여기서 offset 이 전진한다**
--   2) 버퍼를 EMP_ID 로 집계해 사번당 1건의 최종 의도를 만든다
--      · INSERT 행 있음 → 그 값이 변경 후 최종 상태다 (신규/부서이동/퇴사 상태변경)
--      · INSERT 행 없음 → 원장에서 행이 사라진 것이다 → 하드 삭제 오프보딩
--   3) 판정에 따라 계정을 생성·갱신·차단하고 감사 로그를 남긴다

CREATE OR REPLACE PROCEDURE KSM_ENTERPRISE_DB.OPS.SP_SYNC_HR_EMPLOYEES()
RETURNS VARCHAR
LANGUAGE SQL
-- 🔴 절 순서 주의: COMMENT 는 EXECUTE AS 보다 앞에 와야 한다.
COMMENT = '인사 스트림을 소비해 Snowflake 계정을 동기화한다. 실습용. [sso-user-sync]'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_batch_id        VARCHAR DEFAULT UUID_STRING();
    v_consumed        INTEGER DEFAULT 0;
    v_emp_id          VARCHAR;
    v_emp_name        VARCHAR;
    v_dept_name       VARCHAR;
    v_status          VARCHAR;
    v_role            VARCHAR;
    v_display         VARCHAR;
    v_has_insert      INTEGER;
    v_sql             VARCHAR;
    v_action_label    VARCHAR;
    v_processed_count INTEGER DEFAULT 0;
    v_skipped_count   INTEGER DEFAULT 0;

    -- 버퍼를 사번 단위로 집계한다. INSERT 행이 있으면 그 값을 우선 채택하고,
    -- 없으면(순수 DELETE) DELETE 행의 값으로 사번·성명을 확보한다.
    c_batch CURSOR FOR
        SELECT
            EMP_ID,
            MAX(IFF(ACTION_TYPE = 'INSERT', 1, 0))                                                    AS HAS_INSERT,
            COALESCE(MAX(IFF(ACTION_TYPE = 'INSERT', EMP_NAME, NULL)),          MAX(EMP_NAME))          AS EMP_NAME,
            COALESCE(MAX(IFF(ACTION_TYPE = 'INSERT', DEPT_NAME, NULL)),         MAX(DEPT_NAME))         AS DEPT_NAME,
            COALESCE(MAX(IFF(ACTION_TYPE = 'INSERT', EMPLOYMENT_STATUS, NULL)), MAX(EMPLOYMENT_STATUS)) AS EMPLOYMENT_STATUS,
            COALESCE(MAX(IFF(ACTION_TYPE = 'INSERT', SNOWFLAKE_ROLE, NULL)),    MAX(SNOWFLAKE_ROLE))    AS SNOWFLAKE_ROLE
        FROM KSM_ENTERPRISE_DB.OPS.HR_STREAM_BUFFER
        WHERE BATCH_ID = ?
        GROUP BY EMP_ID;
BEGIN
    -- [1] 스트림 소비 — DML 이므로 offset 이 전진한다. 반드시 처리보다 먼저 한다.
    INSERT INTO KSM_ENTERPRISE_DB.OPS.HR_STREAM_BUFFER
        (BATCH_ID, EMP_ID, EMP_NAME, DEPT_NAME, EMPLOYMENT_STATUS, SNOWFLAKE_ROLE, ACTION_TYPE, IS_UPDATE)
    SELECT :v_batch_id, EMP_ID, EMP_NAME, DEPT_NAME, EMPLOYMENT_STATUS, SNOWFLAKE_ROLE,
           METADATA$ACTION, METADATA$ISUPDATE
    FROM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM;

    v_consumed := SQLROWCOUNT;

    IF (v_consumed = 0) THEN
        RETURN '인사 DB 동기화: 스트림에 변경이 없어 처리할 건이 없습니다.';
    END IF;

    -- [2] 배치 처리
    OPEN c_batch USING (v_batch_id);
    FOR rec IN c_batch DO
        v_emp_id     := rec.EMP_ID;
        v_emp_name   := rec.EMP_NAME;
        v_dept_name  := rec.DEPT_NAME;
        v_status     := rec.EMPLOYMENT_STATUS;
        v_role       := rec.SNOWFLAKE_ROLE;
        v_has_insert := rec.HAS_INSERT;

        -- 동적 SQL 의 식별자 자리에 들어가는 값은 바인드할 수 없으므로 패턴을 검사한다.
        -- 인사 원장이 오염되었을 때 임의 DDL 이 실행되는 것을 막는 안전장치다.
        IF (NOT RLIKE(v_emp_id, '[A-Za-z0-9_]{1,50}')
            OR NOT RLIKE(v_role, '[A-Za-z0-9_]{1,100}')) THEN
            INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG
                (EMP_ID, ACTION_TYPE, EXECUTED_QUERY, STATUS, ERROR_MESSAGE)
            VALUES (:v_emp_id, 'REJECTED_UNSAFE_IDENTIFIER', NULL, 'FAILED',
                    '식별자가 허용 패턴을 벗어나 동적 SQL 생성을 거부했습니다.');
            v_skipped_count := v_skipped_count + 1;
            CONTINUE;
        END IF;

        -- 문자열 리터럴 자리의 홑따옴표는 이스케이프한다.
        v_display := REPLACE(v_emp_name, '''', '''''') || ' (' || REPLACE(v_dept_name, '''', '''''') || ')';

        -- [상황 0] 🔴 [결함 3] 정정 — 원장에서 행이 사라졌다 (순수 DELETE)
        IF (v_has_insert = 0) THEN
            v_sql := 'ALTER USER IF EXISTS ' || v_emp_id || ' SET DISABLED = TRUE, PASSWORD = NULL';
            EXECUTE IMMEDIATE :v_sql;
            v_action_label := 'DISABLE_USER_HARD_DELETE';
            INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG
                (EMP_ID, ACTION_TYPE, EXECUTED_QUERY, STATUS)
            VALUES (:v_emp_id, :v_action_label, :v_sql, 'SUCCESS');

        -- [상황 1] 재직 중 (신규 입사 또는 부서/역할 변경)
        ELSEIF (v_status = 'ACTIVE') THEN
            v_sql := 'CREATE USER IF NOT EXISTS ' || v_emp_id
                     || ' LOGIN_NAME = ''' || v_emp_id || ''''
                     || ' DISPLAY_NAME = ''' || v_display || ''''
                     || ' DEFAULT_ROLE = ' || v_role
                     || ' DEFAULT_WAREHOUSE = KSM_AUTH_WH'
                     || ' DISABLED = FALSE'
                     || ' COMMENT = ''현장직 인사 DB 자동 동기화 사용자. 실습용. [sso-user-sync]''';
            EXECUTE IMMEDIATE :v_sql;

            -- CREATE USER IF NOT EXISTS 는 기존 계정을 갱신하지 않는다.
            -- 부서이동·복직·역할 변경을 반영하려면 ALTER 가 반드시 뒤따라야 한다.
            v_sql := 'ALTER USER ' || v_emp_id || ' SET DISABLED = FALSE'
                     || ', DEFAULT_ROLE = ' || v_role
                     || ', DISPLAY_NAME = ''' || v_display || '''';
            EXECUTE IMMEDIATE :v_sql;

            v_sql := 'GRANT ROLE ' || v_role || ' TO USER ' || v_emp_id;
            EXECUTE IMMEDIATE :v_sql;

            v_action_label := 'SYNC_ACTIVE_USER';
            INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG
                (EMP_ID, ACTION_TYPE, EXECUTED_QUERY, STATUS)
            VALUES (:v_emp_id, :v_action_label, :v_sql, 'SUCCESS');

        -- [상황 2] 퇴사(RESIGNED) 또는 정직/휴직(SUSPENDED)
        ELSEIF (v_status IN ('RESIGNED', 'SUSPENDED')) THEN
            v_sql := 'ALTER USER IF EXISTS ' || v_emp_id || ' SET DISABLED = TRUE, PASSWORD = NULL';
            EXECUTE IMMEDIATE :v_sql;
            v_action_label := 'DISABLE_USER_OFFBOARDING';
            INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG
                (EMP_ID, ACTION_TYPE, EXECUTED_QUERY, STATUS)
            VALUES (:v_emp_id, :v_action_label, :v_sql, 'SUCCESS');

        -- [상황 3] 정의되지 않은 상태 — 조용히 넘기지 않고 기록한 뒤 보류한다.
        --   상태값이 늘어났는데 코드가 따라가지 못하는 상황을 드러내기 위한 분기다.
        ELSE
            v_action_label := 'SKIPPED_UNKNOWN_STATUS';
            INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG
                (EMP_ID, ACTION_TYPE, EXECUTED_QUERY, STATUS, ERROR_MESSAGE)
            VALUES (:v_emp_id, :v_action_label, NULL, 'FAILED',
                    '알 수 없는 EMPLOYMENT_STATUS: ' || :v_status);
            v_skipped_count := v_skipped_count + 1;
            CONTINUE;
        END IF;

        v_processed_count := v_processed_count + 1;
    END FOR;
    CLOSE c_batch;

    RETURN '인사 DB 동기화 완료: 스트림 ' || v_consumed || '행 소비 / 직원 '
           || v_processed_count || '명 처리 / ' || v_skipped_count || '명 보류 (batch '
           || v_batch_id || ')';
EXCEPTION
    WHEN OTHER THEN
        -- ⚠️ 이 핸들러는 오류를 삼켜 정상 반환처럼 보이게 만든다. 감사 로그에 남기는 것이
        --    실패를 드러내는 유일한 경로다. 운영에서는 별도 알림을 반드시 추가하십시오.
        --    또한 스트림은 이미 소비되었으므로 실패한 배치는 BATCH_ID 로 버퍼에서
        --    재처리해야 한다 — 스트림에서 다시 읽을 수는 없다.
        --
        -- 🔴🔴 2026-09-17 정정 — `SQLERRM` 을 `:SQLERRM` 으로 바꿨습니다 🔴🔴
        --   이전 판은 `VALUES (..., SQLERRM)` 로 **콜론 없이** 썼습니다.
        --   Snowflake Scripting 에서 `SQLERRM` 을 **SQL 문 안에서** 쓸 때는
        --   반드시 바인드해야 합니다. 콜론이 없으면 컬럼 식별자로 해석되어
        --   실측 오류: SQL compilation error: invalid identifier 'SQLERRM'
        --
        --   그 결과 **감사 로그를 남기려는 이 INSERT 자체가 실패**하고,
        --   핸들러가 처리되지 못한 예외로 터졌습니다.
        --   즉 "실패를 감사 로그에 남긴다"는 이 자료의 방어 설계가
        --   **실제로는 전혀 동작하지 않았습니다.**
        --   ⚠️ 이 결함은 정상 경로 실행만으로는 절대 드러나지 않습니다.
        --      예외를 **의도적으로 일으켜** 핸들러를 실행해 봐야 발견됩니다.
        --      (RETURN 문의 `|| SQLERRM` 은 SQL 문이 아니라 식이므로 콜론 없이도
        --       동작합니다. 그래서 더 헷갈립니다.)
        INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG
            (EMP_ID, ACTION_TYPE, STATUS, ERROR_MESSAGE)
        VALUES (:v_emp_id, 'ERROR', 'FAILED', :SQLERRM);
        RETURN '동기화 중 오류 발생 (batch ' || v_batch_id || '): ' || SQLERRM;
END;
$$;


-- ==============================================================================
-- 06.2 인사 데이터 변경 시에만 자동 구동되는 실시간 Serverless Task 생성 (OPS 스키마)
-- ==============================================================================
CREATE OR REPLACE TASK KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    SCHEDULE = '5 MINUTE'
    COMMENT = '인사 마스터 스트림 감지 시 계정 자동 생성/퇴사 비활성화 동기화 태스크. 실습용. [sso-user-sync]'
    WHEN SYSTEM$STREAM_HAS_DATA('KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM')
    AS
    CALL KSM_ENTERPRISE_DB.OPS.SP_SYNC_HR_EMPLOYEES();

-- 태스크 활성화 (RESUME)
ALTER TASK KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS RESUME;


-- ==============================================================================
-- 06.3 [매일 자정 00:00 KST] 퇴사자/미사용 계정 잔존 전수 점검 및 자동 감사 (SILVER & OPS)
-- ==============================================================================
CREATE OR REPLACE TABLE KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT (
    REPORT_ID NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    AUDIT_TYPE VARCHAR(50) COMMENT 'RESIGNED_VERIFICATION, DORMANT_ACCOUNT, UNMAPPED_USER',
    USER_NAME VARCHAR(100),
    DETAILS VARCHAR(2000),
    ACTION_TAKEN VARCHAR(100) COMMENT 'AUTO_DISABLED, FLAGGED_FOR_REVIEW',
    REPORTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = '매일 자정 정기 실행되는 계정 보안 및 퇴사자 잔존 감사 보고서. 실습용. [sso-user-sync]';

CREATE OR REPLACE PROCEDURE KSM_ENTERPRISE_DB.OPS.SP_AUDIT_DORMANT_AND_RESIGNED_USERS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_user_name VARCHAR;
    v_emp_name  VARCHAR;   -- 🔴 [결함 2] 커서 필드를 SQL 문에 직접 쓸 수 없어 지역 변수로 받는다
    v_details   VARCHAR;
    v_sql VARCHAR;
    v_fixed_count INT DEFAULT 0;
    
    -- BRONZE.HR_EMPLOYEE_MASTER 상 'RESIGNED'(퇴사)이나 혹시 활성화 상태로 남아있는 계정 전수 점검
    c_resigned CURSOR FOR
        SELECT EMP_ID, EMP_NAME, DEPT_NAME
        FROM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER
        WHERE EMPLOYMENT_STATUS = 'RESIGNED';
BEGIN
    OPEN c_resigned;
    FOR r IN c_resigned DO
        v_user_name := r.EMP_ID;
        v_emp_name  := r.EMP_NAME;

        -- 🔴🔴 식별자 검증 게이트 — SP_SYNC_HR_EMPLOYEES 와 동일한 방어 🔴🔴
        --   아래 v_sql 은 EMP_ID 를 **문자열 결합**으로 조립합니다.
        --   식별자(사용자명) 자리에는 바인드 변수를 쓸 수 없으므로 결합이
        --   불가피하고, 그 값이 인사 원장 테이블에서 오므로 **주입 경로**입니다.
        --   원장에 'FOO SET DEFAULT_ROLE=ACCOUNTADMIN --' 같은 값이 들어오면
        --   의도하지 않은 DDL 이 실행됩니다.
        --
        --   이 게이트가 왜 여기 추가되었는가:
        --   06.1 의 SP_SYNC_HR_EMPLOYEES 에는 RLIKE 게이트가 있었지만
        --   이 프로시저에는 **없었습니다.** 같은 자료가 같은 위험에 대해
        --   한쪽만 방어하고 있었으므로 동일한 게이트를 넣었습니다.
        IF (NOT RLIKE(v_user_name, '[A-Za-z0-9_]{1,50}')) THEN
            INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT
                (AUDIT_TYPE, USER_NAME, DETAILS, ACTION_TAKEN)
            VALUES
                ('REJECTED_UNSAFE_IDENTIFIER', :v_user_name,
                 '식별자가 허용 패턴([A-Za-z0-9_]{1,50})을 벗어나 동적 SQL 생성을 거부했습니다.',
                 'SKIPPED');
            CONTINUE;
        END IF;

        v_details   := '퇴사자 계정 자정 전수 점검 및 차단 완료 (' || REPLACE(v_emp_name, '''', '''''') || ')';

        -- 강제 비활성화 쿼리 실행
        v_sql := 'ALTER USER IF EXISTS ' || v_user_name || ' SET DISABLED = TRUE, PASSWORD = NULL';
        EXECUTE IMMEDIATE :v_sql;

        INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT
            (AUDIT_TYPE, USER_NAME, DETAILS, ACTION_TAKEN)
        VALUES
            ('RESIGNED_VERIFICATION', :v_user_name, :v_details, 'AUTO_DISABLED');

        v_fixed_count := v_fixed_count + 1;
    END FOR;
    CLOSE c_resigned;

    RETURN '자정 계정 보안 감사 완료: 총 ' || v_fixed_count || '명 퇴사/비활성화 상태 검증 및 조치 완료';
EXCEPTION
    WHEN OTHER THEN
        -- 🔴 이 핸들러는 오류를 삼켜 실패를 정상 반환처럼 보이게 만듭니다.
        --    태스크 이력의 STATE = SUCCEEDED 도 신뢰할 수 없게 됩니다.
        --
        -- 🔴 정정 내용: 이전 판은 오류를 **문자열로만 반환**하고 어디에도
        --    기록하지 않았습니다. 자정에 자동 실행되는 태스크이므로
        --    아무도 그 반환값을 보지 않고, 실패가 완전히 은폐되었습니다.
        --    (같은 자료의 SP_SYNC_HR_EMPLOYEES 는 감사 로그 INSERT 를 갖고 있었지만,
        --     그 INSERT 도 `:SQLERRM` 콜론 누락으로 실제로는 실패하고 있었습니다.
        --     두 프로시저 모두 이번에 정정했습니다.)
        --    → 실패를 감사 테이블에 남기도록 고쳤습니다.
        --
        -- 🔴 `:SQLERRM` 의 콜론은 필수입니다. SQL 문(INSERT) 안에서 콜론 없이 쓰면
        --    "invalid identifier 'SQLERRM'" 로 이 INSERT 자체가 실패합니다(실측).
        --    자세한 설명은 06.1 SP_SYNC_HR_EMPLOYEES 의 핸들러 주석 참고.
        --
        -- 🔴🔴 이 핸들러의 사각지대 — 실측으로 확인했습니다 🔴🔴
        --   `EXCEPTION WHEN OTHER` 는 **`BEGIN` 이후에 발생한 오류만** 잡습니다.
        --   `DECLARE` 절의 커서 정의(`c_resigned CURSOR FOR SELECT … FROM
        --   HR_EMPLOYEE_MASTER`)가 참조하는 테이블이 없으면, 그 이름 해석은
        --   `BEGIN` 보다 먼저 일어나므로 **핸들러가 실행되지 않습니다.**
        --
        --   실측(2026-09-17): 원본 테이블 이름을 바꾼 뒤 CALL 하면
        --     SQL compilation error: Table
        --     'KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER' does not exist
        --   가 그대로 올라오고, 감사 테이블에는 FAILED 행이 **0건**이었습니다.
        --
        --   → 따라서 "핸들러가 있으니 실패가 기록된다"고 가정하지 마십시오.
        --     태스크로 자동 실행할 때는 감사 테이블만 보지 말고
        --     TASK_HISTORY 의 ERROR_MESSAGE 도 함께 확인해야 합니다(93_ 런북 참고).
        INSERT INTO KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT
            (AUDIT_TYPE, USER_NAME, DETAILS, ACTION_TAKEN)
        VALUES
            ('AUDIT_PROCEDURE_ERROR', CURRENT_USER(), :SQLERRM, 'FAILED');
        RETURN '자정 보안 감사 중 오류 발생 (감사 로그에 기록됨): ' || SQLERRM;
END;
$$;

-- 🔴 감사 실패를 놓치지 않으려면 아래 쿼리를 정기적으로 확인하십시오.
--    반환 메시지나 태스크 STATE 를 근거로 삼지 마십시오.
-- SELECT * FROM KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT
--  WHERE ACTION_TAKEN IN ('FAILED', 'SKIPPED')
--  ORDER BY REPORTED_AT DESC;
--    운영에서는 이 조건에 Snowflake ALERT + NOTIFICATION INTEGRATION 을
--    붙여 실패를 능동적으로 통보받으십시오(93_ 운영 런북 참고).


-- ==============================================================================
-- 06.4 [스케줄링 등록 1] Snowflake Native Serverless Cron Task (매일 자정 실행 - OPS)
-- ==============================================================================
CREATE OR REPLACE TASK KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    SCHEDULE = 'USING CRON 0 0 * * * Asia/Seoul'
    COMMENT = '매일 자정 퇴사자 잔존 여부 전수 점검 및 계정 강제 차단 감사 태스크. 실습용. [sso-user-sync]'
    AS
    CALL KSM_ENTERPRISE_DB.OPS.SP_AUDIT_DORMANT_AND_RESIGNED_USERS();

ALTER TASK KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT RESUME;


-- ==============================================================================
-- 06.5 [스케줄링 등록 2] Cortex Code Automation CLI를 통한 LLM 자율 점검 등록
-- ==============================================================================
/*
# 터미널(CLI) 실행 예시:
cortex automation create \
    --name "DAILY_HR_SYNC_SECURITY_AUDIT" \
    --schedule "0 0 * * *" \
    --prompt "KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT 테이블을 조회하고, 인사 DB 동기화 실패나 비정상 활성화 계정이 있는지 점검하여 일일 보안 보고서를 생성해줘."
*/

-- 06.6 검증 쿼리
SHOW TASKS IN SCHEMA KSM_ENTERPRISE_DB.OPS;
SELECT * FROM KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT ORDER BY REPORTED_AT DESC;

SELECT 'Step 06 Completed: Real-time Sync Task and Midnight Audit Task Successfully Deployed' AS STATUS;


-- ==============================================================================
-- 🧹 리소스 정리 (이 문서가 만든 것)
-- ==============================================================================
-- 정본은 `98_리소스정리.sql` 입니다.
--   · TABLE      KSM_ENTERPRISE_DB.OPS.HR_STREAM_BUFFER
--   · TABLE      KSM_ENTERPRISE_DB.SILVER.HR_SECURITY_AUDIT_REPORT
--   · PROCEDURE  KSM_ENTERPRISE_DB.OPS.SP_SYNC_HR_EMPLOYEES
--   · PROCEDURE  KSM_ENTERPRISE_DB.OPS.SP_AUDIT_DORMANT_AND_RESIGNED_USERS
--   · TASK       KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS      (RESUME 상태)
--   · TASK       KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT         (RESUME 상태)
--   · (간접)     프로시저가 만드는 사용자 EMP_F***  ← **계정 레벨**
--
-- 🔴 태스크 2개는 RESUME 상태로 남습니다. 서버리스 크레딧을 소비하고,
--    **계정 사용자를 자동으로 DISABLED 시키는 동작을 계속합니다.**
--    실습을 중단할 때는 최소한 SUSPEND 하십시오.
--
-- ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_SYNC_HR_TO_SNOWFLAKE_USERS SUSPEND;
-- ALTER TASK IF EXISTS KSM_ENTERPRISE_DB.OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT SUSPEND;
--
-- ⚠️ 프로시저가 만든 사용자는 DB 를 DROP 해도 사라지지 않습니다 (계정 레벨).
--    98_ 의 사용자 삭제 절을 반드시 수행하십시오.
