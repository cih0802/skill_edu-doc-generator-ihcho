#!/usr/bin/env python3
"""
교육자료 스킬 검증기 — 재현 실험 4회차에서 발견된 결함을 전수 검사한다.

각 검사가 어느 회차의 결함에 대응하는지 명시했다.
산문 절차로는 회차마다 다른 구멍이 생겼으므로, 종료 조건을 코드로 고정한다.

위치: 스킬 폴더 **밖**에 둔다.

사용법:
    python3 verify_skill.py                 # 기본 경로 검증
    python3 verify_skill.py --skill <경로>
    python3 verify_skill.py --spec <경로>    # 명세 대조까지 수행

종료 코드: 0 = 전부 통과 / 1 = 결함 있음
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SKILL_NAME = "edu-doc-generator-ihcho"
DEFAULT_SKILL = Path(f"/workspace/.snowflake/cortex/skills/{SKILL_NAME}")
DEFAULT_SPEC = Path(__file__).resolve().parent / "교육자료 생성 프롬프트.md"

LEAVES = ["create/SKILL.md", "improve/SKILL.md"]
# 조각 목록은 폴더에서 읽는다. 손으로 나열하면 조각이 늘거나 이름이 바뀔 때
# 검사 대상에서 조용히 빠진다(실측: references/ 를 안 훑어 죽은 좌표 2건 통과).
def shards(root: Path) -> list[str]:
    d = root / "references"
    return sorted(f.name for f in d.glob("*.md")) if d.is_dir() else []

SHARD_MAX = 400        # 조각 상한 — 넘으면 "이음매를 찾아 분할" 신호
HUB_MAX = 200          # 허브(코디네이터) 상한 — 호출마다 읽히므로 얇게
REQUIRED_SECTIONS = ["When to Load", "Prerequisites", "Workflow",
                     "Stopping Points", "금지 사항", "Output"]

# 좌표 표기 검출: 백틱/슬래시/영숫자가 앞에 없는 'N장' 또는 'N.N'
COORD = re.compile(r"(^|[^`/\w])[0-9](장|\.[0-9])")
# 정상 표기: 참조 파일을 먼저 지목한 뒤의 절 번호
COORD_OK = re.compile(r"references/[0-9a-z_-]*\.md` *[0-9~]*장")

results: list[tuple[bool, str, str]] = []


def check(ok: bool, label: str, detail: str = "") -> bool:
    results.append((ok, label, detail))
    return ok


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8") if p.exists() else ""


def main() -> int:
    ap = argparse.ArgumentParser(description="교육자료 스킬 검증기")
    ap.add_argument("--skill", type=Path, default=DEFAULT_SKILL)
    ap.add_argument("--spec", type=Path, default=DEFAULT_SPEC)
    a = ap.parse_args()
    S = a.skill

    if not S.exists():
        print(f"[오류] 스킬 폴더 없음: {S}")
        return 1

    router = read(S / "SKILL.md")
    leaves = {f: read(S / f) for f in LEAVES}

    # ── 파일 존재 ──────────────────────────────────────────────
    REFS = shards(S)
    expected = ["SKILL.md"] + LEAVES + [f"references/{r}" for r in REFS]
    missing = [f for f in expected if not (S / f).exists()]
    check(not missing and len(REFS) >= 1,
          f"필수 파일 존재 (허브1 + 리프2 + 조각{len(REFS)})",
          f"누락: {missing}" if missing else "")

    # ── /skill-development Step 5 기준 ────────────────────────
    rl = len(router.splitlines())
    check(rl < HUB_MAX, f"허브 < {HUB_MAX}줄", f"{rl}줄 (여유 {HUB_MAX - rl})")
    over = {f: len(read(S / f).splitlines()) for f in expected
            if len(read(S / f).splitlines()) >= 500}
    check(not over, "모든 리프 < 500줄", f"초과: {over}" if over else
          f"최대 {max(len(read(S / f).splitlines()) for f in expected)}줄")

    # ── 도달성 (CYOA) ─────────────────────────────────────────
    for leaf in LEAVES:
        check(f"**Load** `{leaf}`" in router, f"라우터 → {leaf} 도달 가능")
    for ref in REFS:
        cited = any(f"../references/{ref}" in body for body in leaves.values())
        check(cited, f"references/{ref} 참조됨 (고아 아님)")

    # ── 1차 결함: **Load** 지시 부재 ───────────────────────────
    for leaf, body in leaves.items():
        n = len(re.findall(r"\*\*Load\*\* `\.\./references", body))
        check(n > 0, f"[1차] {leaf} 로드 지시 존재", f"{n}건")

    # ── 4차 결함: 치환만 하고 삽입 누락 ────────────────────────
    total_loads = sum(len(re.findall(r"\*\*Load\*\* `\.\./references", b))
                      for b in leaves.values())
    check(total_loads >= 5, "[4차] 로드 지시가 STEP 헤딩에 삽입됨",
          f"총 {total_loads}건 (인라인 언급만으로는 불충분)")

    # ── 2·3차 결함: 죽은 좌표 참조 ─────────────────────────────
    dead: list[str] = []
    for f in ["SKILL.md"] + LEAVES:
        for i, line in enumerate(read(S / f).split("\n"), 1):
            if COORD.search(line) and not COORD_OK.search(line):
                dead.append(f"{f}:{i}: {line.strip()[:70]}")
    check(not dead, "[2·3차] 죽은 좌표 참조 없음",
          "\n".join("        " + d for d in dead[:8]) if dead else "")

    # ── 조각 상한 — 넘으면 "이음매를 찾아 분할" 신호 ──────────
    fat = {f"references/{r}": len(read(S / "references" / r).splitlines())
           for r in REFS
           if len(read(S / "references" / r).splitlines()) > SHARD_MAX}
    biggest = max((len(read(S / "references" / r).splitlines()) for r in REFS),
                  default=0)
    check(not fat, f"모든 조각 <= {SHARD_MAX}줄",
          ("초과: " + ", ".join(f"{k} {v}줄" for k, v in fat.items())
           + " → 바이트 경계로 이어 쓰지 말고 의미 이음매를 찾아 분할하라")
          if fat else f"최대 {biggest}줄 (여유 {SHARD_MAX - biggest})")

    # ── 허브 포인터 표 ↔ 실제 조각 일치 ───────────────────────
    # 표를 손으로 관리하면 조각이 늘 때 어긋난다. 빌드가 생성하므로 여기서 대조만 한다.
    listed = set(re.findall(r"`references/([0-9a-z_-]+\.md)`", read(S / "SKILL.md")))
    actual = set(REFS)
    drift = sorted((listed - actual) | (actual - listed))
    check(not drift, "허브 포인터 표가 실제 조각과 일치",
          (f"어긋남: {drift}  (표에만 {sorted(listed-actual)} / "
           f"폴더에만 {sorted(actual-listed)})") if drift else f"{len(actual)}개 일치")

    # ── references/ 안의 절 번호 좌표 ─────────────────────────
    # 참조 파일은 절 번호를 평평한 `## N.` 로 재부여받는다. 따라서 `N.M` 형태의
    # 절 좌표는 그 파일에 존재하지 않는 번호를 가리킨다 = 죽은 좌표다.
    # (자기 장을 가리키는 "N장" 은 정상이므로 위 검사와 규칙이 다르다.)
    #
    # 이 검사가 없어서 실측 결함 2건이 22/22 통과 상태로 남아 있었다:
    #   `### 3.2.1` (3단 헤딩이라 재번호 정규식에 매치되지 않음)
    #   `위 3.2 표의` (치환 패턴이 "N.M의 "/"N.M 참고" 만 다룸)
    SEC_COORD = re.compile(r"(?<![`\w./])\d+\.\d+(?:\.\d+)?(?![\w.])")
    ref_dead: list[str] = []
    for f in REFS:
        infence = False
        for i, line in enumerate(read(S / "references" / f).split("\n"), 1):
            if line.lstrip().startswith("```"):
                infence = not infence
                continue
            if infence:
                continue
            for m in SEC_COORD.finditer(line):
                ref_dead.append(f"references/{f}:{i}: {m.group(0)} — {line.strip()[:56]}")
    check(not ref_dead, "references/ 에 N.M 절 좌표 없음",
          "\n".join("        " + d for d in ref_dead[:8]) if ref_dead else "")

    # ── 5.1: 서브스킬 필수 절 ─────────────────────────────────
    for leaf, body in leaves.items():
        lack = [s for s in REQUIRED_SECTIONS
                if not re.search(rf"^## .*{re.escape(s)}", body, re.M)]
        check(not lack, f"[5.1] {leaf} 필수 6개 절", f"누락: {lack}" if lack else "6/6")

    # ── 6.1: 경로 규칙 ────────────────────────────────────────
    for leaf, body in leaves.items():
        bad = [l for l in body.split("\n")
               if re.search(r"(?<!\.\./)(?<!\w)references/[0-9a-z_-]+\.md", l)
               and "../references" not in l and "참조 경로" not in l]
        check(not bad, f"[6.1] {leaf} 는 ../references 사용",
              f"잘못된 경로 {len(bad)}건" if bad else "")
    check(bool(re.search(r"`references/[0-9a-z_-]+\.md`", router)),
          "[6.1] 라우터는 references/ 사용 (../ 아님)")

    # ── 6.2: 라우터가 참조를 로드하지 않음 ────────────────────
    n = len(re.findall(r"\*\*Load\*\* `references/", router))
    check(n == 0, "[6.2] 라우터가 참조를 로드하지 않음",
          f"{n}건 발견 — 초기 토큰 절감이 무효화됨" if n else "")

    # ── 트리거 ────────────────────────────────────────────────
    check("교육자료 개선" in router, "description 에 한국어 개선 트리거",
          "없으면 IMPROVE 요청에 반응하지 않음")

    # ── 중단점 ────────────────────────────────────────────────
    stops = sum(len(re.findall(r"⚠️ STOP|✋", read(S / f)))
                for f in ["SKILL.md"] + LEAVES)
    check(stops >= 20, "중단점 20개 이상", f"{stops}개")
    check(bool(re.search(r"✋ \**I3", leaves["improve/SKILL.md"])),
          "IMPROVE 최중요 중단점(I3) 명시")

    # ── 명세 대조 (선택) ──────────────────────────────────────
    if a.spec.exists():
        spec = a.spec.read_text(encoding="utf-8")
        pat = re.compile(r"STEP [CI]\d\. [^(\n]*")
        want = {s.strip() for s in pat.findall(spec)}
        have = {s.strip() for f in LEAVES for s in pat.findall(leaves[f])}
        diff = want - have
        check(not diff, "명세의 모든 STEP 이 스킬에 존재",
              f"누락: {sorted(diff)}" if diff else f"{len(want)}개")

    # ── 보고 ──────────────────────────────────────────────────
    print(f"스킬: {S}\n")
    fails = 0
    for ok, label, detail in results:
        print(f"  {'✅' if ok else '❌'} {label}" + (f"  ({detail})" if detail and ok else ""))
        if not ok:
            fails += 1
            if detail:
                print(detail if detail.startswith("        ") else f"        {detail}")

    print(f"\n{len(results) - fails} / {len(results)} 통과", end="")
    print(" — 전부 통과 ✅" if not fails else f" — 결함 {fails}건 ❌")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
