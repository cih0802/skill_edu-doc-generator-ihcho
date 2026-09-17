# Snowflake Cortex 기반 챗봇 가드레일 및 아키텍처 실습 설계서 (검증 완료)

본 문서는 Snowflake CoWork 및 Cortex 환경에서 안전하고 신뢰할 수 있는 RAG / 검색 챗봇을 구축하기 위한 **다중 레이어 보안(Layered Defense)** 설계 및 실제 Snowflake 환경에서 검증된 전체 아키텍처 명세서입니다.

---

## 1. 챗봇 보안 및 입력 금칙: 다중 레이어 방어 체계 (Layered Defense)

스노우플레이크 CoWork / Cortex Agent 환경에서 입력 금칙 및 보안 처리는 단순한 시스템 프롬프트(Instruction) 단일 계층에 의존하지 않고, **플랫폼 레벨**과 **애플리케이션 레벨**이 결합된 다층 방어 구조로 동작합니다.

```
[사용자 입력 (User Prompt)]
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. 플랫폼 레벨: Cortex Guard (런타임 보안 필터)               │
│    - 프롬프트 인젝션(Prompt Injection), 탈옥(Jailbreak) 차단   │
│    - 유해성/악의적 공격 패턴 인프라 계층 원천 차단 (`guardrails: true`)│
└──────────────────────────┬──────────────────────────────────┘
                           │ (안전한 입력 통과)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. 애플리케이션 레벨: CoWork / Cortex Agent Instructions      │
│    - 비즈니스 금지어, 업무 외 주제(인사/연봉/가십 등) 차단     │
│    - 도메인/답변 범위 제한 및 표준 거부 응답 정책 주입       │
└──────────────────────────┬──────────────────────────────────┘
                           │ (정제된 질의 요청)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. 데이터 및 거버넌스 레벨: RAG & Cortex Search + Horizon    │
│    - PII 사전 마스킹 (정규식 기반 주민번호/전화번호/이메일 차단)│
│    - Owner's Rights 저장 프로시저 기반 스테이지 접근 캡슐화 │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 플랫폼 레벨: Cortex Guard (Cortex AI Guardrails)
* **동작 방식:** 사용자 프롬프트가 LLM에 도달하기 전, 스노우플레이크 인프라 계층(Horizon Catalog 보안 엔진)에서 선제적으로 동작하는 **런타임 보안 필터**입니다.
* **주요 역할:** 
  * 프롬프트 인젝션(Prompt Injection) 및 탈옥(Jailbreak) 시도 탐지 및 원천 차단
  * 악의적 공격 패턴, 시스템 프롬프트 유출 시도 차단
* **실행 방식:** LLM 및 Agent 호출 시 옵션 파라미터 `guardrails: true`를 지정하여 런타임 보안 검사 활성화

### 1.2 애플리케이션 레벨: CoWork / Cortex Agent Instructions
* **동작 방식:** 에이전트의 오케스트레이션 레이어에 주입되는 **시스템 프롬프트(System Instruction) 및 비즈니스 거버넌스 규칙**입니다.
* **주요 역할:**
  * 기업 내부 비즈니스 금지어 및 업무 외 범위(Out-of-scope) 필터링
  * 답변 포맷 강제, 모호한 질문에 대한 사내 문서 기반 답변 원칙 강제
  * 보안 위반 시 표준 거부 문구 출력:  
    `"죄송합니다. 해당 요청은 KSM 사내 AI 보안 및 업무 운영 정책상 처리가 제한되어 있습니다."`

---

## 2. 엔드투엔드 데이터 흐름 및 보안 추론 라이프사이클 (End-to-End Data Flow & Cross-Region Inference)

Snowflake CoWork / Cortex Agent 및 애플리케이션에서 질의가 입력되었을 때, 데이터가 안전하게 가드레일을 통과하고 LLM 추론을 거쳐 반환되는 **전체 데이터 흐름(Data Flow)**은 다음과 같이 동작합니다.

```
[1. CoWork / 사용자 질문 입력 (User Prompt)]
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. 1차 플랫폼 보안 검증: Cortex AI Guardrails               │
│    - Snowflake Horizon Catalog 중앙 보안 엔진 연동          │
│    - 프롬프트 인젝션(Direct/Indirect), 탈옥(Jailbreak) 탐지   │
│    - [이상 감지 시] ──▶ LLM 호출 없이 "즉각 차단" 반환       │
└──────────────────────────┬──────────────────────────────────┘
                           │ (안전한 질의 통과)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. 의미 검색 & 임베딩: Cortex Search (로컬 홈 리전)         │
