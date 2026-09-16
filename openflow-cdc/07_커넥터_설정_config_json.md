<!--
title: 커넥터 설정 (JDBC 드라이버 + config.json)
step: 07
type: md
summary: 혼합 작업. PostgreSQL JDBC 드라이버 JAR 을 업로드하고 config.json 을 GET/편집/업로드한다. Snowsight 는 PUT 이 차단되므로 COPY INTO + COPY FILES 경로를 사용한다.
requires: 06_커넥터_생성.sql
next: 08_커넥터_커밋_및_기동.sql
-->

# 07. 커넥터 설정 — JDBC 드라이버 및 config.json

> ⚠️ **이 단계는 SQL 만으로 완결되지 않습니다.**
> 외부에서 JAR 파일을 다운로드하고, `config.json` 을 로컬에서 편집한 뒤
> Snowflake 스테이지로 올려야 합니다. 그래서 문서를 분리했습니다.

> ### 검증 상태
> ⚠️ **커넥터가 존재하지 않아 이 문서의 SQL 은 실제 실행 검증을 하지 못했습니다.**
> 문법은 Snowflake 공식 문서(`Configure a gen 2 connector with SQL`, `COPY INTO`,
> `COPY FILES`, `GET`)로 대조 확인했습니다.
> ✅ Snowsight 에서 `PUT` 이 차단되는 제약은 이 세션에서 확인된 사실입니다.

---

## 0. 두 가지 경로 중 선택

| 경로 | 방식 | 추천 대상 |
|------|------|-----------|
| **A. 설정 위저드 (UI)** | Openflow UI 의 Guided Wizard 에서 드라이버 업로드와 테이블 선택을 GUI 로 처리 | **최초 실습자에게 권장.** 테이블/컬럼 선택이 훨씬 쉽고 검증이 자동 |
| **B. SQL + 스테이지 (이 문서)** | `GET` → 로컬 편집 → `COPY INTO` → `COPY FILES` | 자동화·재현성이 필요한 경우. Gen 2 의 원리를 이해하는 데 유용 |

두 경로 모두 결과는 동일한 `config.json` 입니다. 이 문서는 **B** 를 다루고,
A 를 선택하는 방법은 6장에 정리했습니다.

---

## 1. 입력값 정리

06번 문서와 04번 문서에서 확보한 값입니다.

```
LIVE_VERSION_URI = snow://...                      (06번 STEP 3)
HOSTNAME         = CHANGE_ME.rds.amazonaws.com     (04번)
PORT             = 5432                            (04번)
DATABASE         = cdclab                          (04번)
REPL_USER        = openflow_repl                   (04번)
PUBLICATION      = openflow_pub                    (04번)
SECRET_FQN       = OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET
DEST_DB          = CDC_LAB_PG_DB
WAREHOUSE        = OPENFLOW_EDU_WH
```

JDBC URL 은 위 값으로 조립합니다.

```
jdbc:postgresql://<HOSTNAME>:<PORT>/<DATABASE>?sslmode=require
```

> `?sslmode=require` 누락은 `START_FAILED` 의 흔한 원인입니다.
> SSL 을 요구하는 소스(관리형 서비스 대부분)에서는 반드시 포함하세요.

---

## 2. PostgreSQL JDBC 드라이버 준비

### 2-1. 다운로드

Maven Central 에서 최신 안정 버전의 **plain JAR** 을 받습니다.

```
https://central.sonatype.com/artifact/org.postgresql/postgresql/versions
```

- `-sources.jar`, `-javadoc.jar` 가 **아닌** 파일을 받으세요.
- 예: `postgresql-42.7.10.jar`
- 실제 다운로드는 `repo1.maven.org` 에서 서비스되며, 이는 CDC 커넥터의
  네트워크 허용 목록에 포함되어 있습니다.

### 2-2. 업로드

드라이버는 커넥터의 live 버전 스테이지에 올립니다. 방법은 실행 환경에 따라 다릅니다.

| 환경 | 방법 |
|------|------|
| **Snowsight (브라우저)** | ⚠️ `PUT` 이 차단됩니다. **설정 위저드(경로 A)의 드라이버 업로드 단계**를 사용하거나, Snowsight 스테이지 UI 로 업로드하세요. |
| **Snow CLI / SnowSQL (로컬)** | `PUT` 사용 가능 |

