#!/usr/bin/env python3
"""
title: 인덱스 생성 스크립트
step: 99
type: python
summary: 이 폴더의 문서를 스캔해 각 파일 최상단 메타 주석을 파싱하고 00_index.md 를 재생성한다. 항상 덮어쓰므로 반복 실행이 안전하다.
requires: 없음
next: 없음
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# ---------------------------------------------------------------
# 설정
# ---------------------------------------------------------------
FOLDER = Path(__file__).resolve().parent
INDEX_FILENAME = "00_index.md"
TARGET_SUFFIXES = {".sql", ".md", ".py"}
META_FIELDS = ("title", "step", "type", "summary", "requires", "next")
NO_SUMMARY = "(요약 없음)"

# 파일 종류별 최상단 주석 블록 패턴
#   .sql : /* ... */
#   .md  : <!-- ... -->
#   .py  : """ ... """
COMMENT_PATTERNS = {
    ".sql": re.compile(r"\A\s*/\*(.*?)\*/", re.DOTALL),
    ".md": re.compile(r"\A\s*<!--(.*?)-->", re.DOTALL),
    ".py": re.compile(r'\A\s*(?:#![^\n]*\n)?(?:from __future__[^\n]*\n)?\s*"""(.*?)"""', re.DOTALL),
}

TYPE_LABEL = {
    "sql": "SQL",
    "md": "MD",
    "python": "Python",
    "py": "Python",
}


# ---------------------------------------------------------------
# 파싱
# ---------------------------------------------------------------
def extract_meta_block(path: Path) -> str | None:
    """파일 최상단 주석 블록의 본문을 반환한다. 없으면 None."""
    pattern = COMMENT_PATTERNS.get(path.suffix)
    if pattern is None:
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"  [경고] {path.name} 읽기 실패: {exc}", file=sys.stderr)
        return None
    match = pattern.search(text)
    return match.group(1) if match else None


def parse_meta(block: str | None) -> dict[str, str]:
    """'key: value' 줄들을 파싱한다. 값에 콜론이 있어도 첫 콜론만 구분자로 쓴다."""
    meta: dict[str, str] = {}
    if not block:
        return meta
    for raw_line in block.splitlines():
        line = raw_line.strip()
        if not line or ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip().lower()
        if key in META_FIELDS:
            meta[key] = value.strip()
    return meta


def step_sort_key(path: Path) -> tuple[int, str]:
    """파일명 접두 번호 기준 정렬. 번호가 없으면 뒤로 보낸다."""
    match = re.match(r"^(\d+)", path.name)
    return (int(match.group(1)) if match else 9999, path.name)


def collect() -> tuple[list[dict[str, str]], list[str]]:
    """폴더를 스캔해 문서 목록과 경고 목록을 반환한다."""
    entries: list[dict[str, str]] = []
    warnings: list[str] = []

    files = [
        p
        for p in FOLDER.iterdir()
        if p.is_file() and p.suffix in TARGET_SUFFIXES and p.name != INDEX_FILENAME
    ]

    for path in sorted(files, key=step_sort_key):
        meta = parse_meta(extract_meta_block(path))

        if not meta:
            warnings.append(f"{path.name}: 최상단 메타 주석 블록이 없습니다.")
        elif "summary" not in meta:
            warnings.append(f"{path.name}: summary 필드가 없습니다.")

        step_match = re.match(r"^(\d+)", path.name)
        entries.append(
            {
                "filename": path.name,
                "step": meta.get("step") or (step_match.group(1) if step_match else "-"),
                "title": meta.get("title") or path.stem,
                "type": meta.get("type") or path.suffix.lstrip("."),
                "summary": meta.get("summary") or NO_SUMMARY,
                "requires": meta.get("requires") or "-",
                "next": meta.get("next") or "-",
            }
        )

    return entries, warnings


# ---------------------------------------------------------------
# 렌더링
# ---------------------------------------------------------------
def md_escape(text: str) -> str:
    """표 셀 안에서 파이프가 열을 깨지 않도록 이스케이프한다."""
    return text.replace("|", "\\|")


def render(entries: list[dict[str, str]], warnings: list[str]) -> str:
    lines: list[str] = []

    lines.append(f"# {FOLDER.name} — 문서 인덱스")
    lines.append("")
    lines.append(
        f"> ⚠️ 이 파일은 `{Path(__file__).name}` 이 자동 생성합니다. "
        "직접 편집하지 마세요 — 다음 실행 시 덮어써집니다."
    )
    lines.append(">")
    lines.append("> 재생성: `python3 99_generate_index.py`")
    lines.append("")
    lines.append(f"총 {len(entries)}개 문서")
    lines.append("")

    # --- 문서 목록 ---
    lines.append("## 문서 목록")
    lines.append("")
    lines.append("| # | 문서 | 유형 | 제목 | 요약 |")
    lines.append("|---|------|------|------|------|")
    for e in entries:
        lines.append(
            "| {step} | `{filename}` | {type} | {title} | {summary} |".format(
                step=md_escape(e["step"]),
                filename=e["filename"],
                type=TYPE_LABEL.get(e["type"].lower(), e["type"]),
                title=md_escape(e["title"]),
                summary=md_escape(e["summary"]),
            )
        )
    lines.append("")

    # --- 실습 진행 순서 ---
    lines.append("## 실습 진행 순서")
    lines.append("")
    ordered = [e for e in entries if e["step"].isdigit() and 1 <= int(e["step"]) <= 98]
    if ordered:
        for e in ordered:
            step_no = int(e["step"])
            if step_no == 1:
                # 01번은 개요/정리본이며 실행 단계가 아니다.
                marker = " 📖 *개요 — 먼저 읽어 주세요*"
            elif e["type"].lower() == "md":
                marker = " ⚠️ *Snowflake 외부/혼합 작업*"
            else:
                marker = ""
            lines.append(f"{step_no}. **`{e['filename']}`** — {md_escape(e['title'])}{marker}")
            lines.append(f"   - {md_escape(e['summary'])}")
        lines.append("")
    else:
        lines.append("_진행 순서를 가진 문서(01~98)가 없습니다._")
        lines.append("")

    # --- 의존 관계 ---
    lines.append("## 의존 관계")
    lines.append("")
    lines.append("| 문서 | 선행 문서 | 다음 문서 |")
    lines.append("|------|-----------|-----------|")
    for e in entries:
        lines.append(
            "| `{filename}` | {requires} | {next} |".format(
                filename=e["filename"],
                requires=md_escape(e["requires"]),
                next=md_escape(e["next"]),
            )
        )
    lines.append("")

    # --- 유형별 통계 ---
    lines.append("## 유형별 문서 수")
    lines.append("")
    counts: dict[str, int] = {}
    for e in entries:
        label = TYPE_LABEL.get(e["type"].lower(), e["type"])
        counts[label] = counts.get(label, 0) + 1
    lines.append("| 유형 | 개수 |")
    lines.append("|------|------|")
    for label in sorted(counts):
        lines.append(f"| {label} | {counts[label]} |")
    lines.append("")

    # --- 경고 ---
    if warnings:
        lines.append("## ⚠️ 메타데이터 경고")
        lines.append("")
        for w in warnings:
            lines.append(f"- {md_escape(w)}")
        lines.append("")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------
# 엔트리포인트
# ---------------------------------------------------------------
def main() -> int:
    print(f"스캔 대상 폴더: {FOLDER}")

    entries, warnings = collect()

    if not entries:
        print("[오류] 대상 문서를 찾지 못했습니다.", file=sys.stderr)
        return 1

    index_path = FOLDER / INDEX_FILENAME
    index_path.write_text(render(entries, warnings), encoding="utf-8")

    print(f"문서 {len(entries)}개를 인덱싱했습니다.")
    for e in entries:
        print(f"  [{e['step']:>2}] {e['filename']}")

    if warnings:
        print(f"\n경고 {len(warnings)}건:")
        for w in warnings:
            print(f"  - {w}")

    print(f"\n생성 완료: {index_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