│    - snowflake-arctic-embed-m-v1.5 모델로 질문 벡터화       │
│    - PII 사전 마스킹(주민번호/연락처 제거) 완료 청크 검색   │
└──────────────────────────┬──────────────────────────────────┘
                           │ (최상위 관련 문서 청크 추출)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. RAG 프롬프트 결합 (Context & Instruction Assembly)       │
│    - 사내 비즈니스 지침 + PII 정제 문서 청크 + 사용자 질문  │
└──────────────────────────┬──────────────────────────────────┘
                           │ (mTLS 1.3 암호화 / 전용 백본망)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. 메인 LLM 추론: Cross-Region Inference                   │
│    - CORTEX_ENABLED_CROSS_REGION 기반 글로벌 보안 클러스터  │
│    - 모델 학습 데이터 비저장 (Zero Data Retention for Train)│
│    - 2차 비즈니스 금칙어(임원 연봉, 가십 등) 검증           │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
[6. 정제된 안전한 최종 답변 사용자 전달]
```

### 2.1 단계별 세부 동작 및 보안 원칙

1. **플랫폼 선제 검사 (Cortex AI Guardrails):**
   * 사용자의 입력문이 메인 LLM에 도달하기 전, Horizon 보안 엔진이 인젝션/탈옥 패턴을 밀리초(ms) 단위로 선제 검사합니다.
   * 악의적 공격이 감지되면 메인 LLM 추론을 호출하지 않고 **인프라 계층에서 즉시 차단 응답을 반환**하여 불필요한 토큰 비용 소모와 시스템 프롬프트 유출을 원천 방어합니다.
2. **사내 문서 하이브리드 검색 (Cortex Search):**
   * 계정의 홈 리전 내에서 `snowflake-arctic-embed-m-v1.5` 모델이 질문을 벡터화하고, 사전 마스킹된 청크 테이블(`SILVER.DOCUMENT_CHUNKS`)에서 코사인 유사도와 키워드 매칭을 결합하여 검색합니다.
3. **크로스 리전 안전 추론 (Cross-Region Inference & Data Residency):**
   * **데이터 저장 위치:** 고객의 원본 데이터 및 테이블은 오직 계정이 위치한 **홈 리전**에만 영구 저장됩니다.
   * **전송 구간 암호화:** 추론 페이로드(프롬프트 및 반환값)는 mTLS 1.3 및 클라우드 전용 백본망을 통해 암호화 전송됩니다.
   * **학습 비저장 (Zero Retention):** 전송된 질의와 문서는 LLM 학습에 절대 사용되지 않으며 추론 완료 즉시 메모리에서 휘발됩니다.

---

## 3. Snowflake 공식 스펙 기반 계정 레벨 보안 및 감사 설정

Snowflake 최신 기능 스펙에 따른 계정 레벨 중앙 제어 및 거버넌스 감사 쿼리입니다.

### 3.1 계정 단위 Cortex AI Guardrails 활성화
```sql
-- ACCOUNTADMIN 권한으로 계정 전체의 Cortex Guardrails 중앙 활성화
ALTER ACCOUNT SET AI_SETTINGS = $$
  guardrails:
    advanced_prompt_injection:
      - enabled: true