Snow CLI / SnowSQL:

```sql
PUT 'file:///path/to/postgresql-42.7.10.jar'
    '<LIVE_VERSION_URI>'
    AUTO_COMPRESS = FALSE
    OVERWRITE     = TRUE;
```

> ⚠️ Snowsight 에서 `PUT` 을 시도하면 `Permission denied by user` 로 실패합니다.
> "한 번만 확인해 보자"는 시도도 하지 마세요. 샌드박스 파일시스템이나
> 동작하는 `GET` 이 있다고 해서 `PUT` 이 허용되는 것은 아닙니다.
> `snow` CLI 를 우회 수단으로 쓰는 것도 동일하게 차단됩니다.

업로드한 파일명을 기록하세요. `config.json` 의 `assetIds` 에 그대로 넣습니다.

```
DRIVER_FILENAME = ____________________________ (예: postgresql-42.7.10.jar)
```

---

## 3. config.json 읽기

`GET` 은 모든 환경에서 동작합니다(차단되지 않음).

```sql
GET '<LIVE_VERSION_URI>/config.json' 'file:///tmp/';
```

> ⚠️ 존재하지 않는 로컬 디렉터리를 지정하면 `ENOENT` 로 실패합니다.
> 이미 존재하는 디렉터리를 쓰세요(`/tmp` 등).
>
> ⚠️ `SELECT $1 FROM 'snow://...'` 방식으로 읽는 것은 **동작하지 않습니다.**
> 반드시 `GET` 을 사용하세요.

### config.json 구조

```json
{
  "configFormatVersion": 1,
  "connectorDefinitionId": "OPENFLOW_POSTGRES_CDC",
  "configuration": [
    {"name": "Source",                     "properties": {}},
    {"name": "Replication table schema",   "properties": {}},
    {"name": "Replication columns",        "properties": {}},
    {"name": "Destination authentication", "properties": {}},
    {"name": "Destination details",        "properties": {}},
    {"name": "Tuning",                     "properties": {}},
    {"name": "Migration",                  "properties": {}}
  ]
}
```

### 프로퍼티 값 타입 3종

| 타입 | 형식 | 용도 |
|------|------|------|
| `STRING_LITERAL` | `{"valueType":"STRING_LITERAL","value":"..."}` | URL, 사용자명, 테이블 목록 |
| `SECRET_REFERENCE` | `{"valueType":"SECRET_REFERENCE","fullyQualifiedSecretName":"db.schema.secret"}` | 비밀번호 |
| `ASSET_REFERENCE` | `{"valueType":"ASSET_REFERENCE","assetIds":["파일명.jar"]}` | JDBC 드라이버 |

---

## 4. 설정할 값 (섹션별)

### Source

| 프로퍼티 | 값 | 타입 |
|----------|-----|------|
| `Source Database Connection URL` | `jdbc:postgresql://<HOSTNAME>:5432/<DATABASE>?sslmode=require` | STRING_LITERAL |
| `Source Database User` | `openflow_repl` | STRING_LITERAL |
| `Source Database Password` | `OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET` | **SECRET_REFERENCE** |
| `Source Database Driver` | `["postgresql-42.7.10.jar"]` | **ASSET_REFERENCE** |
| `Source Database Publication Name` | `openflow_pub` | STRING_LITERAL |

### Replication table schema

| 프로퍼티 | 값 |
|----------|-----|
| `Included Comma Separated Source Table Names` | `"public"."customers","public"."orders"` |

> ⚠️ **형식이 까다롭습니다.** 스키마와 테이블 이름을 각각 큰따옴표로 감싸고
> 쉼표로 구분합니다. JSON 안에서는 `\"public\".\"customers\"` 로 이스케이프됩니다.
> 이 백슬래시가 5장의 이중화 처리 대상입니다.
>
> 정규식으로 지정하려면 `Included Table Regex` 를 사용합니다 (예: `public\..*`).
> 둘 다 지정하면 합집합입니다.

### Destination authentication

| 프로퍼티 | 값 |
|----------|-----|
| `Snowflake Authentication Strategy` | `SNOWFLAKE_MANAGED` |

