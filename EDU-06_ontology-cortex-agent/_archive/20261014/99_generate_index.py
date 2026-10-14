#!/usr/bin/env python3
"""
title: 온톨로지 교육자료 인덱스 자동 생성기
step: 99
type: script
summary: 메타 주석 블록을 파싱하여 00_index.md 문서를 멱등하게 자동 생성하는 Python 스크립트
requires: []
next: [00_index.md]
"""

import os
import re
import sys

def parse_meta_comment(file_path):
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read(4000)

    # Match /* ... */ or <!-- ... --> or """ ... """ or ''' ... '''
    patterns = [
        r'/\*\s*(.*?)\s*\*/',
        r'<!--\s*(.*?)\s*-->',
        r'"""\s*(.*?)\s*"""',
        r"'''\s*(.*?)\s*'''"
    ]
    
    meta_text = None
    for p in patterns:
        m = re.search(p, content, re.DOTALL)
        if m and ('title:' in m.group(1) or 'step:' in m.group(1)):
            meta_text = m.group(1)
            break
            
    if not meta_text:
        return None
        
    meta = {}
    for line in meta_text.splitlines():
        line = line.strip()
        if not line or ':' not in line:
            continue
        key, val = line.split(':', 1)
        key = key.strip().lower()
        val = val.strip()
        if key in ['requires', 'next']:
            # parse array [a, b]
            val = val.strip('[]')
            items = [x.strip() for x in val.split(',') if x.strip()]
            meta[key] = items
        else:
            meta[key] = val
    return meta

def main():
    folder_path = os.path.dirname(os.path.abspath(__file__))
    files = sorted([f for f in os.listdir(folder_path) if os.path.isfile(os.path.join(folder_path, f))])
    
    doc_entries = []
    warnings = []
    
    for filename in files:
        if filename in ['00_index.md']:
            continue
            
        m = re.match(r'^(\d+)_', filename)
        if not m:
            continue
            
        step_num = int(m.group(1))
        full_path = os.path.join(folder_path, filename)
        meta = parse_meta_comment(full_path)
        
        if not meta:
            warnings.append(f"경고: {filename} 에 유효한 메타 주석이 없습니다.")
            meta = {
                'title': filename,
                'step': str(step_num),
                'type': 'unknown',
                'summary': '(요약 없음)',
                'requires': [],
                'next': []
            }
            
        doc_entries.append({
            'filename': filename,
            'step': step_num,
            'title': meta.get('title', filename),
            'type': meta.get('type', 'document'),
            'summary': meta.get('summary', ''),
            'requires': meta.get('requires', []),
            'next': meta.get('next', [])
        })
        
    doc_entries.sort(key=lambda x: x['step'])
    
    index_content = []
    index_content.append("# Snowflake 온톨로지 구축 및 Cortex Agent 연계 교육자료 인덱스 (EDU-06)\n")
    index_content.append("> 이 문서는 `99_generate_index.py`에 의해 자동 생성된 인덱스입니다. 직접 수정하지 마십시오.\n")
    index_content.append("## 1. 실습 문서 목록\n")
    index_content.append("| 번호 | 문서 / 스크립트 | 유형 | 제목 및 요약 | 선수 문서 (Requires) | 다음 단계 (Next) |")
    index_content.append("| :---: | :--- | :---: | :--- | :--- | :--- |")
    
    for entry in doc_entries:
        req_str = ", ".join([f"`{r}`" for r in entry['requires']]) if entry['requires'] else "-"
        next_str = ", ".join([f"`{n}`" for n in entry['next']]) if entry['next'] else "-"
        index_content.append(f"| **{entry['step']:02d}** | [`{entry['filename']}`](./{entry['filename']}) | `{entry['type']}` | **{entry['title']}**<br>{entry['summary']} | {req_str} | {next_str} |")
        
    index_content.append("\n## 2. 실습 진행 순서도\n")
    index_content.append("```mermaid")
    index_content.append("graph TD")
    for entry in doc_entries:
        curr_node = f"S{entry['step']:02d}[\"{entry['step']:02d}. {entry['title']}\"]"
        for n in entry['next']:
            nm = re.match(r'^(\d+)_', n)
            if nm:
                target_step = int(nm.group(1))
                index_content.append(f"    S{entry['step']:02d} --> S{target_step:02d}")
    index_content.append("```\n")
    
    out_file = os.path.join(folder_path, "00_index.md")
    with open(out_file, 'w', encoding='utf-8') as f:
        f.write("\n".join(index_content))
        
    print(f"[OK] 00_index.md 생성 완료 ({len(doc_entries)}개 문서 인덱싱)")
    for w in warnings:
        print(w, file=sys.stderr)

if __name__ == '__main__':
    main()
