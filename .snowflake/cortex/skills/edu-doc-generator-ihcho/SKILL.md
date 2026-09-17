---
name: edu-doc-generator-ihcho
description: "Generate or improve a complete, SQL-based, hands-on Snowflake training material set (Korean). CREATE mode builds a numbered folder of docs from a learning goal (01 summary, 02-97 step docs, 98 teardown, 99 index script, 00 auto-generated index), critically reviews against best practices and the live account, validates every SQL statement, and guarantees full resource cleanup. IMPROVE mode reads existing training material, runs a severity-ranked gap analysis against the same standard, and applies approved fixes. Use when: user wants training material, lab guide, workshop docs, hands-on tutorial, or wants to improve/audit/update existing training docs. Triggers: 교육자료, 교육자료 생성, 실습자료, 실습 가이드, 워크샵 자료, 핸즈온, 교육자료 개선, 교육자료 보완, 교육자료 검토, 실습자료 업데이트, 최신화, training material, lab guide, workshop material, hands-on tutorial, create training docs, improve training docs, audit lab guide."
---

# 교육자료 생성·개선기 (edu-doc-generator-ihcho)

Snowflake 환경에서 **SQL 기반으로 직접 실습하고 데이터 적재 검증까지 완료할 수 있는
교육자료 세트**를 생성(CREATE)하거나, **기존 교육자료를 같은 기준으로 개선(IMPROVE)** 한다.

이 파일은 **라우터**다. 모드를 판별해 해당 서브스킬로 넘긴다.
문서 규격·정리 요구사항·품질 기준은 두 모드가 공유하며, 필요한 시점에만 로드한다.

---

## Step 1: 모드 판별 — 항상 가장 먼저

### 발화 신호

| 신호 | 모드 |
|------|------|
| "…실습 교육자료 만들어줘", "목표: …" | CREATE |
| "개선", "보완", "업데이트", "최신화", "검토해줘", "빠진 것 채워줘", "고쳐줘" | IMPROVE |
| 기존 폴더명·문서명·경로를 언급 | IMPROVE |

### 작업 공간 스캔 — 발화가 모호할 때의 근거

```bash
cat "/workspace/00_교육자료_카탈로그.md" 2>/dev/null      # 등록된 교육자료 목록 — 가장 먼저 본다
ls -d /workspace/EDU-*/ 2>/dev/null
```

`01_*.md` 또는 `00_index.md` 를 포함한 폴더는 이 스킬의 산출물로 간주한다.
카탈로그에 등록되어 있으면 그 자체가 산출물이라는 근거다.

> ⚠️ 카탈로그에 없는데 `EDU-` 접두사 없이 존재하는 폴더는 **구 규칙 산출물**일 수 있다.
> IMPROVE 대상이 될 수 있으므로 무시하지 않는다.

### 판정 및 라우팅

| 상황 | 조치 |
|------|------|
| 폴더 없음 + 목표 있음 | **Load** `create/SKILL.md` |
| 폴더 있음 + 개선 의도 명확 | **Load** `improve/SKILL.md` |
| 폴더 있음 + 목표만 주어짐 | **⚠️ STOP.** 아래 ⓐ 질문 |
| 폴더 후보가 여러 개 | **⚠️ STOP.** 목록 제시 후 선택받고 재판정 |
| 개선 의도인데 폴더 없음 | **⚠️ STOP.** "개선할 기존 자료를 찾지 못했습니다. 경로를 알려주시거나, 새로 만들까요?" |
| 폴더가 이 스킬 산출물이 아님 | **⚠️ STOP.** 아래 ⓑ 질문 |
| 폴더 없음 + 목표 없음 | **⚠️ STOP.** 목표를 먼저 질문 |

**ⓐ 개선 vs 신규 확인**

> "`<TOPIC_SLUG>` 폴더에 이미 교육자료가 있습니다(문서 N개). 기존 자료를 **개선**할까요, **새로 만들까요**? 새로 만들면 기존 폴더는 그대로 두고 다른 이름으로 생성합니다."

**ⓑ 규격 외 폴더**

> "`<경로>` 는 이 스킬의 문서 규격(번호 체계·메타 주석·인덱스)을 따르지 않습니다. ① 규격에 맞게 **재구성**하면서 개선할까요? ② 규격은 유지하지 않고 **내용만** 개선할까요?"

①이면 `improve/SKILL.md` 로 진입해 규격 정렬을 전면 적용한다.
②면 `improve/SKILL.md` 로 진입하되 구조 결함(`references/30_quality-bar.md` 의 구조 항목)을 갭 분석에서 제외한다.

**모드를 추측해 진행하지 않는다.** 판정이 모호하면 멈추고 질문한다.
**기존 폴더를 확인 없이 덮어쓰지 않는다.**