> Snowflake 배포에서는 SPCS 세션 토큰을 자동으로 사용합니다.
> 키페어 생성·회전이 필요 없습니다.

### Destination details

| 프로퍼티 | 값 |
|----------|-----|
| `Snowflake Destination Database` | `CDC_LAB_PG_DB` |
| `Snowflake Warehouse` | `OPENFLOW_EDU_WH` |
| `Object Identifier Resolution` | `CASE_INSENSITIVE` |
| `Destination Schema Pattern` | `${source.schema.name}` (기본값) |

> `CASE_INSENSITIVE`: PostgreSQL 의 소문자 `public.customers` 가
> Snowflake 에서 `PUBLIC.CUSTOMERS` 로 매핑됩니다. 실습에는 이 값이 편합니다.

### Migration

| 프로퍼티 | 값 |
|----------|-----|
| `Ingestion Type` | `full` |

> `full` = 스냅샷(초기 전량) 후 CDC. **최초 설치는 반드시 `full`.**
> `incremental` 은 재설치 시 스냅샷을 생략할 때만 사용합니다.

### Tuning (선택)

| 프로퍼티 | 기본값 | 실습 권장 |
|----------|--------|-----------|
| `Merge Task Schedule CRON` | `* * * * * ?` (매초) | 기본값 유지 — CDC 반영을 빨리 확인할 수 있습니다 |
| `Concurrent Snapshot Queries` | `2` | 기본값 유지 |

---

## 5. config.json 편집 및 업로드

### 5-1. 편집 (Python)

```python
import json

CONFIG_PATH = '/tmp/config.json'

# 변경할 값: {섹션명: {프로퍼티명: 새 값}}
edits = {
    "Source": {
        "Source Database Connection URL":
            "jdbc:postgresql://CHANGE_ME.rds.amazonaws.com:5432/cdclab?sslmode=require",
        "Source Database User": "openflow_repl",
        "Source Database Publication Name": "openflow_pub",
    },
    "Replication table schema": {
        "Included Comma Separated Source Table Names":
            '"public"."customers","public"."orders"',
    },
    "Destination authentication": {
        "Snowflake Authentication Strategy": "SNOWFLAKE_MANAGED",
    },
    "Destination details": {
        "Snowflake Destination Database": "CDC_LAB_PG_DB",
        "Snowflake Warehouse": "OPENFLOW_EDU_WH",
        "Object Identifier Resolution": "CASE_INSENSITIVE",
    },
    "Migration": {
        "Ingestion Type": "full",
    },
}

with open(CONFIG_PATH) as f:
    config = json.load(f)

for section_name, props in edits.items():
    for section in config['configuration']:
        if section['name'] == section_name:
            for prop_name, new_val in props.items():
                if prop_name in section['properties']:
                    section['properties'][prop_name]['value'] = new_val
                else:
                    section['properties'][prop_name] = {
                        'valueType': 'STRING_LITERAL', 'value': new_val
                    }

# SECRET_REFERENCE 와 ASSET_REFERENCE 는 구조가 달라 따로 설정합니다.
for section in config['configuration']:
    if section['name'] == 'Source':
        section['properties']['Source Database Password'] = {
            'valueType': 'SECRET_REFERENCE',
            'fullyQualifiedSecretName':
                'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET',
        }
        section['properties']['Source Database Driver'] = {
            'valueType': 'ASSET_REFERENCE',
            'assetIds': ['postgresql-42.7.10.jar'],   # 실제 업로드한 파일명
        }

# ⚠️ 반드시 compact JSON 으로 저장 (원본 포맷과 일치시킴)
with open(CONFIG_PATH, 'w') as f:
    json.dump(config, f, separators=(',', ':'))

print("config.json 편집 완료")
```

### 5-2. 업로드 — Snow CLI / SnowSQL

```sql
PUT 'file:///tmp/config.json' '<LIVE_VERSION_URI>'
    AUTO_COMPRESS = FALSE
    OVERWRITE     = TRUE;
```

### 5-3. 업로드 — Snowsight (`PUT` 차단 환경)

Snowsight 에서는 `COPY INTO` → `COPY FILES` 경로를 사용합니다.

