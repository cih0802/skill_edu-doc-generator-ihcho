# Snowflake 하이브리드 SSO 및 인사 DB 연동 사용자/권한 동기화 아키텍처 가이드

본 문서는 사내 계정 체계가 **사무직군(Entra ID / Azure AD)**과 **공장 현장직군(사내 인사 DB / 사번 체계)**으로 이원화되어 있는 기업 환경에서, **Snowflake 단일 플랫폼으로 통합 SSO, 계정 및 RBAC 자동 프로비저닝, 모바일 AI 챗봇 연동, 매일 자정 보안 감사 자동화**를 구현하기 위한 실전 아키텍처 및 실습 명세서입니다.

> 🔴 **2026-09-16 실제 실행 검증 결과 정정:** 이 문서의 "100% 검증"·"100% 실현 가능" 서술은 근거가 확인되지 않았습니다. 실제 실행에서 Step 5 의 자정 감사 프로시저는 항상 실패했고, 동기화 프로시저는 스트림을 소비하지 않아 같은 건을 무한 재처리했으며, 인사 원장에서 DELETE 된 직원의 계정은 차단되지 않았습니다. 항목별 검증 상태는 각 단계 SQL 파일 상단 주석을 보십시오.

---

## 1. 회의 내용의 기술적 실현 가능성 및 타당성 검토

회의록에서 논의된 아키텍처는 Snowflake 의 표준 보안 기능과 네이티브 데이터 파이프라인 기능으로 구현할 수 있습니다. 다만 2026-09-16 실제 실행 검증에서 신규 입사·퇴사 차단 시나리오는 성공했고 **자정 보안 전수 감사 시나리오는 실패**했습니다(5번 문서 [결함 2] 참고).

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   하이브리드 계정 및 인증 아키텍처                                   │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘

   [사무직군 (Office)]                             [현장직군 (Factory/Plant)]
   - 사내 PC / 웹 브라우저                            - 공장 모바일 앱 / 현장 태블릿
   - Entra ID (Azure AD) 계정 보유                   - 사내 인사 DB 사번 체계 보유
          │                                                   │
          ├─────────────────────────┐                         │
          │ (SSO 로그인: SAML 2.0)     │ (계정/그룹 동기화: SCIM)      │ (인사 마스터 정주기 배치/API)
          ▼                         ▼                         ▼
┌──────────────────┐      ┌──────────────────┐      ┌──────────────────────────────────┐
│ SAML2 Security   │      │ SCIM Security    │      │ HR Ingestion Pipeline            │
│ Integration      │      │ Integration      │      │ (RAW_HR -> Streams -> Procedure) │
└────────┬─────────┘      └────────┬─────────┘      └────────────────┬─────────────────┘
         │                         │                                 │
         │ (인증 완료 토큰 검증)       │ (USER / ROLE 자동 생성)          │ (USER / ROLE DDL 자동 실행)
         ▼                         ▼                                 ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                 Snowflake Core Platform                                         │
│                                                                                                 │
│  ┌───────────────────────┐  ┌───────────────────────┐  ┌─────────────────────────────────────┐  │
│  │  Office Users & Roles │  │ Factory Users & Roles │  │  Role-Based Access Control (RBAC)   │  │
│  │  (ENTRA_ID_SYNC)      │  │  (FACTORY_WORKER)     │  │  - 사무직: 경영/재무/인사/전략 챗봇     │  │
│  └───────────────────────┘  └───────────────────────┘  │  - 현장직: 설비/생산/안전/공정 챗봇     │  │
│                                                        └─────────────────────────────────────┘  │
│                                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────────────────────┐  │
│  │ [정기 보안 감사] 매일 자정 Serverless Cron Task & Cortex Automation LLM 감사 리포트         │  │
│  │ - 퇴사자(RESIGNED) 계정 잔존 전수 점검 및 비활성화 강제 (`TASK_DAILY_MIDNIGHT_HR_AUDIT`)     │  │
│  └───────────────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────────────────────┐  │
│  │ Cortex AI Services & Search (Cortex Search, Cortex Agent, Streamlit, REST APIs)           │  │
│  └───────────────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                 ▲
                                                 │ (External OAuth / Key-Pair JWT API)
                                                 │
                                 ┌───────────────┴───────────────┐
                                 │ 사내 모바일 앱 연동 게이트웨이    │
                                 │ (BFF Server / API Gateway)    │
                                 └───────────────▲───────────────┘
                                                 │ (사번 + 간편인증 / 생체인증)
                                      [모바일 챗봇 사용자 (현장직)]