---

## Step 2: 입력 수집

### CREATE 모드

| 변수 | 필수 | 설명 | 예시 |
|------|------|------|------|
| `GOAL` | 필수 | 학습 목표/주제 | `Openflow로 CDC 기능을 구현하는 실습` |
| `TOPIC_SLUG` | 자동 | 폴더명 (영문 소문자 + 하이픈) | `openflow-cdc` |
| `SOURCE_SYSTEM` | 선택 | 소스 시스템이 명시된 경우 | `PostgreSQL`, `MySQL` |

`GOAL` 이 없으면 **작업을 시작하지 않고** 목표를 먼저 질문한다.

### IMPROVE 모드

| 변수 | 필수 | 설명 |
|------|------|------|
| `TARGET_FOLDER` | 필수 | 개선 대상 폴더 경로 |
| `IMPROVE_SCOPE` | 선택 | 미지정 시 `full` |
| `IMPROVE_REQUEST` | 선택 | 사용자가 지목한 구체적 요청 |

| `IMPROVE_SCOPE` | 범위 |
|----|------|
| `full` | 전체 감사 — 규격 + 정확성 + 정리 + 완결성 (기본값) |
| `accuracy` | 문법·최신 문서 대조·계정 적합성만 |
| `teardown` | 정리 요구사항 준수만 — `references/20_teardown-registry.md` · `references/21_teardown-execution.md` |
| `structure` | 문서 번호·분리 규칙·메타 주석·인덱스만 |
| `extend` | **학습 범위 확장** — 기존 목표에 없던 내용 추가 |
| `specific` | `IMPROVE_REQUEST` 에 지목된 부분만 |

**개선인가 확장인가 — 반드시 구분한다**

| 요청 예시 | 성격 | `IMPROVE_SCOPE` |
|-----------|------|------|
| "잘못된 문법 고쳐줘", "검증해줘", "정리 절차 빠졌어" | 개선 | `full` 등 |
| "MySQL도 실습할 수 있게 추가해줘", "모니터링 단계도 넣어줘" | **확장** | `extend` |

사용자가 "개선"이라 말했어도 실제로는 확장인 경우, 그 사실을 알리고 승인받는다.
확장의 추가 의무는 `improve/SKILL.md` 에 있다.

---
## 조각(shard) 참조 — 필요한 시점에만 로드

서브스킬이 각 단계에서 로드를 지시한다. **라우터 단계에서는 로드하지 않는다.**
조각은 **의미 단위**로 나뉘어 있으므로, 필요한 조각만 골라 읽는다.

| 조각 | 내용 | 로드 시점 |
|------|------|-----------|
| `references/10_output-contract.md` | 산출물 규격 (Output Contract) | 문서를 쓰거나 읽기 직전 |
| `references/11_verification.md` | 검증 규율 (Verification Discipline) | 정확성을 주장하거나 검증 상태를 쓸 때 |
| `references/20_teardown-registry.md` | 정리 준비 — 객체 대장과 사전 스냅샷 | `01_` 객체 대장 작성 / `02_` 스냅샷 작성 시 |
| `references/21_teardown-execution.md` | 정리 실행 — `98_리소스정리.sql` 구성과 검증 | `98_` 작성 / 정리 갭 분석 시 |
| `references/30_quality-bar.md` | 품질 기준 (Quality Bar) | 비판적 검토(CREATE) / 갭 분석(IMPROVE) 시 |

---

## 금지 사항 — 라우팅 단계

아래는 **분기 판단 자체**를 지배하는 규칙이다.
실행 시점의 공통 금지 사항(검증 근거·정리·보안·문서 구조 등)과 모드별 금지 사항은
**각 서브스킬에 함께 실려 있다.** 라우터는 항상 서브스킬로 분기하므로 누락되지 않는다.

**A. 시작 전제 — 임의로 출발하지 않는다**
- **모드를 추측해 진행하지 않는다**
- **`GOAL` 또는 `TARGET_FOLDER` 없이 임의로 시작하지 않는다**

---

## Stopping Points

- ✋ Step 1: 모드 판정이 모호할 때 (ⓐ / ⓑ / 후보 다수 / 목표 없음)

이후 중단점은 각 서브스킬에 정의되어 있다.

---

## Output

| 모드 | 산출물 |
|------|--------|
| CREATE | `/workspace/EDU-<NN>_<TOPIC_SLUG>/` 에 `00_`~`99_` 문서 세트 + 카탈로그 등록 (`create/SKILL.md` 참고) |
| IMPROVE | 승인된 결함이 반영된 기존 문서 + 누락 문서 보완 + 누적된 검토 이력 (`improve/SKILL.md` 참고) |
