#!/usr/bin/env python3
"""
교육자료 스킬 빌더 — '교육자료 생성 프롬프트.md' 로부터 스킬 6파일을 결정적으로 조립한다.

산문 절차 대신 코드로 고정하는 이유:
  재현 실험 4회차에서 매번 다른 누락이 발생했다.
    1차 변환 규칙 없음 / 2차 눈으로 찾아 누락 / 3차 검출 범위 좁음 / 4차 치환만 하고 삽입 누락
  변환표·로드 배치·필수 절을 코드로 고정하면 이 부류의 누락이 원리적으로 불가능하다.

위치: 스킬 폴더 **밖**에 둔다. 스킬을 처음 만들 때는 스킬 폴더가 없으므로
      안에 두면 부트스트랩이 불가능하다.

사용법:
    python3 build_skill.py --check            # 먼저 차이만 확인 (권장)
    python3 build_skill.py                    # 기본 경로로 빌드
    python3 build_skill.py --spec <경로> --out <경로>
    python3 build_skill.py --check            # 빌드하지 않고 기존 산출물과 차이만 보고

멱등: 같은 입력에 대해 항상 같은 출력을 쓴다.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

# ───────────────────────────────────────────────────────────────
# 고유 결정값 — '교육자료 스킬 패키징.md' 2·5장과 대응
# ───────────────────────────────────────────────────────────────
SKILL_NAME = "edu-doc-generator-ihcho"

DEFAULT_SPEC = Path(__file__).resolve().parent / "교육자료 생성 프롬프트.md"
DEFAULT_OUT = Path(f"/workspace/.snowflake/cortex/skills/{SKILL_NAME}")

TRIGGERS = (
    "교육자료, 교육자료 생성, 실습자료, 실습 가이드, 워크샵 자료, 핸즈온, "
    "교육자료 개선, 교육자료 보완, 교육자료 검토, 실습자료 업데이트, 최신화, "
    "training material, lab guide, workshop material, hands-on tutorial, "
    "create training docs, improve training docs, audit lab guide"
)

ROUTER_DESC = (
    "Generate or improve a complete, SQL-based, hands-on Snowflake training material set (Korean). "
    "CREATE mode builds a numbered folder of docs from a learning goal (01 summary, 02-97 step docs, "
    "98 teardown, 99 index script, 00 auto-generated index), critically reviews against best practices "
    "and the live account, validates every SQL statement, and guarantees full resource cleanup. "
    "IMPROVE mode reads existing training material, runs a severity-ranked gap analysis against the same "
    "standard, and applies approved fixes. Use when: user wants training material, lab guide, workshop "
    "docs, hands-on tutorial, or wants to improve/audit/update existing training docs. "
    f"Triggers: {TRIGGERS}."
)

# 구조 맵 — 원본 장 → 스킬 파일
# title: 참조 파일의 자기 제목. 원본 장 제목을 그대로 쓰면 "## 4. 정리…" 처럼
#        원본 좌표가 남아 파일 안에서 번호가 어긋난다.
#
# 명세 장 순서는 참조 파일 단위로 인접하게 배치되어 있다.
#   0·1 → 라우터 | 2·3 → output-contract | 4 → teardown
#   5 → quality-bar | 6 → create | 7 → improve | 8 → 라우터 + 서브스킬
REFERENCES = {
    "output-contract.md": {
        "chapters": [2, 3],
        "title": "산출물 규격 및 검증 규율",
        "name": "edu-doc-output-contract",
        "desc": "교육자료 산출물 규격과 검증 규율. 폴더 구조, 문서 번호, 분리 규칙, 메타 주석 포맷, "
                "근거 우선순위, 실행 vs 컴파일 판단, 미검증 표기 의무. CREATE/IMPROVE 두 모드 공통.",
    },
    "teardown.md": {
        "chapters": [4],
        "title": "정리(Teardown) 요구사항 — 실습 전후 상태 동일성",
        "name": "edu-doc-teardown",
        "desc": "교육자료 정리(Teardown) 요구사항. 왕복 가능성, 객체 대장, 명명 규칙, 사전 스냅샷, "
                "이중 정리 구조, 98_리소스정리.sql 8개 필수 구성, 안전장치.",
    },
    "quality-bar.md": {
        "chapters": [5],
        "title": "품질 기준 (Quality Bar)",
        "name": "edu-doc-quality-bar",
        "desc": "교육자료 품질 기준. 구조/내용/정확성/정리 4개 영역 체크리스트와 "
                "IMPROVE 갭 분석용 심각도 매핑.",
    },
}

OC = "`../references/output-contract.md`"
TD = "`../references/teardown.md`"
QB = "`../references/quality-bar.md`"
oc, td, qb = (s.replace("../", "") for s in (OC, TD, QB))

# ── 치환ⓐ: 명세의 이름 기반 참조 → 스킬 파일 경로 ─────────────────
# 명세는 제품 중립이라 스킬 파일명을 모른다. 여기서 경로를 주입한다.
# 키는 **장 번호를 담지 않는다** — 명세의 장이 재배치돼도 깨지지 않게 하기 위함.
# 키가 명세에 없으면 빌드가 실패한다(check_subs). 조용한 무효화를 막는 장치다.
#
# 라우터(0·1·8장)용
SUB_ROUTER: list[tuple[str, str]] = [
    ("## 0. 모드 판별 (MODE) — 항상 가장 먼저 수행", "## Step 1: 모드 판별 — 항상 가장 먼저"),
    ("## 1. 입력 (INPUT)", "## Step 2: 입력 수집"),
    ("| 관련 폴더 없음 + 목표 있음 | **CREATE** 로 진행 |",
     "| 폴더 없음 + 목표 있음 | **Load** `create/SKILL.md` |"),
    ("| 관련 폴더 있음 + 개선 의도 명확 | **IMPROVE** 로 진행 |",
     "| 폴더 있음 + 개선 의도 명확 | **Load** `improve/SKILL.md` |"),
    ("①이면 IMPROVE 모드의 규격 정렬을 전면 적용한다.",
     "①이면 `improve/SKILL.md` 로 진입해 규격 정렬을 전면 적용한다."),
    ("②면 IMPROVE 모드로 진입하되 구조 결함(품질 기준의 구조 항목)을 갭 분석에서 제외한다.",
     f"②면 `improve/SKILL.md` 로 진입하되 구조 결함({qb} 의 구조 항목)을 갭 분석에서 제외한다."),
    ("확장의 추가 의무는 IMPROVE 모드에 있다.",
     "확장의 추가 의무는 `improve/SKILL.md` 에 있다."),
    ("| `teardown` | 정리 요구사항 준수만 |", f"| `teardown` | 정리 요구사항 준수만 — {td} |"),
    # 8장 공통 금지 — 라우터는 참조를 로드하지 않으므로 파일명을 명시한다
    ('그것을 **대장 (b) 속성 변경 행으로 등재하고 "속성 변경(Mutation)" 절의 3단계',
     f'그것을 **대장 (b) 속성 변경 행으로 등재하고 {td} 의 "속성 변경(Mutation)" 절 3단계'),
]

# 서브스킬(6·7·8장)용 — 두 모드가 공유
SUB_LEAF: list[tuple[str, str]] = [
    ("모드 판별의 확인 질문으로 돌아간다", "라우터(`SKILL.md`)의 ⓐ 질문으로 돌아간다"),
    ("- **객체 대장**", f"- **객체 대장** — {TD} 1장"),
    ("- **명명 규칙**", f"- **명명 규칙** — {TD} 2장"),
    ("품질 기준으로 초안을 스스로 검토한다. 근거는 검증 규율을 따른다.",
     f"{QB} 를 기준으로 초안을 스스로 검토한다. 근거는 {OC} 의 검증 규율을 따른다."),
    ("- 문서 분리 규칙 적용", f"- 문서 분리 규칙 적용 — {OC}"),
    ("- 모든 파일에 메타 주석 블록 포함", f"- 모든 파일에 메타 주석 블록 포함 — {OC}"),
    ("- **`02_` 시작부에 사전 스냅샷 배치**", f"- **`02_` 시작부에 사전 스냅샷 배치** — {TD} 3장"),
    ("- 정리 문서의 8개 필수 구성 요소를 모두 포함", f"- {TD} 5장의 8개 필수 구성 요소를 모두 포함"),
    ("- 안전장치 적용", f"- {TD} 6장 안전장치 적용"),
    ("- SQL 문서 작성 원칙 적용", f"- SQL 문서 작성 원칙 적용 — {OC} 5장"),
    ("검증 규율에 따라 실행/컴파일 검증하고", f"{OC} 의 검증 규율에 따라 실행/컴파일 검증하고"),
    ("미검증 항목은 미검증 표기 의무에 따라 표기한다.",
     f"미검증 항목은 {OC} 의 미검증 표기 의무에 따라 표기한다."),
    ("품질 기준을 체크리스트로 삼아", f"{QB} 를 체크리스트로 삼아"),
    ("**정확성 판정은 검증 규율을 따른다.**", f"**정확성 판정은 {OC} 의 검증 규율을 따른다.**"),
    ("- 수정 근거를 반드시 확보한 뒤 고친다 (검증 규율)",
     f"- 수정 근거를 반드시 확보한 뒤 고친다 ({OC})"),
    ("- 검증 못 한 것은 미검증으로 표기한다 (미검증 표기 의무)",
     f"- 검증 못 한 것은 미검증으로 표기한다 ({OC})"),
    ("수정한 SQL을 검증 규율에 따라 다시 검증한다.",
     f"수정한 SQL을 {OC} 의 검증 규율에 따라 다시 검증한다."),
    ("### 문서 추가·삭제·번호 변경 규칙 (STEP I4 공통 규칙)",
     "### 문서 추가·삭제·번호 변경 규칙 (STEP I4 공통)"),
    ("그 번호를 사용한다. 번호 변경 불필요 — 번호는 연속일 필요가 없다",
     f"그 번호를 사용한다. 번호 변경 불필요 — 번호는 연속일 필요가 없다 ({OC})"),
    ("| 문서 **분할** — 한 문서가 SQL/외부 작업 혼재 | 문서 분리 규칙에 따라 분리.",
     f"| 문서 **분할** — 한 문서가 SQL/외부 작업 혼재 | {OC} 의 분리 규칙에 따라 분리."),
]

# ── 3단계ⓑ 삽입: STEP 헤딩 아래 **Load** 지시 ────────────────────
# 4차 회귀의 원인 — 치환과 삽입은 다른 동작이다. 코드로 분리해 고정한다.
LOADS: dict[str, dict[str, list[tuple[str, str]]]] = {
    "create": {
        "### STEP C2. 교육자료 초안 작성 (`01_교육자료_정리본.md`)":
            [(TD, "객체 대장과 명명 규칙 작성에 필요하다.")],
        "### STEP C3. 비판적 검토 및 업데이트 (생략 금지)":
            [(QB, "검토 기준."), (OC, "검증 규율(근거 우선순위).")],
        "### STEP C4. 실습 문서 생성 (`02_` ~ `97_`)":
            [(f"{OC} (아직 로드하지 않았다면)", "분리 규칙, 메타 주석, SQL 작성 원칙.")],
    },
    "improve": {
        "### STEP I1. 전체 읽기 (생략 금지)":
            [(OC, "규격 위반을 판별하려면 규격을 알아야 한다.")],
        "### STEP I2. 갭 분석 (Gap Analysis)":
            [(QB, "체크리스트와 심각도 매핑."),
             (TD, "`IMPROVE_SCOPE` 가 `full` 또는 `teardown` 일 때.")],
    },
}

PATH_NOTE = (
    "> **참조 경로**: 아래 `../references/...` 는 스킬 루트의 `references/` 폴더다.\n"
    "> 이 파일이 하위 폴더에 있으므로 상위 경로로 표기한다.\n"
)

OUTPUT_CREATE = """`/workspace/<TOPIC_SLUG>/`
- `00_index.md` — 스크립트 자동 생성
- `01_교육자료_정리본.md` — 객체 대장 + 검토 이력 포함
- `02_` ~ `97_` — 단계별 `.sql` / `.md`
- `98_리소스정리.sql` — 필수
- `99_generate_index.py`"""

OUTPUT_IMPROVE = """- 승인된 결함이 반영된 기존 문서
- 누락되었던 필수 문서 (`98_`, `99_` 등)
- `01_` 검토 이력에 누적된 새 회차
- 재생성된 `00_index.md`"""


# ───────────────────────────────────────────────────────────────
# 파싱
# ───────────────────────────────────────────────────────────────
def load_chapters(spec: Path) -> dict[int, str]:
    """'## N. 제목' 을 경계로 원본 명세를 장 단위로 분해한다."""
    lines = spec.read_text(encoding="utf-8").split("\n")
    starts = {int(m.group(1)): i for i, l in enumerate(lines)
              if (m := re.match(r"^## (\d)\. ", l))}
    if not starts:
        sys.exit("[오류] 명세에서 '## N. ' 형식의 장을 찾지 못했습니다.")
    order = sorted(starts)
    out = {}
    for idx, ch in enumerate(order):
        end = starts[order[idx + 1]] if idx + 1 < len(order) else len(lines)
        out[ch] = "\n".join(lines[starts[ch]:end]).rstrip()
    missing = {0, 1, 2, 3, 4, 5, 6, 7, 8} - set(out)
    if missing:
        sys.exit(f"[오류] 필수 장 누락: {sorted(missing)}")
    return out


def check_subs(spec_text: str) -> None:
    """치환 키가 명세에 실제로 존재하는지 확인한다.

    키가 명세와 어긋나면 `str.replace` 는 조용히 아무 일도 하지 않는다.
    그 결과 좌표·미변환 문구가 스킬에 그대로 새어 나가고, verify 는
    숫자 좌표만 검사하므로 통과해 버린다. 실측: 스테일 키 14개가
    22/22 통과 상태에서 누적되어 있었다. 그래서 빌드 단계에서 막는다.
    """
    stale = [(name, k)
             for name, tbl in (("SUB_ROUTER", SUB_ROUTER), ("SUB_LEAF", SUB_LEAF))
             for k, _ in tbl if k not in spec_text]
    if stale:
        msg = "\n".join(f"  [{n}] {k[:90]}" for n, k in stale)
        sys.exit(
            f"[오류] 명세에 없는 치환 키 {len(stale)}개 — 명세가 바뀌었다면 키도 고쳐야 한다.\n{msg}"
        )


def prohibition(ch8: str, heading: str) -> str:
    m = re.search(rf"^### {re.escape(heading)}\n(.*?)(?=^### |\Z)", ch8, re.S | re.M)
    if not m:
        sys.exit(f"[오류] 8장에서 '{heading}' 절을 찾지 못했습니다.")
    return m.group(1).strip()


def stopping_points(body: str, prefix: str) -> str:
    """본문의 ⚠️ STOP 을 STEP 번호와 함께 요약 목록으로 재수집한다.

    원본 명세는 중단점을 본문에 흩어 놓기만 하므로, 이 절이 없으면
    모델이 전체 중단 지점을 파악하지 못한다 (실측: 22개 → 13개).
    """
    out: list[str] = []
    cur: str | None = None
    for line in body.split("\n"):
        if m := re.match(rf"^### STEP ({prefix}\d)\.", line):
            cur = m.group(1)
        if "⚠️ STOP" in line and cur:
            txt = re.sub(r"\*\*|⚠️ STOP:?", "", line).strip(" -—.:")
            if "파일이 있으면" in line:
                txt = "대상 폴더에 이미 파일이 있을 때"
            out.append(f"- ✋ {cur}: {txt[:75]}")
    return "\n".join(dict.fromkeys(out))


# ───────────────────────────────────────────────────────────────
# 조립
# ───────────────────────────────────────────────────────────────
def frontmatter(name: str, desc: str, parent: str | None = None) -> str:
    p = f"parent_skill: {parent}\n" if parent else ""
    return f"---\nname: {name}\ndescription: {desc}\n{p}---\n\n"


def apply_subs(text: str, subs: list[tuple[str, str]]) -> str:
    for a, b in subs:
        text = text.replace(a, b)
    return text


def insert_loads(text: str, loads: dict[str, list[tuple[str, str]]]) -> str:
    for heading, items in loads.items():
        if heading not in text:
            sys.exit(f"[오류] 로드 지시를 삽입할 헤딩을 찾지 못했습니다: {heading}")
        block = "\n".join(f"\n**Load** {ref} — {why}" for ref, why in items)
        text = text.replace(heading, heading + "\n" + block, 1)
    return text


def assemble_reference(chapters: list[str], title: str) -> str:
    """원본 장들을 독립 참조 문서로 재구성한다.

    참조 파일은 서브스킬이 단독으로 로드해 읽는다. 따라서 원본 장 번호를
    그대로 두면 파일 안에서 좌표가 어긋난다 — `## 3. 정리 요구사항` 은
    "3장"이 없는 문서에서 의미가 없다.

    변환 내용:
      `## N. 제목`   → 제거 (파일 제목 `# title` 로 대체)
      `### N.M 제목` → `## M'. 제목`  (여러 장을 합칠 때 M' 는 통짜 연번)
      본문의 `N.M`   → 새 연번으로 치환
    """
    renum: dict[str, str] = {}
    seq = 0
    # 1차 통과 — 절 번호 매핑을 만든다
    for chunk in chapters:
        for line in chunk.split("\n"):
            if m := re.match(r"^### (\d)\.(\d+) ", line):
                seq += 1
                renum[f"{m.group(1)}.{m.group(2)}"] = str(seq)

    out: list[str] = [f"# {title}", ""]
    for chunk in chapters:
        body: list[str] = []
        for line in chunk.split("\n"):
            if re.match(r"^## \d\. ", line):
                continue                                   # 장 제목 제거
            if m := re.match(r"^### (\d)\.(\d+) (.*)$", line):
                key = f"{m.group(1)}.{m.group(2)}"
                body.append(f"## {renum[key]}. {m.group(3)}")
                continue
            body.append(line)
        out.append("\n".join(body).strip())

    text = "\n\n---\n\n".join(out[2:])
    # 본문 안의 상호 참조 절 번호도 새 번호로
    for old, new in sorted(renum.items(), key=lambda kv: -len(kv[0])):
        text = text.replace(f"{old}의 ", f"{new}장의 ").replace(f"{old} 참고", f"{new}장 참고")
    return f"# {title}\n\n{text}\n"


def build(spec: Path) -> dict[str, str]:
    check_subs(spec.read_text(encoding="utf-8"))
    CH = load_chapters(spec)
    files: dict[str, str] = {}

    # references — 원본 장을 독립 문서로 재구성 (자기 제목 + 절 번호 재부여)
    for fname, cfg in REFERENCES.items():
        body = assemble_reference([CH[c] for c in cfg["chapters"]], cfg["title"])
        files[f"references/{fname}"] = frontmatter(cfg["name"], cfg["desc"]) + body

    # 라우터 — 0·1장 + 8장 공통 금지
    router = apply_subs(f"""{frontmatter(SKILL_NAME, f'"{ROUTER_DESC}"')}# 교육자료 생성·개선기 ({SKILL_NAME})

Snowflake 환경에서 **SQL 기반으로 직접 실습하고 데이터 적재 검증까지 완료할 수 있는
교육자료 세트**를 생성(CREATE)하거나, **기존 교육자료를 같은 기준으로 개선(IMPROVE)** 한다.

이 파일은 **라우터**다. 모드를 판별해 해당 서브스킬로 넘긴다.
문서 규격·정리 요구사항·품질 기준은 두 모드가 공유하며, 필요한 시점에만 로드한다.

---

{CH[0]}

{CH[1]}

---

## 공유 참조 — 필요한 시점에만 로드

서브스킬이 각 단계에서 로드를 지시한다. **라우터 단계에서는 로드하지 않는다.**

| 참조 | 내용 | 로드 시점 |
|------|------|-----------|
| `references/output-contract.md` | 폴더 구조, 문서 번호, 분리 규칙, 메타 주석, 검증 규율 | 문서를 쓰거나 읽기 직전 |
| `references/teardown.md` | 객체 대장, 사전 스냅샷, `98_` 필수 구성, 안전장치 | 객체 대장 작성 / `98_` 작업 / 정리 갭 분석 시 |
| `references/quality-bar.md` | 품질 기준 + 심각도 매핑 | 비판적 검토(CREATE) / 갭 분석(IMPROVE) 시 |

---

## 공통 금지 사항

모드별 금지 사항은 각 서브스킬에 있다.

{prohibition(CH[8], '공통')}

---

## Stopping Points

- ✋ Step 1: 모드 판정이 모호할 때 (ⓐ / ⓑ / 후보 다수 / 목표 없음)

이후 중단점은 각 서브스킬에 정의되어 있다.

---

## Output

| 모드 | 산출물 |
|------|--------|
| CREATE | `/workspace/<TOPIC_SLUG>/` 에 `00_`~`99_` 문서 세트 (`create/SKILL.md` 참고) |
| IMPROVE | 승인된 결함이 반영된 기존 문서 + 누락 문서 보완 + 누적된 검토 이력 (`improve/SKILL.md` 참고) |
""", SUB_ROUTER)
    files["SKILL.md"] = router

    # 서브스킬 — 6·7장 본문 + 8장 모드별 금지 + 필수 6개 절
    leaf_cfg = [
        ("create", 6, "C", "edu-doc-create",
         "신규 교육자료 생성 워크플로. 학습 목표로부터 01_ 정리본, 02_~97_ 단계 문서, "
         "98_ 정리 문서, 99_ 인덱스 스크립트를 만들고 비판적 검토와 SQL 검증을 거친다.",
         "CREATE 모드 — 신규 교육자료 생성",
         "라우터(`SKILL.md`) 모드 판정 결과가 **CREATE** 일 때. `GOAL` 이 확보된 상태여야 한다.",
         "- 모드 판별 완료\n- `GOAL` 확보 (없으면 라우터에서 질문했어야 함)",
         "CREATE 모드 전용", OUTPUT_CREATE, ""),
        ("improve", 7, "I", "edu-doc-improve",
         "기존 교육자료 개선 워크플로. 전체 문서를 읽고 품질 기준에 따라 심각도별 갭 분석을 "
         "수행한 뒤, 승인받은 항목만 최소 변경으로 반영하고 검토 이력을 누적한다.",
         "IMPROVE 모드 — 기존 교육자료 개선",
         "라우터(`SKILL.md`) 모드 판정 결과가 **IMPROVE** 일 때. `TARGET_FOLDER` 가 확보된 상태여야 한다.",
         "- 모드 판별 완료\n- `TARGET_FOLDER` 확보\n"
         "- 규격 외 폴더인 경우: ①(규격 재구성) / ②(내용만) 확정 완료",
         "IMPROVE 모드 전용", OUTPUT_IMPROVE,
         "\n> `✋ I3` (개선 계획 승인)은 **가장 중요한 중단점**이다. "
         "이 승인 없이 파일을 수정하지 않는다.\n"),
    ]

    for (mode, ch, pre, name, desc, title, when, prereq,
         proh_head, output, stop_note) in leaf_cfg:
        body = re.sub(rf"^## {ch}\..*?\n+", "", CH[ch], flags=re.S | re.M)
        body = insert_loads(body, LOADS[mode])
        body = apply_subs(body, SUB_LEAF)
        stops = stopping_points(body, pre)

        files[f"{mode}/SKILL.md"] = (
            frontmatter(name, desc, SKILL_NAME)
            + f"# {title}\n\n## When to Load\n\n{when}\n\n"
            + f"## Prerequisites\n\n{prereq}\n\n{PATH_NOTE}\n---\n\n"
            + f"## Workflow\n\n{body}\n\n---\n\n"
            + f"## Stopping Points\n\n{stops}\n{stop_note}\n---\n\n"
            + f"## {proh_head.replace(' 모드 전용', '')} 전용 금지 사항\n\n"
            + f"라우터의 공통 금지 사항에 추가한다.\n\n{apply_subs(prohibition(CH[8], proh_head), SUB_LEAF)}\n\n---\n\n"
            + f"## Output\n\n{output}\n"
        )

    return files


# ───────────────────────────────────────────────────────────────
# 엔트리포인트
# ───────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description="교육자료 스킬 빌더")
    ap.add_argument("--spec", type=Path, default=DEFAULT_SPEC, help="워크플로 명세 md 경로")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="스킬 출력 폴더")
    ap.add_argument("--check", action="store_true", help="쓰지 않고 차이만 보고")
    a = ap.parse_args()

    if not a.spec.exists():
        return int(bool(sys.stderr.write(f"[오류] 명세 없음: {a.spec}\n"))) or 1

    files = build(a.spec)
    print(f"명세: {a.spec}\n출력: {a.out}\n")

    changed = 0
    for rel, content in sorted(files.items()):
        target = a.out / rel
        old = target.read_text(encoding="utf-8") if target.exists() else ""
        if old == content:
            print(f"  =  {rel:30s} {len(content.splitlines()):4d}줄 (변경 없음)")
            continue
        changed += 1
        if a.check:
            print(f"  ~  {rel:30s} 차이 있음")
            for line in list(difflib.unified_diff(
                    old.splitlines(), content.splitlines(),
                    "기존", "빌드", lineterm="", n=0))[:12]:
                print(f"       {line}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
            print(f"  →  {rel:30s} {len(content.splitlines()):4d}줄 {'생성' if not old else '갱신'}")

    print(f"\n{'차이' if a.check else '변경'} {changed}건 / 전체 {len(files)}개 파일")
    if not a.check:
        print("\n다음: python3 verify_skill.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
