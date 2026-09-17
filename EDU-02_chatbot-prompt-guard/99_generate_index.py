"""
title: 인덱스 생성 스크립트
step: 99
type: python
summary: 폴더 내 문서의 최상단 메타 주석을 파싱해 00_index.md를 재생성한다. _archive/ 는 제외하며 메타 주석 누락과 requires/next 체인 불일치를 경고한다.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

FOLDER = Path(__file__).resolve().parent
INDEX = FOLDER / "00_index.md"

# 인덱스 대상에서 제외한다.
#   _archive/  : 개선 전 원본 이력 (실습 대상이 아니다)
#   00_index.md: 이 스크립트의 산출물
EXCLUDED_DIRS = {"_archive", "__pycache__", ".git"}
EXCLUDED_FILES = {"00_index.md"}

SUFFIX_TYPE = {".sql": "sql", ".md": "md", ".py": "python"}

FIELDS = ("title", "step", "type", "summary", "requires", "next")

# 파일 최상단 메타 주석 블록. 확장자별 주석 구분자가 다르다.
BLOCK_PATTERNS = {
    ".sql": re.compile(r"\A\s*/\*(.*?)\*/", re.DOTALL),
    ".md": re.compile(r"\A\s*<!--(.*?)-->", re.DOTALL),
    ".py": re.compile(r'\A\s*(?:#![^\n]*\n)?\s*"""(.*?)"""', re.DOTALL),
}

FIELD_RE = re.compile(r"^(title|step|type|summary|requires|next)\s*:\s*(.*)$")

warnings: list[str] = []


def warn(msg: str) -> None:
    warnings.append(msg)


def target_files() -> list[Path]:
    files = []
    for p in sorted(FOLDER.iterdir()):
        if p.is_dir():
            continue
        if p.name in EXCLUDED_FILES:
            continue
        if p.suffix not in SUFFIX_TYPE:
            continue
        files.append(p)
    return files


def parse_meta(path: Path) -> dict[str, str] | None:
    """파일 최상단 메타 주석 블록을 파싱한다. 없으면 None."""
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        warn(f"{path.name}: UTF-8 로 읽을 수 없어 건너뜁니다")
        return None

    pattern = BLOCK_PATTERNS[path.suffix]
    m = pattern.search(text)
    if not m:
        return None

    meta: dict[str, str] = {}
    current: str | None = None
    for raw in m.group(1).splitlines():
        line = raw.strip()
        if not line:
            continue
        fm = FIELD_RE.match(line)
        if fm:
            current = fm.group(1)
            meta[current] = fm.group(2).strip()
        elif current:
            # summary 등이 여러 줄로 이어진 경우
            meta[current] = (meta[current] + " " + line).strip()
    return meta or None


def sort_key(entry: dict) -> tuple:
    step = entry["meta"].get("step", "")
    m = re.match(r"^\d+", step)
    # step 이 숫자가 아니면 뒤로 보낸다
    return (0, int(m.group(0)), entry["path"].name) if m else (1, 0, entry["path"].name)


def validate(entries: list[dict]) -> None:
    names = {e["path"].name for e in entries}
    steps: dict[str, str] = {}

    for e in entries:
        path, meta = e["path"], e["meta"]
        name = path.name

        for f in FIELDS:
            if f in ("requires", "next") and path.suffix == ".py":
                continue  # 99_ 는 체인에 참여하지 않는다
            if not meta.get(f):
                warn(f"{name}: 메타 주석에 '{f}' 가 없습니다")

        # step 과 파일명 접두 번호가 일치하는지
        prefix = re.match(r"^(\d+)_", name)
        step = meta.get("step", "")
        if prefix and step and prefix.group(1) != step:
            warn(f"{name}: 파일명 접두 번호({prefix.group(1)}) 와 step({step}) 이 다릅니다")
        if not prefix:
            warn(f"{name}: 파일명이 '<번호>_' 로 시작하지 않습니다")

        # step 중복
        if step:
            if step in steps:
                warn(f"step {step} 중복: {steps[step]} / {name}")
            else:
                steps[step] = name

        # type 과 확장자 일치
        expected = SUFFIX_TYPE[path.suffix]
        if meta.get("type") and meta["type"] != expected:
            warn(f"{name}: type({meta['type']}) 이 확장자({expected}) 와 다릅니다")

        # requires / next 체인이 실제 파일을 가리키는지
        for f in ("requires", "next"):
            v = meta.get(f, "")
            if not v or v == "없음":
                continue
            for ref in [x.strip() for x in v.split(",") if x.strip()]:
                if ref not in names:
                    warn(f"{name}: {f} 가 존재하지 않는 파일을 가리킵니다 → {ref}")


def render(entries: list[dict]) -> str:
    lines: list[str] = []
    lines.append("<!-- 이 파일은 99_generate_index.py 가 생성합니다. 직접 수정하지 마십시오. -->")
    lines.append("")
    lines.append("# 00. 문서 인덱스")
    lines.append("")
    lines.append(f"- **문서 수:** {len(entries)}")
    lines.append("- **재생성:** `python3 99_generate_index.py`")
    lines.append("")
    lines.append("> 실행은 `step` 오름차순으로 진행합니다. 번호는 연속이 아닐 수 있습니다.")
    lines.append("> `_archive/` 는 개선 전 원본 이력이며 실습에 사용하지 않습니다.")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("## 문서 목록")
    lines.append("")
    lines.append("| step | 문서 | 형식 | 제목 |")
    lines.append("| :---: | :--- | :---: | :--- |")
    for e in entries:
        m = e["meta"]
        lines.append(
            f"| {m.get('step', '-')} | `{e['path'].name}` | {m.get('type', '-')} | {m.get('title', '-')} |"
        )
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("## 문서별 요약")
    lines.append("")
    for e in entries:
        m = e["meta"]
        lines.append(f"### {m.get('step', '-')}. {m.get('title', e['path'].name)}")
        lines.append("")
        lines.append(f"- **파일:** `{e['path'].name}`")
        lines.append(f"- **형식:** {m.get('type', '-')}")
        lines.append(f"- **선행:** {m.get('requires', '-')}")
        lines.append(f"- **다음:** {m.get('next', '-')}")
        lines.append("")
        lines.append(m.get("summary", "(요약 없음)"))
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    entries = []
    for path in target_files():
        meta = parse_meta(path)
        if meta is None:
            warn(f"{path.name}: 최상단 메타 주석 블록이 없어 인덱스에서 제외합니다")
            continue
        entries.append({"path": path, "meta": meta})

    entries.sort(key=sort_key)
    validate(entries)

    content = render(entries)
    previous = INDEX.read_text(encoding="utf-8") if INDEX.exists() else None
    INDEX.write_text(content, encoding="utf-8")

    changed = previous != content
    print(f"00_index.md {'갱신' if changed else '변경 없음 (멱등)'} — 문서 {len(entries)}개")

    if warnings:
        print(f"\n⚠️ 경고 {len(warnings)}건:")
        for w in warnings:
            print(f"  - {w}")
        return 1
    print("경고 없음")
    return 0


if __name__ == "__main__":
    sys.exit(main())
