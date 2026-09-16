---
name: edu-doc-create
description: 신규 교육자료 생성 워크플로. 학습 목표로부터 01_ 정리본, 02_~97_ 단계 문서, 98_ 정리 문서, 99_ 인덱스 스크립트를 만들고 비판적 검토와 SQL 검증을 거친다.
parent_skill: edu-doc-generator-ihcho
---

# CREATE 모드 — 신규 교육자료 생성

## When to Load

라우터(`SKILL.md`) 모드 판정 결과가 **CREATE** 일 때. `GOAL` 이 확보된 상태여야 한다.

## Prerequisites

- 모드 판별 완료
- `GOAL` 확보 (없으면 라우터에서 질문했어야 함)

> **참조 경로**: 아래 `../references/...` 는 스킬 루트의 `references/` 폴더다.
> 이 파일이 하위 폴더에 있으므로 상위 경로로 표기한다.

---

## Workflow

### STEP C0. 목표 확정 및 폴더 준비
1. `GOAL`을 확인하고, 모호하면 **질문 1개로만** 명확화한다.
2. `TOPIC_SLUG` 를 결정한다.
3. **대상 폴더가 이미 존재하는지 확인한다.**
   ```bash
   ls /workspace/<TOPIC_SLUG>/ 2>/dev/null
   ```
   파일이 있으면 **⚠️ STOP** — 라우터(`SKILL.md`)의 ⓐ 질문으로 돌아간다.
4. 폴더를 생성한다.

**⚠️ STOP**: `GOAL` / `TOPIC_SLUG` / 예상 문서 구성을 제시하고 승인받는다.

주제에 따라 실습 구성이 갈리는 선택지(소스 시스템, 배포 방식 등)가 있으면
이 시점에 **하나만** 질문해 확정한다. 문서 전체 구조가 여기서 결정된다.

### STEP C1. 계정 적합성 사전 확인

문서를 쓰기 **전에** 이 계정에서 실습이 가능한지 확인한다.
불가능한 실습의 문서를 쓰는 것은 낭비이며, 검토 단계(C3)까지 가서 발견하면 되돌리는 비용이 크다.

```sql
SELECT CURRENT_ACCOUNT(), CURRENT_REGION(), CURRENT_ROLE(),
       CURRENT_USER(), CURRENT_VERSION();
```

주제 관련 기능의 활성화 여부를 실제 SQL로 확인한다
(예: `SHOW <FEATURE> ...`, `SHOW PARAMETERS LIKE '...' IN ACCOUNT`).
최신 문법과 제약은 `cortex search docs "<주제>"` 로 확인한다.

**⚠️ STOP**: 계정 제약으로 실습 자체가 불가하면 진행 전에 알리고 대안을 제시한다.

### STEP C2. 교육자료 초안 작성 (`01_교육자료_정리본.md`)

**Load** `../references/teardown.md` — 객체 대장과 명명 규칙 작성에 필요하다.
포함해야 할 내용:
- 학습 목표 및 완료 시 달성 상태
- 사전 준비물 / 필요 권한 / 필요 리소스
- 아키텍처 개요 (텍스트 다이어그램 허용)
- 핵심 개념 설명
- **객체 대장** — `../references/teardown.md` 1장
- **명명 규칙** — `../references/teardown.md` 2장
- 전체 실습 단계 요약 (문서 번호와 매핑, `98_` 정리 문서 포함)
- 예상 소요 시간
- **비용 주의 — 지속 과금 객체와 정리 필요성**
- 트러블슈팅 참고 사항

### STEP C3. 비판적 검토 및 업데이트 (생략 금지)

**Load** `../references/quality-bar.md` — 검토 기준.

**Load** `../references/output-contract.md` — 검증 규율(근거 우선순위).
`../references/quality-bar.md` 를 기준으로 초안을 스스로 검토한다. 근거는 `../references/output-contract.md` 의 검증 규율을 따른다.

검토 결과를 `01_` 문서에 반영하고, 발견한 문제와 조치를 문서 하단
`## 검토 이력` 의 `### 1차 (생성 시)` 로 기록한다.