$$;

-- 현재 계정의 AI_SETTINGS 확인
SHOW PARAMETERS LIKE 'AI_SETTINGS' IN ACCOUNT;
```

### 3.2 크로스 리전 추론 범위 설정 (`CORTEX_ENABLED_CROSS_REGION`)
```sql
-- 최신 프런티어 모델(Llama 3.1, Claude 3.5 등) 및 Guardrails 글로벌 추론 허용
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'; -- 또는 'AWS_GLOBAL', 'AWS_APJ'
```

### 3.3 Guardrails 차단 이력 및 토큰 사용량 감사 뷰
Snowflake Horizon Catalog의 `ACCOUNT_USAGE` 스키마를 통해 실시간 위협 탐지 이력을 모니터링합니다.
```sql
-- 최근 72시간 동안 가드레일에 의해 차단된 위협 요청 조회
SELECT 
    USAGE_TIME,
    USER_NAME,
    AGENTIC_SOURCE,
    GUARDRAILS_SIGNAL, -- TRUE: 공격/인젝션 차단 발생
    CREDITS_USED,
    TOKENS_SCANNED
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_GUARDRAILS_USAGE_HISTORY
WHERE GUARDRAILS_SIGNAL = TRUE
  AND USAGE_TIME >= DATEADD('hour', -72, CURRENT_TIMESTAMP())
ORDER BY USAGE_TIME DESC;
```

---

## 4. 표준 스키마 및 오브젝트 구성 체계 (Medallion + Serving + Ops + Security)

단일 데이터베이스(`KSM_CHATBOT_DB`) 내에서 역할과 보안 수준에 따라 **6대 표준 스키마**로 분리하여 데이터 파이프라인과 거버넌스를 완벽히 격리합니다.

```
KSM_CHATBOT_DB
├── BRONZE     : 원본 비정형 문서 스테이지(@DOC_STAGE), 디렉터리 테이블, 스트림
├── SILVER     : AI_PARSE_DOCUMENT 파싱 및 청킹 정제 데이터 (DOCUMENT_CHUNKS)
├── GOLD       : 비즈니스 도메인 지식 베이스 및 요약 데이터
├── SERVING    : Cortex Search Service, 챗봇 서빙 프로시저 (SP_EXECUTE_GUARDED_CHAT)
├── OPS        : 파이프라인 자동화 Serverless Task, 배치 실행 로그 모니터링
└── SECURITY   : 보안 가드 설정 테이블 (PROMPT_GUARD_CONFIG), PII 마스킹 UDF, 보안 정책
```

### 4.1 보안 가드 제어 오브젝트 위치: `SECURITY` 스키마
* **적재 위치:** `KSM_CHATBOT_DB.SECURITY.PROMPT_GUARD_CONFIG`
* **설계 사유:** 보안 가드 On/Off 설정 테이블 및 PII 마스킹 함수는 일반 사용자가 수정할 수 없도록 `SECURITYADMIN` 또는 전용 `KSM_CHATBOT_ADMIN_ROLE` 권한으로 엄격히 격리되어야 하는 핵심 보안 거버넌스 자산입니다.

---

## 5. 운영 관리: 보안 가드레일 동적 On/Off 제어 체계 (Config-Driven Guardrails)

운영 환경에서 서비스 중단이나 코드 재배포 없이 **SQL 쿼리 1줄로 즉시 챗봇 보안 가드를 활성화(ON) 또는 비활성화(OFF)**할 수 있는 동적 제어 구조를 지원합니다.

### 5.1 동적 On/Off 제어 구조도
```
[운영자 SQL] UPDATE SECURITY.PROMPT_GUARD_CONFIG SET CONFIG_VALUE = 'ON' / 'OFF';
                               │
                               ▼
