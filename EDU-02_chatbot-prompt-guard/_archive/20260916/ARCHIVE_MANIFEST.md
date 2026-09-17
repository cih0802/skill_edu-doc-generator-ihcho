<!--
title: 아카이브 대장 — 개선 전 원본 문서 이력
step: -
type: md
summary: 교육자료 개선(1차) 이전 원본 문서 13종의 보관 이력과 대체 문서 매핑. 실습 단계가 아니며 인덱스 생성 대상에서 제외한다.
requires: 없음
next: 없음
-->

# 아카이브 대장 — 개선 전 원본 문서 이력

- **보관 일시:** 2026-09-16
- **보관 사유:** 교육자료 규격 재구성(IMPROVE 1차) 완료로 원본이 대체됨
- **보관 방식:** 삭제하지 않고 이동. 내용은 원본 그대로이며 수정하지 않았다

> ⚠️ 이 폴더의 문서는 **더 이상 실습에 사용하지 않는다.**
> 아래 표의 "대체 문서" 를 사용할 것. 알려진 결함이 그대로 남아 있으므로
> 실행하면 실패하거나 계정에 잔여물이 남을 수 있다.
>
> ⚠️ `_archive/` 는 `99_generate_index.py` 의 인덱스 생성 대상에서 **제외**한다.

---

## 1. 대체 매핑

| 원본 (이 폴더) | 대체 문서 (활성 세트) |
| :--- | :--- |
| `1.환경 초기화 및 권한 구성.sql` | `02_환경초기화_및_RBAC구성.sql` |
| `2.문서 스테이지 및 디렉터리 테이블 설정.sql` | `03_문서스테이지_및_디렉터리테이블.sql` + `04_문서업로드_안내.md` |
| `3.보안 UDF 및 마스킹 함수 생성.sql` | `05_보안UDF_및_PII마스킹.sql` |
| `4.문서 파싱 및 청킹 파이프라인.sql` | `06_문서파싱_및_청킹파이프라인.sql` |
| `5.Stream 및 Serverless Task 파이프라인.sql` | `07_Stream_및_ServerlessTask.sql` |
| `6.Cortex Search 서비스 생성.sql` | `08_CortexSearch_서비스.sql` |
| `7.Cortex Guard 및 Cortex Agent 설정.sql` | `09_가드동적제어_및_검증.sql` + `10_계정레벨_AIGuardrails_및_감사.sql` |
| `8.실습 환경 정리 및 초기화.sql` | `98_리소스정리.sql` |
| `91.초기환경.md` | `95_실습전_기준선.md` |
| `92.작업후환경비교.md` | `96_실습후_대조.md` |
| `93.성능검증_및_성과보고서.md` | `92_성능측정_가이드.md` |
| `학습용참고자료.md` | `90_학습용_참고자료.md` |
| `사내_IT_인프라팀_연계구현_요청서.md` | `91_사내연계_요청서.md` |
| `snowflake_chatbot_guard_architecture_guide.md` | `01_교육자료_정리본.md` (개념·아키텍처) + `10_계정레벨_AIGuardrails_및_감사.sql` (계정 레벨 SQL) |

## 2. 보관 회차

| 회차 | 일시 | 대상 |
| :--- | :--- | :--- |
| 1차 | 2026-09-16 | 원본 13종. 대체 문서가 확정된 것 |
| 2차 | 2026-09-16 | `snowflake_chatbot_guard_architecture_guide.md`. 대체본 `01_교육자료_정리본.md` 작성 완료로 보관 |

## 3. 이 폴더 문서에 남아 있는 주요 결함 (보관 시점 기준)

개선 회차에서 확인된 것만 적는다. 근거는 컴파일·실행·공식 문서 대조다.

| 심각도 | 원본 위치 | 결함 |
| :--- | :--- | :--- |
| 🔴 | 아키텍처 가이드 §1.1·§2, 학습용참고자료 §2.1, `7.…sql` | Cortex Guard 를 "LLM 도달 전 입력 인젝션 차단" 으로 서술. 실제는 **모델 응답(출력)을 Llama Guard 3 로 필터링** 하는 기능 |
| 🔴 | 아키텍처 가이드 §3.1 | Cortex AI Guardrails(`AI_SETTINGS`) 가 `COMPLETE` 호출을 보호하는 것처럼 서술. 실제 적용 대상은 **CoCo / Snowflake CoWork / Cortex Agents 한정** |
| 🔴 | `4.문서 파싱…sql` | `AI_PARSE_DOCUMENT('@stage', file, {...})` 형식이 존재하지 않음 → 컴파일 실패. 현행은 `AI_PARSE_DOCUMENT(TO_FILE(...), {...})` |
| 🔴 | 아키텍처 가이드 §3.3 | 감사 쿼리의 `CREDITS_USED`, `TOKENS_SCANNED` 컬럼 미존재 → 컴파일 실패. 실제는 `TOKENS`, `TOKEN_CREDITS`, `CREDITS_GRANULAR` |
| 🔴 | `7.…sql` `SP_EXECUTE_GUARDED_CHAT` | 답변 텍스트가 아닌 원시 JSON 전체를 반환. 92·93 이 제시한 거부 문구와 실제 반환값이 불일치 |
| 🔴 | 아키텍처 가이드 §3.1·§3.2 ↔ `8.…sql` | `ALTER ACCOUNT SET AI_SETTINGS` / `CORTEX_ENABLED_CROSS_REGION` 이 기존 계정 속성 변경인데 사전값 기록·원복 절 없음 |
| 🔴 | `93.성능검증…md`, `92.작업후환경비교.md` | 측정 절차 없는 정량 수치를 사실로 서술 (`0.38초 P95`, `100+ QPS`, `85% 절감`, `방어율 100%`) |
| 🔴 | `1.…sql` | `CREATE OR REPLACE DATABASE/WAREHOUSE/ROLE` + 접두사 충돌 검사 없음 → 동명 기존 객체 파괴 위험 |
| 🟡 | `91.초기환경.md` | 기준선이 실측과 불일치 (`COMPUTE_WH` Auto-Suspend 600초로 기재, 실제 300초. 웨어하우스 2개 누락) |
| 🟡 | `92.작업후환경비교.md` | DB 소유자를 `KSM_CHATBOT_ADMIN_ROLE` 로 기재. `1.…sql` 은 `ACCOUNTADMIN` 으로 생성 |
| 🟡 | 전체 | 메타 주석·`requires`/`next`·검증 상태 주석·객체 대장 부재. "검증 완료" 총괄 선언 |
