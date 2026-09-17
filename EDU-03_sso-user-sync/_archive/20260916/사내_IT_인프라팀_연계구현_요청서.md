# [기술 요구사항 요청서] 사내 IT / 인프라팀 연계 구현 요청서

**문서 번호:** REQ-SNOW-AUTH-2026-01  
**프로젝트명:** Snowflake 통합 인증(SSO), 계정/권한 자동 동기화 및 모바일 AI 챗봇 연계 구축  
**수신:** 사내 IT 기획팀, 클라우드/인프라팀, 인사정보시스템(HR) 운영팀, 사내 모바일 앱 개발팀  
**발신:** 데이터 플랫폼 / Snowflake 도입 TF  
**작성일자:** 2026년 9월 7일  

---

## 1. 요청 개요 및 목적

본 문서는 Snowflake 도입 및 사내 AI 챗봇(Cortex) 확산 프로젝트와 관련하여, **사내 IT 인프라 및 레거시 시스템과 Snowflake 간의 연계를 위해 사내 IT/인프라 담당 부서에서 수행해주셔야 할 기술 요구사항**을 정리한 요청서입니다.

사내 계정 체계가 **사무직(Entra ID)**과 **공장 현장직(인사 DB 사번 체계)**으로 이원화되어 있으므로, 각 영역별로 필요한 설정과 데이터 파이프라인 구축을 요청드립니다.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        사내 IT / 인프라팀 연계 개발 및 설정 범위                          │
└────────────────────────────────────────────────────────────────────────────────────────┘

 [1. 인프라/클라우드팀] ──▶ Entra ID SAML 2.0 SSO 및 SCIM 프로비저닝 설정
 [2. 인사정보시스템팀]  ──▶ 사내 인사 DB(현장직) ➔ Snowflake 데이터 적재 파이프라인(ETL) 구축
 [3. 모바일/앱개발팀]   ──▶ 사내 모바일 앱 백엔드(BFF) 인증 연동 및 Cortex API 중계 개발
 [4. 보안/네트워크팀]   ──▶ Snowflake 엔드포인트 방화벽 아웃바운드(443) 허용 및 인증서 관리
```

---

## 2. 부서별 세부 요청 항목

### [요청 1] 사무직군: Entra ID (Azure AD) SSO 및 SCIM 연동 (클라우드/인프라팀)

#### 1.1 SAML 2.0 Single Sign-On (SSO) 설정
* **작업 내용:** Azure Portal(Entra ID)의 `엔터프라이즈 애플리케이션(Enterprise Applications)`에 Snowflake SSO 앱을 등록하고 SAML 연동 정보를 설정합니다.
* **설정 파라미터 (Snowflake 측 제공 정보):**
  * **식별자 (Entity ID):** `https://lj20513.snowflakecomputing.com`
  * **회신 URL (Assertion Consumer Service URL):** `https://lj20513.snowflakecomputing.com/fed/login`
  * **Sign-on URL:** `https://lj20513.snowflakecomputing.com`
  * **이름 식별자 형식 (NameID):** `user.userprincipalname` (또는 `user.mail`)
* **IT팀 회신 요청 항목 (Snowflake Security Integration에 입력할 값):**
  1. **SAML2_ISSUER (Azure AD 식별자):** 예) `https://sts.windows.net/<Tenant-ID>/`
  2. **SAML2_SSO_URL (로그인 URL):** 예) `https://login.microsoftonline.com/<Tenant-ID>/saml2`
  3. **SAML2_X509_CERT (서명 인증서):** Base64로 인코딩된 X.509 인증서 문자열 (인증서 다운로드 후 텍스트 제공)

#### 1.2 SCIM 2.0 사용자 및 역할 자동 프로비저닝 설정
* **작업 내용:** Entra ID에서 사용자 생성/수정/퇴사 시 Snowflake로 실시간 계정 상태를 동기화하도록 SCIM 프로비저닝을 활성화합니다.
* **설정 파라미터:**
  * **테넌트 URL:** `https://lj20513.snowflakecomputing.com/scim/v2/`
  * **비밀 토큰 (Secret Token):** Snowflake 팀에서 발급하여 전달 (`SYSTEM$GENERATE_SCIM_ACCESS_TOKEN`)
