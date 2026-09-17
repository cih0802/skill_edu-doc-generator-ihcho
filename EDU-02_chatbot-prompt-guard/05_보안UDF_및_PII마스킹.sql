/*
title: 보안 UDF 및 PII 마스킹
step: 05
type: sql
summary: 정규식 기반 PII(주민번호/휴대전화/이메일) 마스킹 SQL UDF와 스테이지 파일 MD5 해시 계산 Python UDF를 생성하고 마스킹 결과를 단위 테스트한다.
requires: 04_문서업로드_안내.md
next: 06_문서파싱_및_청킹파이프라인.sql
*/

-- ==============================================================================
-- 검증 상태 (2026-09-16, 실습 완주):
--   ✅ MASK_PII_TEXT 생성 및 단위 테스트 — 실제 실행 검증 완료
--      출력: '담당자: 홍길동 (010-****-5432, 950505-*******, [EMAIL_MASKED])'
--      → 문서에 적힌 기대값과 정확히 일치
--   ✅ [3.1] 한계 케이스 — 실제 실행 검증 완료. 공백 구분 번호·이름·주소·계좌번호는
--      전혀 마스킹되지 않음(입력=출력). 문서의 한계 서술이 정확함
--   ✅ CALCULATE_STAGE_FILE_HASH (Python, RUNTIME 3.11) 생성 — 실제 실행 검증 완료
--   ⚠️ CALCULATE_STAGE_FILE_HASH 의 실제 해시 계산 호출은 미검증.
--      06_ 이 디렉터리 테이블의 MD5 를 쓰므로 실습 경로에서 호출되지 않는다
-- ==============================================================================
-- ==============================================================================
-- ⚙️ 설정값
-- ==============================================================================
--   마스킹 UDF   : KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(VARCHAR)
--   해시 UDF     : KSM_CHATBOT_DB.SECURITY.CALCULATE_STAGE_FILE_HASH(STRING)
--   Python 런타임: 3.11
--   해시 알고리즘: MD5 (변경 감지 용도. 암호학적 용도가 아님)
--
--   예상 소요 시간: 약 10분
-- ==============================================================================

USE ROLE KSM_CHATBOT_ADMIN_ROLE;
USE WAREHOUSE KSM_CHATBOT_WH;
USE DATABASE KSM_CHATBOT_DB;
USE SCHEMA SECURITY;


-- ##############################################################################
-- [1] PII 마스킹 SQL UDF
-- ##############################################################################
-- 문서 텍스트를 벡터 인덱싱하기 **전에** 개인정보를 치환합니다.
-- 저장소(DOCUMENT_CHUNKS)와 검색 인덱스에 원본 PII가 들어가지 않게 하는 것이 목적입니다.
--
-- 🔴 이 UDF의 한계를 반드시 인지하십시오. 정규식은 아래를 잡지 못합니다.
--    · 형식이 어긋난 표기 (예: 공백·점으로 구분된 번호, 전각 숫자)
--    · 이름·주소·계좌번호·여권번호 등 패턴이 정형화되지 않은 식별정보
--    · OCR 오인식으로 숫자가 깨진 경우
--    따라서 이것은 **완전한 비식별 조치가 아니며**, 실제 개인정보가 든 문서를
--    이 실습에 투입하면 안 됩니다.
-- IF NOT EXISTS: 재실행 시 기존 함수를 덮어쓰지 않습니다.
--    본문을 수정해 다시 배포해야 하면 CREATE OR REPLACE 로 바꾸십시오
--    (함수는 상태를 갖지 않으므로 교체로 잃는 데이터가 없습니다).

CREATE FUNCTION IF NOT EXISTS KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(RAW_TEXT VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
IMMUTABLE
COMMENT = '주민번호/휴대전화/이메일 정규식 마스킹. 완전한 비식별 조치가 아님. [chatbot-prompt-guard]'
AS
$$
    -- 1) 주민등록번호  900101-1234567 → 900101-*******
    -- 2) 휴대전화번호  010-1234-5678  → 010-****-5678
    -- 3) 이메일 주소   a@b.com        → [EMAIL_MASKED]
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


-- ##############################################################################
-- [2] 스테이지 파일 해시 계산 Python UDF (보조)
-- ##############################################################################
-- 디렉터리 테이블의 MD5 컬럼으로도 변경 감지가 가능하므로 06_ 의 파이프라인은
-- 이 UDF를 사용하지 않습니다. 파일 무결성을 별도로 확인하고 싶을 때 쓰는 보조 함수입니다.
-- SnowflakeFile.open 에 넘기는 URL 은 BUILD_STAGE_FILE_URL 로 만든 스코프 URL 입니다.

CREATE FUNCTION IF NOT EXISTS KSM_CHATBOT_DB.SECURITY.CALCULATE_STAGE_FILE_HASH(FILE_URL STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'calculate_hash'
COMMENT = '스테이지 파일의 바이너리 MD5 해시 계산(변경 감지 용도). [chatbot-prompt-guard]'
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
            while True:
                chunk = f.read(8192)
                if not chunk:
                    break
                hasher.update(chunk)
        return hasher.hexdigest()
    except Exception as e:
        return f"ERROR: {str(e)}"
$$;


-- ##############################################################################
-- [3] 마스킹 단위 테스트
-- ##############################################################################
-- 기대 출력: '담당자: 홍길동 (010-****-5432, 950505-*******, [EMAIL_MASKED])'
-- 위 기대값은 정규식 체인을 직접 실행해 확인한 결과입니다(문서 상단 검증 상태 참고).

SELECT
    '담당자: 홍길동 (010-9876-5432, 950505-1234567, contact@ksm.co.kr)' AS ORIGINAL_TEXT,
    KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(ORIGINAL_TEXT)               AS SANITIZED_TEXT;

-- 3.1 한계 확인 테스트 — 아래는 **마스킹되지 않습니다.** 정규식의 한계를 직접 보십시오.
SELECT
    '연락처 010 1234 5678 / 홍길동 / 서울시 강남구 / 110-123-456789' AS EDGE_CASE_INPUT,
    KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(EDGE_CASE_INPUT)             AS EDGE_CASE_OUTPUT;
--   관찰 결과: ______________________________________________
--   (공백 구분 번호, 이름, 주소, 계좌번호는 이 UDF가 처리하지 않습니다)

-- 3.2 함수 생성 확인
SHOW USER FUNCTIONS IN SCHEMA KSM_CHATBOT_DB.SECURITY;


-- ##############################################################################
-- [4] 권한 부여
-- ##############################################################################
-- 사용자 역할이 마스킹 함수를 직접 호출할 필요가 있을 때만 부여합니다.
-- 파이프라인(06_)은 프로시저 소유자 권한으로 호출하므로 이 부여가 없어도 동작합니다.

GRANT USAGE ON FUNCTION KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(VARCHAR)
    TO ROLE KSM_CHATBOT_USER_ROLE;


-- ##############################################################################
-- 🧹 리소스 정리 — 이 문서까지 진행한 뒤 중단하는 경우
-- ##############################################################################
-- 전체 정리는 98_리소스정리.sql 이 정본입니다.
-- 이 문서에서 만든 함수 2개는 DB 를 삭제하면 함께 사라집니다.
-- 함수만 지우려면 주석을 해제하십시오.
--
-- DROP FUNCTION IF EXISTS KSM_CHATBOT_DB.SECURITY.MASK_PII_TEXT(VARCHAR);
-- DROP FUNCTION IF EXISTS KSM_CHATBOT_DB.SECURITY.CALCULATE_STAGE_FILE_HASH(STRING);
