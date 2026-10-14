"""
title: 인덱스 생성 스크립트
step: 99
type: python
summary: 폴더 내 문서의 최상단 메타 주석을 파싱해 00_index.md를 재생성한다. _archive/ 는 제외하며 메타 주석 누락과 requires/next 체인 불일치를 경고한다. 재실행 시 항상 덮어쓴다(멱등).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "00_index.md")
FIELDS = ("title", "step", "type", "summary", "requires", "next")

# 파일 최상단의 첫 주석 블록만 읽는다 (/* */, <!-- -->, """ """)
BLOCK_PATTERNS = (
    re.compile(r"\A\s*/\*(.*?)\*/", re.S),
    re.compile(r"\A\s*<!--(.*?)-->", re.S),
    re.compile(r'\A\s*"""(.*?)"""', re.S),
)
NUM_PREFIX = re.compile(r"^(\d{2})_")


def parse_meta(path):
    try:
        with open(path, encoding="utf-8") as f:
            head = f.read(4000)
    except (UnicodeDecodeError, OSError) as e:
        return None, f"읽기 실패: {e}"
    for pat in BLOCK_PATTERNS:
        m = pat.match(head)
        if m:
            meta = {}
            for line in m.group(1).splitlines():
                k, sep, v = line.partition(":")
                if sep and k.strip() in FIELDS:
                    meta[k.strip()] = v.strip()
            return meta, None
    return None, "메타 주석 없음"


def main():
    warnings = []
    docs = []
    for name in sorted(os.listdir(HERE)):
        full = os.path.join(HERE, name)
        if name == "00_index.md" or name.startswith(("_", ".")) or not os.path.isfile(full):
            continue            # 인덱스 자신, _archive/, 숨김 파일 제외
        m = NUM_PREFIX.match(name)
        if not m:
            continue
        meta, err = parse_meta(full)
        if meta is None:
            warnings.append(f"{name}: {err}")
            meta = {"title": name, "summary": "(요약 없음)"}
        # requires/next 는 실습 문서(.sql/.md)에만 필수. .py 는 체인에 속하지 않는다
        required = FIELDS if not name.endswith(".py") else FIELDS[:4]
        for k in required:
            if k not in meta:
                warnings.append(f"{name}: '{k}' 필드 누락")
        if meta.get("step") and meta["step"] != m.group(1):
            warnings.append(f"{name}: step={meta['step']} 이 파일 번호 {m.group(1)} 와 다름")
        docs.append((int(m.group(1)), name, meta))

    docs.sort(key=lambda d: (d[0], d[1]))
    names = {d[1] for d in docs}
    for _, name, meta in docs:
        for k in ("requires", "next"):
            v = meta.get(k)
            if v and v != "없음" and v not in names:
                warnings.append(f"{name}: {k}='{v}' 파일이 존재하지 않음")

    lines = [
        "<!-- 이 파일은 99_generate_index.py 가 자동 생성합니다. 직접 수정하지 마십시오. -->",
        "",
        "# 00. 인덱스",
        "",
        "| 번호 | 파일 | 제목 | 유형 | 요약 |",
        "|:---:|------|------|:---:|------|",
    ]
    for num, name, meta in docs:
        summary = meta.get("summary", "(요약 없음)").replace("|", "\\|")
        lines.append(f"| {num:02d} | `{name}` | {meta.get('title', '')} | {meta.get('type', '')} | {summary} |")

    lines += ["", "## 실습 진행 순서", ""]
    step_docs = [d for d in docs if 2 <= d[0] <= 89 or d[0] == 98]
    for i, (num, name, meta) in enumerate(step_docs, 1):
        lines.append(f"{i}. `{name}` — {meta.get('title', '')}")

    lines += ["", "## 의존 관계", "", "| 파일 | requires | next |", "|------|------|------|"]
    for _, name, meta in docs:
        lines.append(f"| `{name}` | {meta.get('requires', '-')} | {meta.get('next', '-')} |")

    lines += ["", f"문서 수: {len(docs)} (이 인덱스 제외)", ""]

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    for w in warnings:
        print(f"⚠️  {w}", file=sys.stderr)
    print(f"00_index.md 생성: 문서 {len(docs)}개, 경고 {len(warnings)}건")
    return 1 if warnings else 0


if __name__ == "__main__":
    sys.exit(main())
