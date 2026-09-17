/*
title: Entra ID SSO SAML 시큐리티 인티그레이션
step: 03
type: sql
summary: 사무직군을 위한 SAML2 시큐리티 인티그레이션을 생성하고 샘플 사용자에 역할을 부여한다. 계정 로그인 페이지에 영향을 준다.
requires: 02_RBAC_및_기본보안_환경구성.sql
next: 04_EntraID_SCIM_자동프로비저닝.sql
*/

-- ==============================================================================
-- [Step 03] Entra ID (Azure AD) SSO SAML 2.0 Security Integration 설정
-- 목적: 사무직 직원이 사내 Microsoft 365 / Entra ID 계정으로 Snowflake 및 
--       Snowflake 연계 웹 챗봇(Streamlit)에 Single Sign-On 할 수 있도록 설정합니다.
-- ==============================================================================
-- 검증 상태 (2026-09-16, 계정 LJ20513 / AWS_AP_NORTHEAST_1 / Enterprise 에서 실제 실행):
--   ✅ CREATE SECURITY INTEGRATION ... TYPE = SAML2 — 실제 실행 검증 완료
--      ("Integration ENTRA_ID_SAML_INTEGRATION successfully created")
--   ✅ CREATE USER KSM_OFFICE_SAMPLE_USER + GRANT ROLE — 실제 실행 검증 완료
--   ✅ DROP SECURITY INTEGRATION 으로 완전 원복 — 실제 실행 검증 완료
--   ⚠️ 실제 Entra ID 와의 SSO 로그인 왕복은 미검증. 위 인증서·Issuer·SSO URL 은
--      더미 값이므로 이 인티그레이션으로는 실제 로그인이 성공하지 않는다.
--      문법과 생성 가능성만 확인된 것이다.
--
-- 🔴 실행 시 계정에 미치는 영향 — 비용과 무관한 변경입니다
--   ENABLED = TRUE + SAML2_ENABLE_SP_INITIATED = TRUE 이면 이 계정의 **로그인 페이지에
--   SSO 버튼이 추가**됩니다(레이블: SAML2_SP_INITIATED_LOGIN_PAGE_LABEL).
--   비밀번호 로그인은 비활성화되지 않으며 DROP 으로 완전히 사라집니다.
--   🔴 2.4 의 SSO_LOGIN_ONLY = TRUE 는 주석을 해제하지 마십시오. 더미 IdP 상태에서
--      해제하면 해당 사용자는 로그인할 수 없게 됩니다(잠금).
-- ==============================================================================

USE ROLE ACCOUNTADMIN;

-- 03.1 Entra ID 연동 SAML2 Security Integration 생성
-- * 실제 운영 시: Azure Portal의 Entra ID [엔터프라이즈 애플리케이션] -> [Snowflake] SAML 설정 화면에서 
--   발급받은 실제 SAML2_ISSUER, SAML2_SSO_URL, SAML2_X509_CERT 값으로 대체합니다.
-- * 아래 인증서는 실제 Snowflake 컴파일 검증을 통과한 유효한 X.509 포맷입니다.
-- 🔴 계정 레벨 객체이므로 CREATE OR REPLACE 를 쓰지 않습니다.
--    OR REPLACE 는 **동명의 기존 객체를 통째로 덮어씁니다.** 계정에 이미 같은 이름의
--    시큐리티 인티그레이션이나 사용자가 있으면 사용자 자산을 파괴하고, DROP 으로
--    되돌아가지 않습니다. 재실행 안전성은 IF NOT EXISTS + 사전 충돌 검사로 확보합니다.
--    (사전 충돌 검사는 95_실습전_기준선.md 를 먼저 수행하십시오)
CREATE SECURITY INTEGRATION IF NOT EXISTS ENTRA_ID_SAML_INTEGRATION
    TYPE = SAML2
    ENABLED = TRUE
    SAML2_ISSUER = 'https://sts.windows.net/00000000-0000-0000-0000-000000000000/'
    SAML2_SSO_URL = 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/saml2'
    SAML2_PROVIDER = 'CUSTOM'
    SAML2_X509_CERT = 'MIIDCDCCAfCgAwIBAgIUCL7mcirG6KDHW3BWOn4UTPab8qswDQYJKoZIhvcNAQELBQAwPjELMAkGA1UEBhMCS1IxFTATBgNVBAoMDEtTTSBFbnRyYSBJRDEYMBYGA1UEAwwPc3RzLndpbmRvd3MubmV0MB4XDTI2MDkwNzAyMjEwNVoXDTI3MDkwNzAyMjEwNVowPjELMAkGA1UEBhMCS1IxFTATBgNVBAoMDEtTTSBFbnRyYSBJRDEYMBYGA1UEAwwPc3RzLndpbmRvd3MubmV0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkGyw8/oCTI9n08nASn8NBJETcoi/BKRlwMLPdwQ9O5F/RrKIvWSbBVap3JWk9jwEL8pC3XtWPzstLqEju/LKLDmTK0d6CkD7RkBzbSCPCrbktYZ2KS40P4NJoEeTY49Bb+Zx/JOTO3k74GjllXjuV7qSeXEpTNgaoBkENTi0XsuMCYBpSk4fXWUKnhM6SUtOdtLTVRIWX8fPGTm8btYh4N90kl33U9ElFwGgy9jZ3wcboCY/AUwbQh4EQeoBdMGjDFOfwE2005KllWdKKzHDRkr4WApXPfyLlTfqcNrOUkhr/nyrxHfQd8azCu2ZEZ16JE60IYUMj6xJLQbN1z620wIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQCIHPBnSu22vCpBMkuPIliYSXf35b/txVJAlm+9SuLVxYerQuvIXM0g25P8ykc/yazrUlmLynJABeAWy+VnpB113mh55i1bS+aThkHYZujpNbKLQrp5KXzjbB76RpvZDk/0oLZuQmOBhqR9XNZHl8ZFYsaX7c/MovD0RFWS1mxrfUeFxg3avIMoObkreF1EaLWqA09qSHqzakjmjk8ElkMyUKSCzbhyMT4bosBev0Pg/65mIIU3WV6XnyfLHsc6Mh8VrkgDxGWc3jx+evJpjh/g7foZEuuMmKNqIft20KaWafBY2/cGHaylPUxQL06CAVIiCAfqKqLoQHckmDDvcCg9'
    SAML2_SP_INITIATED_LOGIN_PAGE_LABEL = 'KSM Entra ID 사내 계정으로 로그인'
    SAML2_ENABLE_SP_INITIATED = TRUE
    SAML2_POST_LOGOUT_REDIRECT_URL = 'https://myapps.microsoft.com'
    COMMENT = '사무직군 Entra ID (Azure AD) SAML 2.0 SSO 연동 인티그레이션. 실습용. [sso-user-sync]';

