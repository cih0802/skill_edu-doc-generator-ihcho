-- ==============================================================================
-- 실습 3단계: 보안 UDF 및 마스킹 함수 생성 (3.보안 UDF 및 마스킹 함수 생성.sql)
-- 설명: 텍스트 내 개인정보(PII: 전화번호, 주민등록번호, 이메일 등) 사전 마스킹 UDF와
--       스테이지 파일 무결성 및 증분 검증을 위한 해시 계산 Python UDF 생성
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA SECURITY;

-- [1] 종합 PII 데이터 마스킹 SQL UDF 생성
-- 비정형 문서 텍스트 내 주민번호, 휴대전화번호, 이메일 주소를 정규식으로 감지하여 안전하게 치환
CREATE OR REPLACE FUNCTION KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(RAW_TEXT VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
IMMUTABLE
AS
$$
    -- 1. 주민등록번호 패턴 마스킹 (예: 900101-1234567 -> 900101-*******)
    -- 2. 휴대전화번호 패턴 마스킹 (예: 010-1234-5678 -> 010-****-5678)
    -- 3. 이메일 주소 패턴 마스킹 (예: sample@company.com -> s***e@company.com 또는 [EMAIL_MASKED])
    SELECT 
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    RAW_TEXT,
                    '\\b([0-9]{6})-?([1-8][0-9]{6})\\b', 
                    '\\1-*******'
                ),
                '\\b(01[016789])-?([0-9]{3,4})-?([0-9]{4})\\b', 
                '\\1-****-\\3'
            ),
            '\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b', 
            '[EMAIL_MASKED]'
        )
$$;

-- [2] 스테이지 파일 해시(MD5/SHA256) 검증 Python UDF 생성
-- Snowpark Python File Stream을 활용하여 스테이지에 적재된 파일의 바이너리 해시를 직접 계산
CREATE OR REPLACE FUNCTION KSM_CHATBOT_DB.SECURITY.CALCULATE_STAGE_FILE_HASH(FILE_URL STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'calculate_hash'
AS
$$
import hashlib
from snowflake.snowpark.files import SnowflakeFile

def calculate_hash(file_url: str) -> str:
    if not file_url:
        return None
    try:
        hasher = hashlib.md5()
        with SnowflakeFile.open(file_url, 'rb') as f:
            while chunk := f.read(8192):
                hasher.update(chunk)
        return hasher.hexdigest()
    except Exception as e:
        return f"ERROR: {str(e)}"
$$;

-- [3] 함수 실행 및 마스킹 단위 테스트 (Verification)
SELECT 
    '담당자: 홍길동 (010-9876-5432, 950505-1234567, contact@ksm.co.kr)' AS ORIGINAL_TEXT,
    KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(ORIGINAL_TEXT) AS SANITIZED_TEXT;

-- [4] 권한 부여 (필요 시 USER_ROLE 등 공유)
GRANT USAGE ON FUNCTION KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(VARCHAR) TO ROLE KSM_CHATBOT_USER_ROLE;