* **동기화 매핑 규칙 요청:**
  * **사용자 매핑:** Entra ID `userPrincipalName` ➔ Snowflake `LOGIN_NAME` / `EMAIL`
  * **보안 그룹(Security Group) 매핑:** Entra ID 보안 그룹(`SEC-SNOWFLAKE-OFFICE` 등) ➔ Snowflake 역할(`KSM_OFFICE_USER_ROLE`)로 매핑 설정

---

### [요청 2] 현장직군: 사내 인사 DB ➔ Snowflake 데이터 연계 (인사시스템팀 / 데이터엔지니어링팀)

#### 2.1 연계 개요
* **목적:** Entra ID 계정이 없는 공장 생산/설비 현장 직원의 사번 및 재직 정보를 Snowflake에 실시간/배치로 전송하여 자동 계정 생성 및 퇴사 시 즉각 차단을 수행합니다.

#### 2.2 적재 대상 테이블 스펙 (Snowflake)
* **대상 테이블:** `KSM_ENTERPRISE_DB.HR_SYNC.HR_EMPLOYEE_MASTER`
* **필수 컬럼 인터페이스 규격:**

| 컬럼명 | 데이터 타입 | 필수 여부 | 설명 및 예시 |
| :--- | :--- | :---: | :--- |
| **`EMP_ID`** | VARCHAR(50) | **필수 (PK)** | 사번 (예: `EMP_F001`, `20240105`) |
| **`EMP_NAME`** | VARCHAR(100) | **필수** | 성명 (예: `박현장`) |
| **`DEPT_NAME`** | VARCHAR(100) | **필수** | 소속 부서명 (예: `반도체 1공장 설비보전반`) |
| **`FACTORY_CODE`** | VARCHAR(20) | **필수** | 공장 코드 (예: `FACTORY_A`, `FACTORY_B`) |
| **`JOB_TITLE`** | VARCHAR(50) | **필수** | 직무/직책 (예: `설비엔지니어`, `오퍼레이터`, `안전관리자`) |
| **`EMPLOYMENT_STATUS`** | VARCHAR(20) | **필수** | 재직 상태코드 (**`ACTIVE`**: 재직, **`RESIGNED`**: 퇴사, **`SUSPENDED`**: 휴직/정직) |
| **`SNOWFLAKE_ROLE`** | VARCHAR(100) | 선택 | 기본값 `KSM_FACTORY_WORKER_ROLE` (직무별 차등 역할 필요시 매핑) |
| **`PHONE_NUMBER`** | VARCHAR(30) | 선택 | 모바일 본인인증용 연락처 (예: `010-1234-5678`) |
| **`LAST_UPDATED_AT`** | TIMESTAMP_NTZ | **필수** | 인사 원천 데이터 최종 변경 일시 |

#### 2.3 파이프라인 전송 주기 및 권장 구현 방식
* **전송 주기:** 1일 1회 정기 배치 (매일 23:00 권장) 및 인사 변동 발생 시 즉시 반영
* **권장 연계 방식 (사내 환경에 맞게 택 1):**
  1. **옵션 A (Snowpipe / Stage):** 인사 DB 변경분을 CSV/Parquet 파일로 생성 후 클라우드 스토리지(S3/Azure Blob) 또는 내부 스테이지로 업로드.
  2. **옵션 B (JDBC 배치 / Airflow / NiFi):** 사내 배치 스케줄러에서 Snowflake Python 커넥터/JDBC를 통해 `MERGE INTO HR_EMPLOYEE_MASTER` 실행.
  3. **옵션 C (Snowflake Openflow / NiFi):** 사내 인사 DB CDC 커넥터로 실시간 복제.

---

### [요청 3] 모바일 앱 연동: 백엔드 API (BFF) 인증 및 중계 (사내 모바일 앱 개발팀)

#### 3.1 연계 아키텍처 (Backend-for-Frontend 패턴)
현장 직원의 모바일 앱이 Snowflake에 직접 커넥션을 맺지 않고, **기존 사내 모바일 앱 백엔드(BFF / API Gateway)**를 경유하여 Snowflake Cortex REST API를 호출합니다.

