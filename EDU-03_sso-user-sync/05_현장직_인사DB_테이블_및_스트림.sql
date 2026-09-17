/*
title: 현장직 인사 DB 테이블 및 CDC 스트림
step: 05
type: sql
summary: 현장직 인사 원장 테이블과 동기화 감사 로그 테이블을 만들고 변경을 캡처하는 스트림을 구성한다. 스트림 액션(INSERT/UPDATE/DELETE) 실측을 포함한다.
requires: 02_RBAC_및_기본보안_환경구성.sql
next: 06_사용자권한_자동동기화_프로시저_및_태스크.sql
*/

-- ==============================================================================
-- [Step 05] 현장직 인사 DB 동기화 테이블 및 CDC Stream 파이프라인
-- 목적: Entra ID가 없는 공장 현장직원의 사번, 근무공장, 직무, 재직상태 데이터를 
--       적재하고 변경 이벤트를 실시간 캡처하는 파이프라인을 구축합니다.
-- ==============================================================================
-- ==============================================================================
-- 검증 상태 (2026-09-16, 계정 LJ20513 에서 실제 실행):
--   ✅ KSM_HR_SYNC_ADMIN 역할로 테이블 2종 + 스트림 생성 — 실제 실행 검증 완료
--   ✅ MERGE 로 현장직 3행 적재 — 실제 실행 검증 완료 (MASTER_ROWS = 3)
--   ✅ 스트림이 INSERT 3건을 감지 — 실제 실행 검증 완료
--      (METADATA$ACTION=INSERT, METADATA$ISUPDATE=FALSE)
--   ✅ UPDATE 는 스트림에 DELETE + INSERT(ISUPDATE=TRUE) 2행을 만든다 — 실제 실행 검증 완료
--   ✅ DELETE 는 스트림에 DELETE 1행만 만든다 — 실제 실행 검증 완료
--
-- 📌 위 스트림 액션 표는 06_ 동기화 로직의 설계 근거입니다. 06_ 문서 상단 참고.
--    · UPDATE 는 DELETE + INSERT 쌍을 만든다 → INSERT 행 존재 여부로 하드 삭제를 판별할 수 있다
--    · 순수 DELETE 는 DELETE 1행만 만든다 → 이 경우가 오프보딩 대상이다
--    이전 판의 06_ 는 METADATA$ACTION='INSERT' 만 필터해 순수 DELETE 를 놓쳤고
--    커서 SELECT 로만 읽어 스트림 offset 을 전진시키지 못했다. 둘 다 정정되었다.
-- ==============================================================================

USE ROLE KSM_HR_SYNC_ADMIN;
USE WAREHOUSE KSM_AUTH_WH;
USE DATABASE KSM_ENTERPRISE_DB;
USE SCHEMA BRONZE;

-- 05.1 사내 인사 DB 마스터 스테이징 테이블 생성 (BRONZE 스키마)
CREATE OR REPLACE TABLE KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER (
    EMP_ID VARCHAR(50) NOT NULL COMMENT '사번 (현장직 고유 식별자, 예: EMP_F001)',
    EMP_NAME VARCHAR(100) NOT NULL COMMENT '성명',
    DEPT_NAME VARCHAR(100) NOT NULL COMMENT '소속 부서 (예: 반도체 1라인 가공팀)',
    FACTORY_CODE VARCHAR(20) NOT NULL COMMENT '근무 공장 코드 (예: FACTORY_A, FACTORY_B)',
    JOB_TITLE VARCHAR(50) NOT NULL COMMENT '직책/직무 (예: 설비보전원, 오퍼레이터, 공정관리자)',
    EMPLOYMENT_STATUS VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT '재직 상태 (ACTIVE: 재직, RESIGNED: 퇴사, SUSPENDED: 휴직)',
    SNOWFLAKE_ROLE VARCHAR(100) NOT NULL DEFAULT 'KSM_FACTORY_WORKER_ROLE' COMMENT '매핑될 Snowflake 역할',
    PHONE_NUMBER VARCHAR(30) COMMENT '모바일 본인인증용 연락처',
    LAST_UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() COMMENT '인사 DB 변경 일시',
    CONSTRAINT PK_HR_EMPLOYEE PRIMARY KEY (EMP_ID)
)
COMMENT = '사내 인사 시스템(현장직)에서 주기적으로 동기화되는 임직원 원장 테이블. 실습용. [sso-user-sync]';