[SERVING.SP_EXECUTE_GUARDED_CHAT 프로시저 실행]
                               │
                ┌──────────────┴──────────────┐
       [CONFIG_VALUE = 'ON']          [CONFIG_VALUE = 'OFF']
                │                              │
                ▼                              ▼
  - Cortex Guard 활성화 (`guardrails: true`)     - Cortex Guard 비활성화 (`guardrails: false`)
  - 엄격한 비즈니스 Instruction 주입           - 일반 친절 응답 시스템 프롬프트
  - 금칙어 / 프롬프트 인젝션 차단               - 자유 질의 모드 (개발/테스트/디버깅)
```

### 5.2 쿼리 1줄 On/Off 운영 명령어
```sql
-- [보안 가드 끄기 (Disable - 개발/디버깅 모드)]:
UPDATE KSM_CHATBOT_DB.SECURITY.PROMPT_GUARD_CONFIG 
SET CONFIG_VALUE = 'OFF', UPDATED_AT = CURRENT_TIMESTAMP(), UPDATED_BY = CURRENT_USER() 
WHERE CONFIG_KEY = 'ENABLE_PROMPT_GUARD';

-- [보안 가드 켜기 (Enable - 운영 보안 모드)]:
UPDATE KSM_CHATBOT_DB.SECURITY.PROMPT_GUARD_CONFIG 
SET CONFIG_VALUE = 'ON', UPDATED_AT = CURRENT_TIMESTAMP(), UPDATED_BY = CURRENT_USER() 
WHERE CONFIG_KEY = 'ENABLE_PROMPT_GUARD';
```

---

## 6. KSM HQ 챗봇 아키텍처 및 검증된 기능 명세

### 6.1 AI 문서 처리 (Document Processing Pipeline)
| 구분 | Snowflake 기능 / UDF | 상세 역할 및 검증 내용 |
| :--- | :--- | :--- |
| **레이아웃 OCR** | `AI_PARSE_DOCUMENT` | PDF 및 비정형 문서의 표, 단락, 구조를 마크다운 텍스트(`mode: 'LAYOUT'`)로 추출 |
| **개인정보 마스킹** | `SECURITY.MASK_PII_TEXT` | 주민번호(`900101-*******`), 전화번호(`010-****-5678`), 이메일(`[EMAIL_MASKED]`) 사전 치환 |
| **청킹 (Chunking)** | `SPLIT_TEXT_RECURSIVE_CHARACTER` | 문서 구조를 보존하며 1000자 단위/200자 중첩으로 청킹 분할 |
| **보안 캡슐화** | `SP_PROCESS_NEW_DOCUMENTS` | `EXECUTE AS OWNER`로 실행되어 호출자 권한과 무관하게 안전한 정제 데이터만 테이블 적재 |

### 6.2 검색 & 질의 (Search & Reasoning Layer)
| 구분 | 기능 / 모델 | 상세 역할 및 검증 내용 |
| :--- | :--- | :--- |
| **Cortex Search** | `KSM_HQ_SEARCH_SERVICE`<br>(`snowflake-arctic-embed-m-v1.5`) | `CHUNK_TEXT` 대상 하이브리드 의미 검색 서비스 인덱싱 (`TARGET_LAG = '1 hour'`) |
| **동적 보안 서빙** | `SP_EXECUTE_GUARDED_CHAT` | `SECURITY.PROMPT_GUARD_CONFIG` 설정에 따라 실시간 가드레일 On/Off 분기 처리 |
| **오케스트레이션 LLM** | `llama3.1-70b` (또는 `claude-3-5-sonnet`) | 사용자 질의 의도 해석, 검색 컨텍스트 추론 및 자연어 답변 생성 |

### 6.3 데이터 파이프라인 (Automated Ingestion Pipeline)
| 구분 | Snowflake 기능 | 상세 역할 및 검증 내용 |
| :--- | :--- | :--- |
| **스테이지 인덱싱** | `Directory Table` | 내부 스테이지(`@BRONZE.DOC_STAGE`)의 파일 목록 및 메타데이터 자동 추적 |
| **증분 변경 감지** | `STAGE_DOC_STREAM` | 스테이지 디렉터리 테이블의 파일 신규 추가/수정 실시간 추적 |
| **해시 중복 방지** | `CALCULATE_STAGE_FILE_HASH` | Python File Stream 기반 바이너리 MD5 해시를 계산하여 변경된 파일만 증분 처리 |
| **자동화 스케줄링** | `TASK_INGEST_NEW_DOCUMENTS` | Serverless Task로 구성되어 스트림 변경 감지 시 자동으로 파싱 프로시저 트리거 |

---

## 7. 실습용 SQL 스크립트 구성 및 실행 순서 (1~8단계)

모든 스크립트는 실제 환경에서 상호 호환성과 문법 검증이 완료되었습니다.

| 번호 | 스크립트 파일명 | 핵심 수행 내용 |
| :---: | :--- | :--- |
| **1** | `1.환경 초기화 및 권한 구성.sql` | `KSM_CHATBOT_WH`, `KSM_CHATBOT_DB`, 6대 스키마(`BRONZE`~`SECURITY`), RBAC 역할 2종 생성 |
| **2** | `2.문서 스테이지 및 디렉터리 테이블 설정.sql` | 암호화(`SNOWFLAKE_SSE`) 및 디렉터리 테이블이 활성화된 `@DOC_STAGE` 생성 |
| **3** | `3.보안 UDF 및 마스킹 함수 생성.sql` | 정규식 PII 마스킹 SQL UDF (`MASK_PII_TEXT`) 및 Python MD5 계산 UDF 생성 |
| **4** | `4.문서 파싱 및 청킹 파이프라인.sql` | `AI_PARSE_DOCUMENT` + 마스킹 + `SPLIT_TEXT_RECURSIVE_CHARACTER` 저장 프로시저(`SP_PROCESS_NEW_DOCUMENTS`) 구축 |
| **5** | `5.Stream 및 Serverless Task 파이프라인.sql` | 스테이지 감지 `Stream` 생성 및 5분 주기 자동 실행 Serverless `Task` 스케줄링 |
| **6** | `6.Cortex Search 서비스 생성.sql` | `snowflake-arctic-embed-m-v1.5` 기반 `KSM_HQ_SEARCH_SERVICE` 생성 및 `SEARCH_PREVIEW` 검증 |
| **7** | `7.Cortex Guard 및 Cortex Agent 설정.sql` | `SECURITY.PROMPT_GUARD_CONFIG` 설정 테이블 생성, 쿼리 1줄 On/Off 토글 및 동적 서빙 프로시저 검증 |
| **8** | `8.실습 환경 정리 및 초기화.sql` | Task 중지 및 삭제, Search Service, DB, WH, Role 일괄 삭제를 통한 클린업 |

---

## 8. 다중 레이어 보안 검증 테스트 결과 요약

1. **PII 마스킹 단위 테스트:**
   - 입력: `010-9876-5432, 950505-1234567, contact@ksm.co.kr`
   - 출력: `010-****-5432, 950505-*******, [EMAIL_MASKED]` (개인 식별 정보 완전 격리)
2. **Cortex Search 의미 검색 테스트:**
   - `"사내 보안 규정 및 MFA 설정에 대해 알려줘"` 질의 시 정확한 MFA 규정 청크가 유사도 1위로 반환.
3. **보안 가드 ON 상태 검증:**
   - 비즈니스 금칙어(임원 연봉) 및 탈옥/프롬프트 인젝션 시도시 즉각 차단 및 표준 거부 메시지 출력.
4. **보안 가드 OFF 상태 검증:**
   - 쿼리 1줄(`UPDATE ... SET CONFIG_VALUE = 'OFF'`)로 가드 해제 후 개발/디버깅 모드 정상 확인.