```
[사내 모바일 앱] ──(사번+간편인증)──▶ [모바일 BFF / API GW] ──(RSA Key-Pair / OAuth JWT)──▶ [Snowflake Cortex API]
```

#### 3.2 모바일 앱팀 개발 요구사항
1. **사용자 인증:** 기존 모바일 앱 인프라의 사번 + 간편인증(생체/PIN)을 유지합니다.
2. **Snowflake Cortex API 호출 중계:**
   * 현장 직원이 챗봇에 질문 입력 시, 백엔드 서버가 Snowflake Cortex Search / Cortex Agent API를 호출.
   * 호출 방식: Snowflake 팀에서 발급한 **전용 서비스 계정(`KSM_MOBILE_CHATBOT_SVC_USER`) 및 RSA 2048bit Private Key 서명 JWT**를 사용하거나, **External OAuth Access Token**을 Authorization 헤더에 첨부하여 전송.
3. **권한 격리 검증:**
   * 모바일 앱 백엔드는 `KSM_FACTORY_WORKER_ROLE` 권한 컨텍스트로 호출하여, 현장 작업자가 허가된 설비/도면 매뉴얼 외의 사내 기밀(인사/재무) 데이터에 접근할 수 없도록 보장.

---

### [요청 4] 보안 및 네트워크 방화벽 정책 (보안/네트워크팀)

1. **아웃바운드 방화벽 정책:**
   * 사내 배치 서버 및 모바일 API Gateway에서 Snowflake 호스트(`lj20513.snowflakecomputing.com`)로의 **HTTPS (TCP 443 포트) 아웃바운드 트래픽 허용**.
2. **보안 감사 및 통제:**
   * 퇴사자 발생 시 사내 인사 DB의 `EMPLOYMENT_STATUS`를 `RESIGNED`로 갱신하면 Snowflake가 5분 내 계정을 강제 비활성화(`DISABLED = true`)하고, 매일 자정 00:00 KST에 전수 검증을 수행하므로 해당 주기의 동작 여부 상호 모니터링 협조.

---

## 3. 정보 교환 및 상호 제공 파라미터 체크리스트

| 단계 | 항목 | 제공 주체 | 수신 주체 | 준비 상태 |
| :---: | :--- | :---: | :---: | :---: |
| **SSO** | Snowflake ACS URL & Entity ID | Snowflake TF | 클라우드/인프라팀 | **준비 완료** |
| **SSO** | Entra ID Issuer URL, SSO URL, X.509 인증서 | 클라우드/인프라팀 | Snowflake TF | **요청 필요** |
| **SCIM** | SCIM Endpoint URL (`/scim/v2/`) & Bearer Token | Snowflake TF | 클라우드/인프라팀 | **발급 준비 완료** |
| **HR 연계** | `HR_EMPLOYEE_MASTER` 테이블 DDL 및 계정 권한 | Snowflake TF | 인사시스템팀 | **배포 완료** |
| **HR 연계** | 일일 인사 DB 추출 및 Snowflake MERGE 스크립트 | 인사시스템팀 | Snowflake TF | **구축 요청** |
| **모바일** | Cortex Search / Agent REST API 규격서 & 서비스 계정 키 | Snowflake TF | 모바일 앱팀 | **준비 완료** |
| **모바일** | 모바일 BFF API Gateway 라우팅 및 챗봇 UI 임베딩 | 모바일 앱팀 | Snowflake TF | **개발 요청** |

---

## 4. 향후 일정 및 협업 계획

1. **1주차:** Entra ID SAML 2.0 SSO 연동 정보 교환 및 테스트 계정 로그인 검증
2. **2주차:** Entra ID SCIM 프로비저닝 연결 및 부서/역할 동기화 테스트
3. **3주차:** 인사 DB ➔ `HR_EMPLOYEE_MASTER` 테이블 정기 전송 배치 연계 및 실시간 계정 생성/퇴사 비활성화 검증
4. **4주차:** 모바일 앱 백엔드(BFF) Cortex API 연동 및 엔드투엔드 챗봇 질의응답 파일럿 오픈
