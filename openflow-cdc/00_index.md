# openflow-cdc — 문서 인덱스

> ⚠️ 이 파일은 `99_generate_index.py` 이 자동 생성합니다. 직접 편집하지 마세요 — 다음 실행 시 덮어써집니다.
>
> 재생성: `python3 99_generate_index.py`

총 13개 문서

## 문서 목록

| # | 문서 | 유형 | 제목 | 요약 |
|---|------|------|------|------|
| 01 | `01_교육자료_정리본.md` | MD | 교육자료 정리본 — Openflow Gen 2로 CDC 구현하기 | Openflow Gen 2 SQL API로 PostgreSQL/MySQL CDC 파이프라인을 구축해 Snowflake로 데이터를 적재하는 실습의 개념, 아키텍처, 전체 흐름, 사전 준비물을 정리한다. |
| 02 | `02_사전준비_및_권한구성.sql` | SQL | 사전 준비 및 권한 구성 | Openflow Gen 2 사용 가능 여부 게이트 확인 후, Role 3종(admin/DE/execute-as), 인프라 DB/스키마, Warehouse, 대상 DB, Event Table을 생성한다. |
| 03 | `03_openflow_배포_및_런타임_생성.sql` | SQL | Openflow 배포 및 런타임 생성 | Gen 2 OPENFLOW DEPLOYMENT 와 OPENFLOW RUNTIME 을 SQL로 생성하고, 비동기 프로비저닝을 WAIT 함수로 대기한 뒤 Event Table 을 연결한다. |
| 04 | `04_소스DB_준비_및_CDC설정_postgresql.md` | MD | 소스 PostgreSQL 준비 및 CDC 설정 | Snowflake 외부 작업. 소스 PostgreSQL 에서 wal_level=logical, 복제 사용자, PUBLICATION, 실습 테이블(PK 포함)을 설정하고 호스트명/포트를 확보한다. |
| 05 | `05_네트워크_규칙_및_EAI_구성.sql` | SQL | 네트워크 규칙, EAI, Secret 구성 | 소스 호스트 egress 를 허용하는 Network Rule 과 External Access Integration 을 만들고 Runtime 에 연결한 뒤, 소스 비밀번호를 담을 GENERIC_STRING Secret 을 준비한다. |
| 06 | `06_커넥터_생성.sql` | SQL | 커넥터 생성 | OPENFLOW_POSTGRES_CDC 정의로 커넥터 객체를 생성하고 STOPPED 상태까지 대기한 뒤, config.json 편집에 필요한 live 버전 스테이지 URI 를 확보한다. |
| 07 | `07_커넥터_설정_config_json.md` | MD | 커넥터 설정 (JDBC 드라이버 + config.json) | 혼합 작업. PostgreSQL JDBC 드라이버 JAR 을 업로드하고 config.json 을 GET/편집/업로드한다. Snowsight 는 PUT 이 차단되므로 COPY INTO + COPY FILES 경로를 사용한다. |
| 08 | `08_커넥터_커밋_및_기동.sql` | SQL | 커넥터 커밋, 검증, 기동 | config.json 을 COMMIT 하고 VALIDATE CONFIGURATION 으로 사전 검증한 뒤 커넥터를 START 하여 RUNNING 상태까지 대기한다. START_FAILED 진단 쿼리 포함. |
| 09 | `09_적재결과_검증.sql` | SQL | 적재 결과 검증 | 스냅샷 단계에서 대상 스키마/테이블 자동 생성과 초기 행 수를 확인하고, 소스의 INSERT/UPDATE/DELETE 가 CDC 로 반영되는지 단계별로 검증한다. |
| 10 | `10_부록_MySQL_차이점.md` | MD | 부록 — MySQL CDC 로 전환할 때의 차이점 | 동일한 실습 흐름을 MySQL/MariaDB 소스로 바꿀 때 달라지는 부분만 정리한다. binlog 설정, 권한, 드라이버, config 프로퍼티, 제약사항. |
| 11 | `11_트러블슈팅.md` | MD | 트러블슈팅 | 증상별 진단 절차, 단계별 오류 메시지 대응표, Event Table 조회 쿼리, Connector Observability 활용법을 제공한다. 리소스 정리는 98_리소스정리.sql 로 분리되었다. |
| 98 | `98_리소스정리.sql` | SQL | 리소스 정리 (전체 원상복구) | 실습에서 만든 모든 Snowflake 객체와 외부(소스 DB) 리소스를 역순으로 삭제해 실습 전 상태로 되돌린다. 비용 경고, 일시 중단 선택지, 상태 전이 절차, 원복 항목, 완료 검증 쿼리, 체크리스트를 포함한다. |
| 99 | `99_generate_index.py` | Python | 인덱스 생성 스크립트 | 이 폴더의 문서를 스캔해 각 파일 최상단 메타 주석을 파싱하고 00_index.md 를 재생성한다. 항상 덮어쓰므로 반복 실행이 안전하다. |

## 실습 진행 순서

1. **`01_교육자료_정리본.md`** — 교육자료 정리본 — Openflow Gen 2로 CDC 구현하기 📖 *개요 — 먼저 읽어 주세요*
   - Openflow Gen 2 SQL API로 PostgreSQL/MySQL CDC 파이프라인을 구축해 Snowflake로 데이터를 적재하는 실습의 개념, 아키텍처, 전체 흐름, 사전 준비물을 정리한다.
2. **`02_사전준비_및_권한구성.sql`** — 사전 준비 및 권한 구성
   - Openflow Gen 2 사용 가능 여부 게이트 확인 후, Role 3종(admin/DE/execute-as), 인프라 DB/스키마, Warehouse, 대상 DB, Event Table을 생성한다.