#### (1) SQL 문자열용으로 이스케이프

```python
with open('/tmp/config.json') as f:
    data = f.read()

# ⚠️ 두 처리를 모두 해야 합니다.
sql_safe = data.replace('\\', '\\\\').replace("'", "''")

with open('/tmp/config_sql_ready.txt', 'w') as f:
    f.write(sql_safe)

print(f"원본 {len(data)} bytes → 변환 {len(sql_safe)} bytes")
```

> ⚠️ **백슬래시 이중화 (`\` → `\\`) — 가장 흔한 실패 원인**
> Snowflake 의 단일 인용 문자열은 `\` 를 이스케이프 문자로 취급합니다.
> 처리하지 않으면 JSON 의 `\"` 가 맨 `"` 로 바뀌어 구조가 깨지고,
> `COMMIT` 이 `Invalid connector configuration file at location:
> 'config.json'` 으로 실패합니다.
> 테이블 목록 `\"public\".\"customers\"` 때문에 CDC 커넥터에서 특히 자주 발생합니다.
> 업로드/커밋을 반복해도 해결되지 않습니다 — 원인이 여기입니다.
>
> ⚠️ **단일 인용 이스케이프 (`'` → `''`)**
> 설정값에 아포스트로피가 있으면 `COPY INTO ... FROM (SELECT '...')` 문
> 자체가 문법 오류(문자열 미종료)로 실패합니다. 백슬래시 문제와는
> **실패 지점이 다릅니다** — JSON 이 스테이지에 도달하기도 전에 깨집니다.

#### (2) 스테이지 준비

```sql
USE ROLE OPENFLOW_EDU_DE_RL;
SELECT CURRENT_ROLE();   -- 스테이지 이름에 사용

-- Role 별로 하나만 만들어 재사용합니다 (영속 객체).
CREATE STAGE IF NOT EXISTS
  OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_CONFIG_STAGE_OPENFLOW_EDU_DE_RL
  COMMENT = 'Gen 2 config 편집용 스테이징. [openflow-edu]';
```

> 왜 Role 별인가: 스테이지는 생성한 Role 이 소유하므로, 스키마당 하나를
> 공유하면 다른 Role 이 쓸 수 없습니다.
> 왜 영속인가: Snowsight 에서는 DDL 마다 승인이 필요합니다. 유지하면
> 이후 편집 시 `CREATE` / `DROP` 승인 2회를 아낄 수 있습니다.
> 비어 있는 스테이지는 스토리지 비용이 없습니다.

#### (3) 스테이지에 기록

`/tmp/config_sql_ready.txt` 내용을 아래 `'...'` 안에 붙여 넣습니다.

```sql
COPY INTO @OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_CONFIG_STAGE_OPENFLOW_EDU_DE_RL/config.json
FROM (SELECT '<여기에 이스케이프된 JSON 전체>')
SINGLE      = TRUE
OVERWRITE   = TRUE
HEADER      = FALSE
FILE_FORMAT = (TYPE = CSV
               FIELD_OPTIONALLY_ENCLOSED_BY = NONE
               FIELD_DELIMITER              = NONE
               ESCAPE                       = NONE
               ESCAPE_UNENCLOSED_FIELD      = NONE
               COMPRESSION                  = NONE)
MAX_FILE_SIZE = 67108864;
```

> ⚠️ **`COMPRESSION = NONE` 필수.** 없으면 `config.json` 이라는 이름의
> gzip 덩어리가 만들어지고 커밋이 조용히 실패합니다.
>
> ✅ **검증**: 결과의 `input_bytes` 와 `output_bytes` 가 **같아야** 합니다.
> `output_bytes` 가 더 작으면 압축된 것입니다 → `REMOVE` 후 재실행하세요.
>
> ⚠️ 임시 테이블(`CREATE TEMPORARY TABLE` + `INSERT`)로 우회하지 마세요.
> 별도의 SQL 실행 호출 사이에서 임시 테이블은 유지되지 않습니다.
> JSON 을 `COPY INTO ... FROM (SELECT '...')` 안에 인라인해야 합니다.

#### (4) 커넥터 live 버전으로 복사

```sql
COPY FILES INTO '<LIVE_VERSION_URI>/'
FROM @OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_CONFIG_STAGE_OPENFLOW_EDU_DE_RL
FILES = ('config.json');
```

스테이지는 삭제하지 않습니다. 다음 편집에서 재사용합니다.

---

## 6. 경로 A — 설정 위저드 사용법

최초 실습이라면 이 경로가 더 쉽습니다.

1. Snowsight → 좌측 메뉴 **Ingestion » Openflow** → **Launch Openflow**
2. **Connector library** 탭에서 `PostgreSQL` (Gen 2) 선택
3. 설치할 Runtime 으로 `OPENFLOW_EDU_RUNTIME` 선택
4. 위저드에 아래 값을 입력

| 항목 | 값 |
|------|-----|
| JDBC URL | `jdbc:postgresql://<HOSTNAME>:5432/<DATABASE>?sslmode=require` |
| Source Database User | `openflow_repl` |
| Source Database Password (Secret) | `OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_SOURCE_SECRET` |
| Driver JAR | 2-1 에서 받은 `postgresql-*.jar` 업로드 |
| Publication Name | `openflow_pub` |
| Destination Database | `CDC_LAB_PG_DB` |
| Warehouse | `OPENFLOW_EDU_WH` |
| Ingestion Type | `full` |

5. 테이블 선택 단계에서 `public.customers`, `public.orders` 체크
6. 검증(Verification) 단계 통과 후 저장

> 좌측 메뉴에 **Ingestion » Openflow** 가 보이지 않으면 계정에 Openflow UI
> 가 노출되지 않은 것입니다(Trial 계정에서 흔함). 이 경우 경로 B 를
> 사용하거나 계정 팀에 문의하세요.

> 위저드가 생성한 `config.json` 은 3장의 `GET` 으로 내려받아
> 이후 SQL 기반 배포의 템플릿으로 재사용할 수 있습니다.

---

## 7. 완료 체크리스트

- [ ] JDBC 드라이버 JAR 을 live 버전 스테이지에 업로드했다
- [ ] `assetIds` 에 실제 업로드한 파일명을 정확히 넣었다
- [ ] `Source Database Password` 가 `SECRET_REFERENCE` 타입이고 FQN 이 `db.schema.secret` 형식이다
- [ ] JDBC URL 에 `?sslmode=require` 가 포함되었다
- [ ] 테이블 목록이 `"public"."customers","public"."orders"` 형식이다
- [ ] `Ingestion Type` = `full`
- [ ] `Snowflake Authentication Strategy` = `SNOWFLAKE_MANAGED`
- [ ] (Snowsight) 백슬래시 이중화와 단일 인용 이스케이프를 모두 적용했다
- [ ] (Snowsight) `COPY INTO` 결과에서 `input_bytes` = `output_bytes` 를 확인했다
- [ ] `COPY FILES` 로 live 버전에 복사했다

---

## 🧹 리소스 정리 (이 문서에서 만든 것)

> ⚠️ 정본은 `98_리소스정리.sql` **PART C-4** 입니다.
> 이 문서는 **Stage 한 개**를 만듭니다. 객체 대장에 등재된 항목이므로
> 실습 종료 시 반드시 삭제해야 합니다.

```sql
-- 실습을 계속할 예정이면 삭제하지 마세요 — 다음 config 편집에서 재사용합니다.
-- USE ROLE OPENFLOW_EDU_DE_RL;
-- DROP STAGE IF EXISTS
--   OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.OPENFLOW_CONFIG_STAGE_OPENFLOW_EDU_DE_RL;
--
-- 확인
-- SHOW STAGES IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;
```

> 💡 `OPENFLOW_EDU_DB` 를 DROP 하면 이 Stage 도 함께 사라집니다.
> 명시적 DROP 이 필요한 것은 DB 를 보존하기로 선택한 경우입니다.
>
> 🔒 **로컬 파일 정리**: 편집한 `config.json` 에는 소스 DB 사용자명과
> JDBC URL 이 담깁니다(비밀번호는 Secret 참조이므로 평문이 아닙니다).
> 작업이 끝나면 로컬 임시 파일을 삭제하는 것이 안전합니다.

---

**다음 문서**: `08_커넥터_커밋_및_기동.sql` (Snowflake 로 복귀)