-- 03.2 생성된 SAML Integration 상세 정보 확인
DESCRIBE SECURITY INTEGRATION ENTRA_ID_SAML_INTEGRATION;

-- 03.3 사무직 사용자 샘플 생성 (SAML 이메일 매핑)
-- 🔴 계정 레벨 객체이므로 CREATE OR REPLACE 를 쓰지 않습니다.
--    OR REPLACE 는 **동명의 기존 객체를 통째로 덮어씁니다.** 계정에 이미 같은 이름의
--    시큐리티 인티그레이션이나 사용자가 있으면 사용자 자산을 파괴하고, DROP 으로
--    되돌아가지 않습니다. 재실행 안전성은 IF NOT EXISTS + 사전 충돌 검사로 확보합니다.
--    (사전 충돌 검사는 95_실습전_기준선.md 를 먼저 수행하십시오)
CREATE USER IF NOT EXISTS KSM_OFFICE_SAMPLE_USER
    LOGIN_NAME = 'user.office@ksm.co.kr'
    DISPLAY_NAME = '김사무 (경영기획팀)'
    FIRST_NAME = '사무'
    LAST_NAME = '김'
    EMAIL = 'user.office@ksm.co.kr'
    DEFAULT_ROLE = KSM_OFFICE_USER_ROLE
    DEFAULT_WAREHOUSE = KSM_AUTH_WH
    MUST_CHANGE_PASSWORD = FALSE
    COMMENT = '사무직 Entra ID SSO 연동 테스트 사용자. 실습용. [sso-user-sync]';

-- 사무직 역할 부여
GRANT ROLE KSM_OFFICE_USER_ROLE TO USER KSM_OFFICE_SAMPLE_USER;

-- 03.4 계정 전체 또는 사용자별 SSO 강제 설정 옵션 (운영 단계 적용)
-- ALTER USER KSM_OFFICE_SAMPLE_USER SET SSO_LOGIN_ONLY = TRUE;

SELECT 'Step 03 Completed: Entra ID SAML 2.0 SSO Integration Configured and Verified' AS STATUS;


-- ==============================================================================
-- 🧹 리소스 정리 (이 문서가 만든 것)
-- ==============================================================================
-- 정본은 `98_리소스정리.sql` 입니다.
--   · SECURITY INTEGRATION  ENTRA_ID_SAML_INTEGRATION  ← **계정 레벨**
--   · USER                  KSM_OFFICE_SAMPLE_USER     ← **계정 레벨**
--
-- 🔴 SAML 인티그레이션은 계정 **로그인 페이지에 SSO 버튼을 추가**합니다.
--    남겨두면 모든 사용자가 더미 IdP 로 가는 버튼을 보게 됩니다. 반드시 제거하십시오.
--
-- DROP SECURITY INTEGRATION IF EXISTS ENTRA_ID_SAML_INTEGRATION;
-- DROP USER IF EXISTS KSM_OFFICE_SAMPLE_USER;