3. **`03_openflow_배포_및_런타임_생성.sql`** — Openflow 배포 및 런타임 생성
   - Gen 2 OPENFLOW DEPLOYMENT 와 OPENFLOW RUNTIME 을 SQL로 생성하고, 비동기 프로비저닝을 WAIT 함수로 대기한 뒤 Event Table 을 연결한다.
4. **`04_소스DB_준비_및_CDC설정_postgresql.md`** — 소스 PostgreSQL 준비 및 CDC 설정 ⚠️ *Snowflake 외부/혼합 작업*
   - Snowflake 외부 작업. 소스 PostgreSQL 에서 wal_level=logical, 복제 사용자, PUBLICATION, 실습 테이블(PK 포함)을 설정하고 호스트명/포트를 확보한다.
5. **`05_네트워크_규칙_및_EAI_구성.sql`** — 네트워크 규칙, EAI, Secret 구성
   - 소스 호스트 egress 를 허용하는 Network Rule 과 External Access Integration 을 만들고 Runtime 에 연결한 뒤, 소스 비밀번호를 담을 GENERIC_STRING Secret 을 준비한다.
6. **`06_커넥터_생성.sql`** — 커넥터 생성
   - OPENFLOW_POSTGRES_CDC 정의로 커넥터 객체를 생성하고 STOPPED 상태까지 대기한 뒤, config.json 편집에 필요한 live 버전 스테이지 URI 를 확보한다.
7. **`07_커넥터_설정_config_json.md`** — 커넥터 설정 (JDBC 드라이버 + config.json) ⚠️ *Snowflake 외부/혼합 작업*
   - 혼합 작업. PostgreSQL JDBC 드라이버 JAR 을 업로드하고 config.json 을 GET/편집/업로드한다. Snowsight 는 PUT 이 차단되므로 COPY INTO + COPY FILES 경로를 사용한다.
8. **`08_커넥터_커밋_및_기동.sql`** — 커넥터 커밋, 검증, 기동
   - config.json 을 COMMIT 하고 VALIDATE CONFIGURATION 으로 사전 검증한 뒤 커넥터를 START 하여 RUNNING 상태까지 대기한다. START_FAILED 진단 쿼리 포함.
9. **`09_적재결과_검증.sql`** — 적재 결과 검증
   - 스냅샷 단계에서 대상 스키마/테이블 자동 생성과 초기 행 수를 확인하고, 소스의 INSERT/UPDATE/DELETE 가 CDC 로 반영되는지 단계별로 검증한다.
10. **`10_부록_MySQL_차이점.md`** — 부록 — MySQL CDC 로 전환할 때의 차이점 ⚠️ *Snowflake 외부/혼합 작업*
   - 동일한 실습 흐름을 MySQL/MariaDB 소스로 바꿀 때 달라지는 부분만 정리한다. binlog 설정, 권한, 드라이버, config 프로퍼티, 제약사항.
11. **`11_트러블슈팅.md`** — 트러블슈팅 ⚠️ *Snowflake 외부/혼합 작업*
   - 증상별 진단 절차, 단계별 오류 메시지 대응표, Event Table 조회 쿼리, Connector Observability 활용법을 제공한다. 리소스 정리는 98_리소스정리.sql 로 분리되었다.
98. **`98_리소스정리.sql`** — 리소스 정리 (전체 원상복구)
   - 실습에서 만든 모든 Snowflake 객체와 외부(소스 DB) 리소스를 역순으로 삭제해 실습 전 상태로 되돌린다. 비용 경고, 일시 중단 선택지, 상태 전이 절차, 원복 항목, 완료 검증 쿼리, 체크리스트를 포함한다.

## 의존 관계

| 문서 | 선행 문서 | 다음 문서 |
|------|-----------|-----------|
| `01_교육자료_정리본.md` | 없음 | 02_사전준비_및_권한구성.sql |
| `02_사전준비_및_권한구성.sql` | 없음 | 03_openflow_배포_및_런타임_생성.sql |
| `03_openflow_배포_및_런타임_생성.sql` | 02_사전준비_및_권한구성.sql | 04_소스DB_준비_및_CDC설정_postgresql.md |
| `04_소스DB_준비_및_CDC설정_postgresql.md` | 03_openflow_배포_및_런타임_생성.sql | 05_네트워크_규칙_및_EAI_구성.sql |
| `05_네트워크_규칙_및_EAI_구성.sql` | 04_소스DB_준비_및_CDC설정_postgresql.md | 06_커넥터_생성.sql |
| `06_커넥터_생성.sql` | 05_네트워크_규칙_및_EAI_구성.sql | 07_커넥터_설정_config_json.md |
| `07_커넥터_설정_config_json.md` | 06_커넥터_생성.sql | 08_커넥터_커밋_및_기동.sql |
| `08_커넥터_커밋_및_기동.sql` | 07_커넥터_설정_config_json.md | 09_적재결과_검증.sql |
| `09_적재결과_검증.sql` | 08_커넥터_커밋_및_기동.sql | 10_부록_MySQL_차이점.md |
| `10_부록_MySQL_차이점.md` | 09_적재결과_검증.sql | 11_트러블슈팅.md |
| `11_트러블슈팅.md` | 09_적재결과_검증.sql | 98_리소스정리.sql |
| `98_리소스정리.sql` | 09_적재결과_검증.sql | 없음 (마지막 문서) |
| `99_generate_index.py` | 없음 | 없음 |

## 유형별 문서 수

| 유형 | 개수 |
|------|------|
| MD | 5 |
| Python | 1 |
| SQL | 7 |