이 이력은 이후 IMPROVE 모드가 중복 지적을 피하는 근거가 되므로,
**미검증 항목과 그 이유를 반드시 남긴다.**

### STEP C4. 실습 문서 생성 (`02_` ~ `97_`)

**Load** `../references/output-contract.md` (아직 로드하지 않았다면) — 분리 규칙, 메타 주석, SQL 작성 원칙.
- 문서 분리 규칙 적용 — `../references/output-contract.md`
- 모든 파일에 메타 주석 블록 포함 — `../references/output-contract.md`
- **`02_` 시작부에 사전 스냅샷 배치** — `../references/teardown.md` 3장
- SQL 문서 작성 원칙 적용 — `../references/output-contract.md` 5장

### STEP C5. 정리 문서 생성 (`98_리소스정리.sql`) — 생략 금지
- `../references/teardown.md` 5장의 8개 필수 구성 요소를 모두 포함
- `01_` 객체 대장과 **1:1 대조**
- `../references/teardown.md` 6장 안전장치 적용
- 외부 정리가 분량이 크면 별도 `.md` 로 분리 (예: `97_외부리소스_정리.md`)

**⚠️ 자체 검증**: `01_` 객체 대장 항목 수와 `98_` 삭제 대상 수를 세어
**1:1 일치**를 확인한다. 불일치하면 어느 쪽이 누락인지 판단해 수정한다.

### STEP C6. 쿼리 검증 (생략 금지)
`../references/output-contract.md` 의 검증 규율에 따라 실행/컴파일 검증하고, 실패는 **수정 후 재검증**한다.
미검증 항목은 `../references/output-contract.md` 의 미검증 표기 의무에 따라 표기한다.

### STEP C7. 인덱스 스크립트 생성 및 실행 (`99_` → `00_`)
`99_generate_index.py` 요구사항:
- 스크립트가 위치한 폴더를 스캔
- `00_index.md` 자체는 목록에서 제외
- 파일명 접두 번호 기준 정렬 (빈 번호 허용)
- 최상단 메타 주석(`/* */`, `<!-- -->`, `""" """`) 파싱 → `title`, `step`, `type`, `summary`, `requires`, `next` 추출
- 메타 주석 없으면 `summary: (요약 없음)` 처리 + **경고 출력**
- 마크다운 표 + 실습 진행 순서 + 의존 관계를 `00_index.md` 에 기록
- **재실행 시 항상 덮어쓰기(멱등)**

작성 후 실제로 실행한다.

```bash
cd /workspace/<TOPIC_SLUG> && python3 99_generate_index.py
```

경고가 출력되면 원인(메타 주석 누락 등)을 해결한 뒤 재실행한다.
**멱등성을 확인한다** — 2회 실행 결과가 동일해야 한다.

### STEP C8. 최종 보고
- 생성된 폴더 경로와 문서 개수
- **검증된 항목 / 미검증 항목** (숨기지 않는다)
- 실습 시작 방법 (`00_index.md` 부터)

**⚠️ STOP**: 최종 리뷰.

---

---

## Stopping Points

- ✋ C0: 대상 폴더에 이미 파일이 있을 때
- ✋ C0: `GOAL` / `TOPIC_SLUG` / 예상 문서 구성을 제시하고 승인받는다
- ✋ C1: 계정 제약으로 실습 자체가 불가하면 진행 전에 알리고 대안을 제시한다
- ✋ C8: 최종 리뷰

---

## CREATE 전용 금지 사항

라우터의 공통 금지 사항에 추가한다.

- **기존 폴더를 확인 없이 덮어쓰지 않는다**
- 문서 번호를 중복하지 않는다
- 필수 문서(`01_`, `98_`, `99_`)를 빼놓고 마무리하지 않는다
- **계정 적합성 확인(STEP C1) 없이 문서를 쓰지 않는다** — 불가능한 실습의 문서는 낭비다

---

## Output

`/workspace/<TOPIC_SLUG>/`
- `00_index.md` — 스크립트 자동 생성
- `01_교육자료_정리본.md` — 객체 대장 + 검토 이력 포함
- `02_` ~ `97_` — 단계별 `.sql` / `.md`
- `98_리소스정리.sql` — 필수
- `99_generate_index.py`
