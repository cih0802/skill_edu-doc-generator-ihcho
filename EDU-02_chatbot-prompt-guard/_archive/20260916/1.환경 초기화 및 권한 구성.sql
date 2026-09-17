-- ==============================================================================
-- 실습 1단계: 환경 초기화 및 권한/RBAC 구성 (1.환경 초기화 및 권한 구성.sql)
-- 설명: KSM HQ 챗봇 시스템 구축을 위한 데이터베이스, 스키마, 가상 웨어하우스 생성
--       및 Cortex 함수/검색/에이전트 사용을 위한 역할(Role) 및 권한 설정
-- ==============================================================================

-- [1] 계정 관리자 권한으로 전환
USE ROLE ACCOUNTADMIN;

-- [2] 실습용 전용 가상 웨어하우스(Compute Warehouse) 생성
CREATE OR REPLACE WAREHOUSE KSM_CHATBOT_WH
    WITH 
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'KSM HQ 챗봇 파이프라인 및 서비스용 웨어하우스';

USE WAREHOUSE KSM_CHATBOT_WH;

-- [3] 실습용 데이터베이스 생성
CREATE OR REPLACE DATABASE KSM_CHATBOT_DB
    COMMENT = 'KSM HQ 챗봇 및 Cortex 검색/가드레일 실습 데이터베이스';

-- [4] 표준 6대 스키마 (Medallion + Serving + Ops + Security) 생성
-- 4.1 BRONZE: 원본 문서 적재용 스키마 (스테이지, 디렉터리 테이블, 스트림)
CREATE OR REPLACE SCHEMA KSM_CHATBOT_DB.BRONZE
    COMMENT = '비정형 원본 문서 적재 및 인덱싱 스키마 (Raw Layer)';

-- 4.2 SILVER: 파싱 및 청킹 완료 정제 데이터 스키마
CREATE OR REPLACE SCHEMA KSM_CHATBOT_DB.SILVER
    COMMENT = 'AI_PARSE_DOCUMENT 및 청킹 처리된 텍스트/메타데이터 스키마 (Refined Layer)';

-- 4.3 GOLD: 고도화된 지식 베이스 및 비즈니스 요약 데이터 스키마
CREATE OR REPLACE SCHEMA KSM_CHATBOT_DB.GOLD
    COMMENT = '정제된 업무 요약 및 도메인 지식 베이스 스키마 (Aggregated/Business Layer)';

-- 4.4 SERVING: Cortex Search 서비스 및 최종 챗봇 서빙 스키마
CREATE OR REPLACE SCHEMA KSM_CHATBOT_DB.SERVING
    COMMENT = 'Cortex Search Service 및 챗봇 인터페이스/뷰 스키마 (Serving Layer)';

-- 4.5 OPS: 파이프라인 자동화 및 운영 관리 스키마 (Task, 모니터링)
CREATE OR REPLACE SCHEMA KSM_CHATBOT_DB.OPS
    COMMENT = 'Serverless Task, 파이프라인 제어 및 운영 배치 모니터링 스키마 (Operations Layer)';

-- 4.6 SECURITY: 보안 가드레일 설정, PII 마스킹 UDF 및 거버넌스 스키마
CREATE OR REPLACE SCHEMA KSM_CHATBOT_DB.SECURITY
    COMMENT = '보안 가드 설정 테이블, PII 마스킹 UDF 및 거버넌스 통제 스키마 (Security/Governance Layer)';


-- ==============================================================================
-- [5] 보안 및 거버넌스를 위한 RBAC(Role-Based Access Control) 구성
-- ==============================================================================

-- 5.1 챗봇 엔지니어 역할 (개발 및 파이프라인 관리자)
CREATE OR REPLACE ROLE KSM_CHATBOT_ADMIN_ROLE
    COMMENT = 'KSM 챗봇 파이프라인 개발 및 Cortex Search/Agent 관리자 역할';

-- 5.2 챗봇 최종 사용자 역할 (검색 및 질의 전용)
CREATE OR REPLACE ROLE KSM_CHATBOT_USER_ROLE
    COMMENT = 'KSM 챗봇 검색 서비스 및 에이전트 조회 전용 역할';

-- 5.3 역할 계층 구조 설정 (SYSADMIN에 상속)
GRANT ROLE KSM_CHATBOT_ADMIN_ROLE TO ROLE SYSADMIN;
GRANT ROLE KSM_CHATBOT_USER_ROLE TO ROLE KSM_CHATBOT_ADMIN_ROLE;

-- 5.4 현재 사용자에게 관리자 역할 부여 (테스트용)
SET CURRENT_USER_NAME = CURRENT_USER();
GRANT ROLE KSM_CHATBOT_ADMIN_ROLE TO USER IDENTIFIER($CURRENT_USER_NAME);


-- ==============================================================================
-- [6] 권한(Grants) 부여
-- ==============================================================================

-- 6.1 웨어하우스 사용 권한
GRANT USAGE, OPERATE ON WAREHOUSE KSM_CHATBOT_WH TO ROLE KSM_CHATBOT_ADMIN_ROLE;
GRANT USAGE ON WAREHOUSE KSM_CHATBOT_WH TO ROLE KSM_CHATBOT_USER_ROLE;

-- 6.2 데이터베이스 및 스키마 권한 (ADMIN)
GRANT ALL PRIVILEGES ON DATABASE KSM_CHATBOT_DB TO ROLE KSM_CHATBOT_ADMIN_ROLE;
GRANT ALL PRIVILEGES ON ALL SCHEMAS IN DATABASE KSM_CHATBOT_DB TO ROLE KSM_CHATBOT_ADMIN_ROLE;
GRANT ALL PRIVILEGES ON FUTURE SCHEMAS IN DATABASE KSM_CHATBOT_DB TO ROLE KSM_CHATBOT_ADMIN_ROLE;

-- 6.3 Cortex AI 기능 및 LLM 함수 실행을 위한 필수 Database Role 부여
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE KSM_CHATBOT_ADMIN_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE KSM_CHATBOT_USER_ROLE;

-- 6.4 Serverless Task 실행 권한 (계정 레벨 권한 부여)
GRANT EXECUTE TASK, EXECUTE MANAGED TASK ON ACCOUNT TO ROLE KSM_CHATBOT_ADMIN_ROLE;

-- 6.5 사용자 역할(USER_ROLE)에 대한 최소 권한 부여 (Serving 스키마 읽기 전용)
GRANT USAGE ON DATABASE KSM_CHATBOT_DB TO ROLE KSM_CHATBOT_USER_ROLE;
GRANT USAGE ON SCHEMA KSM_CHATBOT_DB.SERVING TO ROLE KSM_CHATBOT_USER_ROLE;


-- ==============================================================================
-- [7] 설정 검증 (Verification)
-- ==============================================================================
SHOW SCHEMAS IN DATABASE KSM_CHATBOT_DB;
SHOW ROLES LIKE 'KSM_CHATBOT%';
SHOW GRANTS TO ROLE KSM_CHATBOT_ADMIN_ROLE;