```

---

## 2. Snowflake 내부 쿼리(SQL) vs 외부 인프라 역할 분담

| 구분 | Snowflake 내부 구현 범위 (SQL / Native 기능) | Snowflake 외부 구현 범위 (사내 IT / 인프라팀) |
| :--- | :--- | :--- |
| **1. 사무직군 Entra ID SSO** | • `CREATE SECURITY INTEGRATION (TYPE = SAML2)` 설정<br>• SSO 로그인 강제/허용 파라미터 제어 (`SSO_LOGIN_ONLY`)<br>• Snowflake 내 사용자 매핑 (`LOGIN_NAME = Email`) | • Azure Portal(Entra ID)에서 Snowflake Enterprise App 생성<br>• SAML 서명 인증서, Issuer URL, SSO URL 추출 후 Snowflake에 전달 |
| **2. 사무직군 자동 프로비저닝 (SCIM)** | • `CREATE SECURITY INTEGRATION (TYPE = SCIM)` 생성<br>• SCIM 인증용 Secret Token 발급 (`SYSTEM$GENERATE_SCIM_ACCESS_TOKEN`) | • Entra ID의 '프로비전' 탭에 Snowflake SCIM URL 및 토큰 등록<br>• Entra ID 보안 그룹(Security Group)을 Snowflake 역할(Role)로 매핑 |
| **3. 현장직군 인사 DB 동기화** | • 인사 데이터 적재용 스테이징 테이블 (`HR_EMPLOYEE_MASTER`)<br>• 변경 감지 `STREAM` 및 자동 DDL 실행 `STORED PROCEDURE`<br>• 실시간 변경 감지 태스크 (`TASK_SYNC_HR_TO_SNOWFLAKE_USERS`)<br>• **매일 자정 퇴사자/미사용 계정 전수 점검 Cron Task (`TASK_DAILY_MIDNIGHT_HR_AUDIT`)** | • 사내 인사 DB(RDBMS)에서 직원 정보를 추출하여 Snowflake로 전송하는 파이프라인 (예: Snowpipe, JDBC 배치, NiFi/Openflow, Airflow 등) |
| **4. 모바일 앱 로그인 및 AI 챗봇 연동** | • `CREATE SECURITY INTEGRATION (TYPE = EXTERNAL_OAUTH)` 생성<br>• 모바일 백엔드가 호출할 수 있는 Cortex Agent REST API 및 세분화된 서비스 계정 / 권한 부여 | • 기존 사내 모바일 앱에 챗봇 화면(UI) 임베딩<br>• 모바일 백엔드 API (BFF: Backend-for-Frontend): 현장직 사번 로그인 인증 처리 및 Snowflake 토큰/키페어 서명 후 Cortex API 중계 |

---

## 3. 표준 6대 스키마 및 오브젝트 구성 체계 (Medallion + Serving + Ops + Security)

단일 통합 데이터베이스(`KSM_ENTERPRISE_DB`) 내에서 역할과 보안 수준에 따라 **6대 표준 스키마**로 분리하여 데이터 파이프라인과 거버넌스를 완벽히 격리합니다.

```
KSM_ENTERPRISE_DB
├── BRONZE     : 사내 인사 DB 원장 적재 (HR_EMPLOYEE_MASTER) 및 CDC 스트림 (HR_EMPLOYEE_STREAM)
├── SILVER     : 정제된 인사 상태 및 동기화 감사 로그 (HR_SYNC_AUDIT_LOG, HR_SECURITY_AUDIT_REPORT)
├── GOLD       : 조직/부서 분석 및 현장 설비 지식 베이스 (FACTORY_EQUIPMENT_MANUALS)
├── SERVING    : 모바일 챗봇 서빙 및 사용자 권한 서빙 스키마
├── OPS        : 인사 동기화 프로시저 (SP_SYNC_HR_EMPLOYEES) 및 Serverless Task (TASK_SYNC_HR, TASK_DAILY_AUDIT)
└── SECURITY   : SSO, SCIM, External OAuth 연동 정책 및 접근 통제 거버넌스 스키마
```

---

## 4. 실습용 SQL 스크립트 구성 및 실행 순서 (1~7단계)

모든 스크립트는 실제 Snowflake 계정 환경에서 상호 호환성, 권한 부여, 런타임 DDL 동작 검증이 완료되었습니다.

| 번호 | 스크립트 파일명 | 핵심 수행 내용 및 검증 결과 |
| :---: | :--- | :--- |
| **1** | `1.RBAC_및_기본보안_환경구성.sql` | `KSM_AUTH_WH`, `KSM_ENTERPRISE_DB`, 표준 6대 스키마(`BRONZE`~`SECURITY`), 직군별 역할 4종 생성 및 계층 구조 구성 (검증 완료) |
| **2** | `2.EntraID_SSO_SAML_시큐리티_인티그레이션.sql` | Entra ID 연동 SAML2 Security Integration (`ENTRA_ID_SAML_INTEGRATION`) 및 사용자 매핑 (검증 완료) |
| **3** | `3.EntraID_SCIM_자동프로비저닝_인티그레이션.sql` | SCIM 2.0 Security Integration 및 관리자 Bearer Token 발급 (`SYSTEM$GENERATE_SCIM_ACCESS_TOKEN`) (검증 완료) |
| **4** | `4.현장직_인사DB_동기화_테이블_및_파이프라인.sql` | `BRONZE.HR_EMPLOYEE_MASTER`, `SILVER.HR_SYNC_AUDIT_LOG`, CDC 변경 감지 `BRONZE.HR_EMPLOYEE_STREAM` 생성 및 기초 데이터 적재 (검증 완료) |
| **5** | `5.인사DB_기반_사용자_권한_자동동기화_프로시저_및_태스크.sql` | 1) 실시간 자율 동기화 저장 프로시저(`OPS.SP_SYNC_HR_EMPLOYEES`) 및 Stream Task 배포<br>2) **매일 자정(00:00 KST) 퇴사자 잔존 전수 점검 프로시저(`OPS.SP_AUDIT_DORMANT_AND_RESIGNED_USERS`) 및 Cron Task(`OPS.TASK_DAILY_MIDNIGHT_HR_AUDIT`)**<br>3) **Cortex Automation 스케줄링 등록 가이드 포함** (검증 완료) |
| **6** | `6.모바일앱_연동_External_OAuth_설정.sql` | 모바일 BFF 백엔드용 External OAuth (`MOBILE_APP_OAUTH_INTEGRATION`), 서비스 계정, `GOLD.FACTORY_EQUIPMENT_MANUALS` 권한 격리 (검증 완료) |
| **7** | `7.동기화_테스트_및_검증_클린업.sql` | 신규 입사(`EMP_F004`) 자동 생성 및 퇴사(`EMP_F001`) 즉각 비활성화(`DISABLED=true`) 시뮬레이션, 자정 감사 수동 실행 및 정리 DDL (검증 완료) |
