<!-- 이 파일은 99_generate_index.py 가 자동 생성합니다. 직접 수정하지 마십시오. -->

# 00. 인덱스

| 번호 | 파일 | 제목 | 유형 | 요약 |
|:---:|------|------|:---:|------|
| 01 | `01_교육자료_정리본.md` | 교육자료 정리본 — 비정형 기술문서 파이프라인 및 RAG 구현 | md | Snowpark·Cortex AI 로 기술문서(PDF)를 증분 파싱·청킹·인덱싱하고 출처 포함 RAG 질의응답(SQL 조립형 + Cortex Agent)까지 구현하는 실습의 목표, 비용 최적화 아키텍처, 선택 기준, 객체 대장, 단계 요약, 검토 이력. |
| 02 | `02_환경준비_및_비용가드.sql` | 환경 준비 및 비용 가드 | sql | 사전 스냅샷·접두사 충돌·모델 수명 게이트를 확인한 뒤 전용 Role/Warehouse(XS, 60초 자동중지)/Database/Schema 와 리소스 모니터(크레딧 상한)를 만든다. |
| 03 | `03_스테이지_및_증분감지.sql` | 문서 스테이지 및 증분 감지 | sql | 서버 측 암호화 + 디렉터리 테이블 AUTO_REFRESH 내부 스테이지를 만들고, 디렉터리 테이블 위에 스트림을 걸어 "새로 들어온 파일만" 감지하는 기반을 만든다. |
| 04 | `04_문서업로드_안내.md` | 문서 업로드 안내 | md | 실습용 기술문서(PDF)를 Snowflake CLI 또는 Snowsight UI 로 DOC_STAGE 에 올리고, 디렉터리 테이블과 스트림에 반영되었는지 확인한다. Snowflake 외부(로컬/UI) 작업. |
| 05 | `05_파싱_및_Snowpark청킹.sql` | 문서 파싱 및 Snowpark 청킹 | sql | AI_PARSE_DOCUMENT 로 신규 파일만 1회 파싱(MD5 중복 제거)하고, Snowpark Python UDTF 로 섹션 인식 청킹·하이픈 정규화를 수행해 청크 테이블에 적재하는 증분 프로시저를 만든다. |
| 06 | `06_증분파이프라인_TriggeredTask.sql` | 증분 파이프라인 (Triggered Task) | sql | 스케줄 없이 스트림에 데이터가 들어올 때만 도는 Triggered Task 로 SP_INGEST_NEW_DOCS 를 자동 실행하고, 신규 문서 적재·중복 사본 파싱 재사용을 결과 테이블로 확인한다. |
| 07 | `07_CortexSearch_서비스.sql` | Cortex Search 서비스 | sql | 중복 사본을 제외한 청크로 하이브리드(벡터+키워드) Cortex Search 서비스를 만들고, 긴 TARGET_LAG·AUTO_SUSPEND 로 인덱싱·서빙 비용을 줄인 뒤 한국어 질의로 검색 품질을 확인한다. |
| 08 | `08_RAG_질의응답_및_캐시.sql` | RAG 질의응답 및 답변 캐시 | sql | Cortex Search 상위 k개 청크를 근거로 AI_COMPLETE 가 출처 포함 답변을 생성하는 RAG 프로시저를 만들고, 설정 테이블(모델·k·최대 토큰)과 질문 해시 캐시로 LLM 호출 비용을 통제한다. |
| 09 | `09_Snowpark_품질평가_및_비용모니터링.sql` | Snowpark 품질 평가 및 비용 모니터링 | sql | Snowpark DataFrame API 로 작성한 Python 저장 프로시저가 평가셋을 SP_ASK 로 돌려 키워드·출처·거절 정확도를 채점하고, 파이프라인 로그·질의 로그·계정 사용량 뷰로 비용을 점검한다. |
| 10 | `10_CortexAgent_구성.sql` | Cortex Agent 구성 (선택 확장) | sql | 07_ 검색 서비스를 cortex_search 도구로 쓰는 Cortex Agent 를 만들고, 인용·여러 턴 대화·호출자 권한(caller's rights)을 08_ SP 방식과 비교하며, budget 으로 에이전트 비용 상한을 둔다. |
| 98 | `98_리소스정리.sql` | 리소스 정리 (Teardown) | sql | 실습이 만든 계정·스키마 객체 25종을 역순으로 정리하고(일시 중단 선택지 포함), 재실행 안전 방어 블록과 정리 완료 검증 쿼리로 사전 스냅샷과 대조한다. |
| 99 | `99_generate_index.py` | 인덱스 생성 스크립트 | python | 폴더 내 문서의 최상단 메타 주석을 파싱해 00_index.md를 재생성한다. _archive/ 는 제외하며 메타 주석 누락과 requires/next 체인 불일치를 경고한다. 재실행 시 항상 덮어쓴다(멱등). |

## 실습 진행 순서

1. `02_환경준비_및_비용가드.sql` — 환경 준비 및 비용 가드
2. `03_스테이지_및_증분감지.sql` — 문서 스테이지 및 증분 감지
3. `04_문서업로드_안내.md` — 문서 업로드 안내
4. `05_파싱_및_Snowpark청킹.sql` — 문서 파싱 및 Snowpark 청킹
5. `06_증분파이프라인_TriggeredTask.sql` — 증분 파이프라인 (Triggered Task)
6. `07_CortexSearch_서비스.sql` — Cortex Search 서비스
7. `08_RAG_질의응답_및_캐시.sql` — RAG 질의응답 및 답변 캐시
8. `09_Snowpark_품질평가_및_비용모니터링.sql` — Snowpark 품질 평가 및 비용 모니터링
9. `10_CortexAgent_구성.sql` — Cortex Agent 구성 (선택 확장)
10. `98_리소스정리.sql` — 리소스 정리 (Teardown)

## 의존 관계

| 파일 | requires | next |
|------|------|------|
| `01_교육자료_정리본.md` | 없음 | 02_환경준비_및_비용가드.sql |
| `02_환경준비_및_비용가드.sql` | 01_교육자료_정리본.md | 03_스테이지_및_증분감지.sql |
| `03_스테이지_및_증분감지.sql` | 02_환경준비_및_비용가드.sql | 04_문서업로드_안내.md |
| `04_문서업로드_안내.md` | 03_스테이지_및_증분감지.sql | 05_파싱_및_Snowpark청킹.sql |
| `05_파싱_및_Snowpark청킹.sql` | 04_문서업로드_안내.md | 06_증분파이프라인_TriggeredTask.sql |
| `06_증분파이프라인_TriggeredTask.sql` | 05_파싱_및_Snowpark청킹.sql | 07_CortexSearch_서비스.sql |
| `07_CortexSearch_서비스.sql` | 06_증분파이프라인_TriggeredTask.sql | 08_RAG_질의응답_및_캐시.sql |
| `08_RAG_질의응답_및_캐시.sql` | 07_CortexSearch_서비스.sql | 09_Snowpark_품질평가_및_비용모니터링.sql |
| `09_Snowpark_품질평가_및_비용모니터링.sql` | 08_RAG_질의응답_및_캐시.sql | 10_CortexAgent_구성.sql |
| `10_CortexAgent_구성.sql` | 09_Snowpark_품질평가_및_비용모니터링.sql | 98_리소스정리.sql |
| `98_리소스정리.sql` | 10_CortexAgent_구성.sql | 없음 |
| `99_generate_index.py` | - | - |

문서 수: 12 (이 인덱스 제외)