-- 05.2 동기화 작업 결과 감사(Audit) 로그 테이블 (SILVER 스키마)
CREATE OR REPLACE TABLE KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG (
    LOG_ID NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    EMP_ID VARCHAR(50),
    ACTION_TYPE VARCHAR(50) COMMENT 'CREATE_USER, DISABLE_USER, GRANT_ROLE, REVOKE_ROLE',
    EXECUTED_QUERY VARCHAR(1000),
    STATUS VARCHAR(20) COMMENT 'SUCCESS, FAILED',
    ERROR_MESSAGE VARCHAR(2000),
    EXECUTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = '인사 DB -> Snowflake 사용자 및 권한 동기화 이력 감사 로그. 실습용. [sso-user-sync]';

-- 05.3 변경 데이터 캡처 (CDC)를 위한 Stream 생성 (BRONZE 스키마)
-- 인사 테이블의 신규 입사(INSERT), 부서/직무 변경(UPDATE), 퇴사(UPDATE/DELETE)를 감지합니다.
CREATE OR REPLACE STREAM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM
    ON TABLE KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER
    APPEND_ONLY = FALSE
    COMMENT = '인사 마스터 테이블 변경분 감지 스트림. 실습용. [sso-user-sync]';

-- 05.4 기초 테스트 데이터 적재 (현장 작업자 샘플)
MERGE INTO KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER AS target
USING (
    SELECT 'EMP_F001' AS EMP_ID, '박현장' AS EMP_NAME, '반도체 1공장 설비보전반' AS DEPT_NAME, 'FACTORY_A' AS FACTORY_CODE, '설비엔지니어' AS JOB_TITLE, 'ACTIVE' AS EMPLOYMENT_STATUS, 'KSM_FACTORY_WORKER_ROLE' AS SNOWFLAKE_ROLE, '010-1234-5678' AS PHONE_NUMBER UNION ALL
    SELECT 'EMP_F002' AS EMP_ID, '이공정' AS EMP_NAME, '반도체 1공장 생산가공반' AS DEPT_NAME, 'FACTORY_A' AS FACTORY_CODE, '오퍼레이터' AS JOB_TITLE, 'ACTIVE' AS EMPLOYMENT_STATUS, 'KSM_FACTORY_WORKER_ROLE' AS SNOWFLAKE_ROLE, '010-2345-6789' AS PHONE_NUMBER UNION ALL
    SELECT 'EMP_F003' AS EMP_ID, '최안전' AS EMP_NAME, '공장환경안전팀' AS DEPT_NAME, 'FACTORY_B' AS FACTORY_CODE, '안전관리자' AS JOB_TITLE, 'ACTIVE' AS EMPLOYMENT_STATUS, 'KSM_FACTORY_WORKER_ROLE' AS SNOWFLAKE_ROLE, '010-3456-7890' AS PHONE_NUMBER
) AS src
ON target.EMP_ID = src.EMP_ID
WHEN MATCHED THEN
    UPDATE SET 
        EMP_NAME = src.EMP_NAME,
        DEPT_NAME = src.DEPT_NAME,
        FACTORY_CODE = src.FACTORY_CODE,
        JOB_TITLE = src.JOB_TITLE,
        EMPLOYMENT_STATUS = src.EMPLOYMENT_STATUS,
        SNOWFLAKE_ROLE = src.SNOWFLAKE_ROLE,
        LAST_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (EMP_ID, EMP_NAME, DEPT_NAME, FACTORY_CODE, JOB_TITLE, EMPLOYMENT_STATUS, SNOWFLAKE_ROLE, PHONE_NUMBER, LAST_UPDATED_AT)
    VALUES (src.EMP_ID, src.EMP_NAME, src.DEPT_NAME, src.FACTORY_CODE, src.JOB_TITLE, src.EMPLOYMENT_STATUS, src.SNOWFLAKE_ROLE, src.PHONE_NUMBER, CURRENT_TIMESTAMP());

SELECT * FROM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER;
SELECT * FROM KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM;

SELECT 'Step 05 Completed: HR Master Table and Stream Successfully Created' AS STATUS;


-- ==============================================================================
-- 🧹 리소스 정리 (이 문서가 만든 것)
-- ==============================================================================
-- 정본은 `98_리소스정리.sql` 입니다.
--   · TABLE   KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER
--   · TABLE   KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG
--   · STREAM  KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM
--
-- 모두 KSM_ENTERPRISE_DB 하위이므로 `DROP DATABASE KSM_ENTERPRISE_DB` 로
-- 함께 제거됩니다. 개별 정리가 필요하면 아래를 사용하십시오.
--
-- DROP STREAM IF EXISTS KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_STREAM;
-- DROP TABLE  IF EXISTS KSM_ENTERPRISE_DB.BRONZE.HR_EMPLOYEE_MASTER;
-- DROP TABLE  IF EXISTS KSM_ENTERPRISE_DB.SILVER.HR_SYNC_AUDIT_LOG;
