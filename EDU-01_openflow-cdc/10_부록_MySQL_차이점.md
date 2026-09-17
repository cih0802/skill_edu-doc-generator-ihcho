<!--
title: 부록 — MySQL CDC 로 전환할 때의 차이점
step: 10
type: md
summary: 동일한 실습 흐름을 MySQL/MariaDB 소스로 바꿀 때 달라지는 부분만 정리한다. binlog 설정, 권한, 드라이버, config 프로퍼티, 제약사항.
requires: 09_적재결과_검증.sql
next: 11_트러블슈팅.md
-->

# 10. 부록 — MySQL / MariaDB CDC 로 전환할 때의 차이점

이 문서는 **02~09번 문서의 흐름을 그대로 재사용**하면서, PostgreSQL 대신
MySQL 또는 MariaDB 를 소스로 쓸 때 **달라지는 부분만** 정리합니다.

> MariaDB 도 동일한 `OPENFLOW_MYSQL_CDC` 커넥터 정의를 사용합니다.

> ### 검증 상태
> ⚠️ **이 문서의 SQL 은 전부 미검증입니다.** 접근 가능한 MySQL/MariaDB
> 인스턴스가 없어 실행 검증을 하지 못했습니다. 문법은 MySQL 공식 문서 및
> Snowflake Openflow MySQL 커넥터 설정 문서로 대조 확인했습니다.
> ✅ `SHOW OPENFLOW CONNECTOR DEFINITIONS` 에 `OPENFLOW_MYSQL_CDC` 가
> 존재하는 것은 이 세션에서 실행 확인했습니다.

> ### 객체 대장 보완
> MySQL 경로를 택하면 `01_교육자료_정리본.md` 객체 대장 **(c) 외부 리소스**의
> PostgreSQL 행 대신 MySQL 행이 적용됩니다.
> 추가로 만들어지는 것: MySQL 사용자 `openflow_repl@%`, 스키마 `cdclab`,
> binlog 관련 파라미터 변경 여러 건.
> 정리는 `98_리소스정리.sql` **PART D-2** 를 사용하세요.
> Snowflake 측 객체는 PostgreSQL 경로와 동일합니다(대상 DB 이름만
> `CDC_LAB_MYSQL_DB` 등으로 바꾸는 것을 권장하며, 바꿨다면 대장과 `98_` 에도
> 반영하세요).

---

## 1. 변경되지 않는 것

다음은 PostgreSQL 실습과 완전히 동일합니다. 문서를 그대로 따르면 됩니다.

- `02_사전준비_및_권한구성.sql` — Role 3종, 인프라 DB/스키마, Warehouse, Event Table
  - 단, 대상 DB 이름만 `CDC_LAB_MYSQL_DB` 등으로 구분하는 것을 권장합니다.
- `03_openflow_배포_및_런타임_생성.sql` — Deployment / Runtime (아래 2장의 사이즈 항목만 참고)
- `05_네트워크_규칙_및_EAI_구성.sql` — Network Rule / EAI / Secret
  - 포트만 `5432` → `3306` 으로 변경
- `06`, `08`, `09` — 커넥터 생성 / 커밋·기동 / 검증 절차
  - 커넥터 정의 이름만 `OPENFLOW_POSTGRES_CDC` → `OPENFLOW_MYSQL_CDC`

---

## 2. Runtime 사이즈 요구사항 차이

| 항목 | PostgreSQL CDC | MySQL CDC |
|------|----------------|-----------|
| 멀티노드 | 미지원 (MIN/MAX = 1) | 미지원 (MIN/MAX = 1) |
| 최소 사이즈 | Small 가능 (저볼륨 단일 커넥터) | **최소 사이즈 요구 없음.** 어떤 사이즈든 동작하며 Medium 이 일반적인 기본값 |

실습 규모에서는 양쪽 모두 `NODE_TYPE = SMALL`, `NODE_TYPE_TIER = 'S1'` 로 충분합니다.

> 두 커넥터 모두 런타임 버전 **2026.8.25.11 이상**을 요구합니다.

---

## 3. 소스 설정 차이 — 04번 문서 대체

PostgreSQL 의 `wal_level` / PUBLICATION / 복제 슬롯 대신 **binary log** 를 사용합니다.

### 3-1. binlog 설정 (`my.cnf` 또는 파라미터 그룹)

| 설정 | 필수 값 | 설명 |
|------|---------|------|
| `log_bin` | `on` | binary logging 활성화 |
| `binlog_format` | `row` | 커넥터는 row 기반 복제만 지원 |
| `binlog_row_metadata` | `full` | 컬럼명과 PK 정보를 얻기 위해 필수 |
| `binlog_row_image` | `full` | 모든 컬럼을 로그에 기록 |
| `binlog_row_value_options` | *(비워 둠)* | 부분 JSON 문서 미지원 — 반드시 비어 있어야 함 |
| `binlog_expire_logs_seconds` | 3일 이상 권장 | 주말·연휴에 복제가 끊기지 않도록 |
| `sort_buffer_size` | `4194304` | "Out of sort memory" 오류 방지 |

```ini
log_bin                  = on
binlog_format            = row
binlog_row_metadata      = full
binlog_row_image         = full
binlog_row_value_options =
sort_buffer_size         = 4194304
```

> ⚠️ `log_bin` 또는 `binlog_format` 을 변경하면 **MySQL/MariaDB 재시작이 필요**합니다.

### 3-2. 관리형 서비스별 주의사항

| 서비스 | 주의사항 |
|--------|----------|
| **AWS RDS** | 파라미터 그룹에서 설정. 보존 기간은 `CALL mysql.rds_set_configuration('binlog retention hours', N);` |
| **Amazon Aurora** | `binlog_row_image` 가 `full` 로 고정 — 변경 불필요. **리더 인스턴스는 미지원** (자체 binlog 를 유지하지 않음) |
| **GCP Cloud SQL** | `binlog_format` 이 `row` 로 고정 — 변경 불필요 |
| **Azure Database for MySQL** | `binlog_row_metadata` 를 사용자가 변경할 수 없음 → **Microsoft 지원 티켓 필요** |

### 3-3. 읽기 복제본에 연결하는 경우

```ini
log_replica_updates = ON
```

### 3-4. MariaDB 전용 설정

```ini
binlog_legacy_event_pos = ON
```

MariaDB Connector/J 드라이버가 복제 중 binlog 위치를 올바르게 추적하기 위해 필요합니다.

### 3-5. 복제 사용자 생성 및 권한

> 🔴 **MySQL 8.0 이상에서는 `GRANT` 가 사용자를 자동 생성하지 않습니다.**
> (`NO_AUTO_CREATE_USER` 모드가 제거되면서 이 동작이 사라졌습니다.)
> 반드시 `CREATE USER` 를 먼저 실행해야 합니다.
> PostgreSQL 경로(04번 문서)는 `CREATE USER` 를 명시하고 있으나
> 이 부록은 누락되어 있었습니다.

```sql
-- (1) 사용자 생성 — 반드시 GRANT 보다 먼저
CREATE USER IF NOT EXISTS 'openflow_repl'@'%'
  IDENTIFIED BY 'CHANGE_ME_STRONG_PASSWORD';
-- MySQL 8.0 기본 인증 플러그인은 caching_sha2_password 입니다.
-- 구형 JDBC 드라이버로 접속이 거부되면 아래를 사용하세요.
-- ALTER USER 'openflow_repl'@'%'
--   IDENTIFIED WITH mysql_native_password BY 'CHANGE_ME_STRONG_PASSWORD';

-- (2) 복제 권한
GRANT REPLICATION SLAVE  ON *.* TO 'openflow_repl'@'%';
GRANT REPLICATION CLIENT ON *.* TO 'openflow_repl'@'%';

-- 복제할 스키마의 SELECT 권한
GRANT SELECT ON cdclab.* TO 'openflow_repl'@'%';
-- 또는 특정 테이블만
-- GRANT SELECT ON cdclab.customers TO 'openflow_repl'@'%';

FLUSH PRIVILEGES;

-- (3) 확인
SELECT user, host, plugin FROM mysql.user WHERE user = 'openflow_repl';
SHOW GRANTS FOR 'openflow_repl'@'%';
```

> ⚠️ 위 비밀번호는 05번 문서의 `PG_SOURCE_SECRET`(MySQL 경로에서도 같은
> Secret 객체를 재사용합니다) 에 넣는 값과 반드시 일치해야 합니다.

### 3-6. server_id 확인

```sql
SHOW VARIABLES LIKE 'server_id';
```

**0 이 아닌, 복제 토폴로지 내에서 유일한 정수**여야 합니다. 아니면 `my.cnf` 에 추가하고 재시작합니다.

```ini
server-id = 1001
```

### 3-7. 설정 검증 쿼리

```sql
SHOW VARIABLES WHERE Variable_name IN (
    'log_bin', 'binlog_format', 'binlog_row_metadata',
    'binlog_row_image', 'binlog_row_value_options', 'server_id'
);
```

### 3-8. 실습 테이블 (PK 필수)

```sql
CREATE TABLE IF NOT EXISTS customers (
    customer_id   INT          PRIMARY KEY,
    customer_name VARCHAR(100) NOT NULL,
    email         VARCHAR(200),
    grade         VARCHAR(20)  DEFAULT 'BRONZE',
    updated_at    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS orders (
    order_id     INT            PRIMARY KEY,
    customer_id  INT            NOT NULL,
    product_name VARCHAR(100),
    amount       DECIMAL(12,2),
    order_status VARCHAR(20)    DEFAULT 'NEW',
    created_at   TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
);
```

> InnoDB 는 명시적 PK 가 없으면 **첫 번째 NOT NULL UNIQUE 인덱스를 PK 로 자동
> 승격**합니다. 둘 다 없으면 UPDATE/DELETE 가 유실되므로 논리 키를 설정해야 합니다.

---

## 4. 드라이버 차이 — 07번 문서 대체

PostgreSQL JDBC 대신 **MariaDB Connector/J** 를 사용합니다.
MySQL 소스에도 이 드라이버를 씁니다.

### 다운로드

```
https://repo1.maven.org/maven2/org/mariadb/jdbc/mariadb-java-client/3.5.3/mariadb-java-client-3.5.3.jar
```

최신 버전 확인:

```bash
curl -s "https://search.maven.org/solrsearch/select?q=g:org.mariadb.jdbc+AND+a:mariadb-java-client&rows=1&wt=json" \
  | jq -r '.response.docs[0].latestVersion'
```

### JDBC URL

```
jdbc:mariadb://<HOSTNAME>:3306
```

> - **`jdbc:mysql://` 이 아니라 `jdbc:mariadb://`** 입니다. MySQL 소스도 동일합니다.
> - DB 이름을 URL 에 포함하는 것은 **선택**입니다. 테이블은 Ingestion 파라미터로 선택합니다.
> - 소스에서 SSL 이 비활성화된 경우 `?allowPublicKeyRetrieval=true` 를 붙입니다.

---

## 5. config.json 프로퍼티 차이

### Source 섹션

| 프로퍼티 | PostgreSQL | MySQL |
|----------|-----------|-------|
| `Source Database Connection URL` | `jdbc:postgresql://host:5432/db?sslmode=require` | `jdbc:mariadb://host:3306` |
| `Source Database Driver` | `postgresql-42.7.10.jar` | `mariadb-java-client-3.5.3.jar` |
| `Source Database Publication Name` | `openflow_pub` (필수) | **해당 없음** — MySQL 은 PUBLICATION 개념이 없음 |

### 테이블 선택 섹션

| 프로퍼티 | PostgreSQL | MySQL |
|----------|-----------|-------|
| 명시적 테이블 목록 | `Included Comma Separated Source Table Names`<br>`"public"."customers","public"."orders"` | `Included Comma Separated Source Table Names`<br>`"cdclab"."customers","cdclab"."orders"` |
| 정규식 | `Included Table Regex` | `Included Source Table Pattern` ← **이름이 다름** |

> ⚠️ MySQL 은 `"데이터베이스"."테이블"` 형식입니다. PostgreSQL 의
> `"스키마"."테이블"` 과 자리는 같지만 의미가 다릅니다.
> **MySQL 의 데이터베이스가 Snowflake 의 스키마로 매핑**됩니다.
> 양쪽 모두 두 부분을 각각 큰따옴표로 감싸야 합니다.

### Destination 섹션 추가 항목

| 프로퍼티 | 값 | 설명 |
|----------|-----|------|
| `Destination Schema Strategy` | `SOURCE_SCHEMA` | MySQL DB 하나 → Snowflake 스키마 하나 |
| `Destination Schema Pattern` | (선택) `prefix_${source.schema.name}` | 커스텀 패턴 |
| `Destination Schema Prefix` / `Suffix` | (선택) | `SOURCE_SCHEMA` 로 도출된 이름에 접두/접미 부여 |

PostgreSQL 은 `Destination Schema Pattern` 만 사용합니다 (기본값 `${source.schema.name}`).

---

## 6. MySQL 고유 제약사항 (실습 전 반드시 확인)

| 제약 | 내용 |
|------|------|
| **미지원 컬럼 타입** | `GEOMETRY`, `GEOMETRYCOLLECTION`, `LINESTRING`, `MULTILINESTRING`, `MULTIPOINT`, `MULTIPOLYGON`, `POINT`, `POLYGON` |
| **Cascade delete** | `ON DELETE CASCADE` 는 **캡처되지 않습니다.** InnoDB 가 binlog 기록 없이 내부적으로 처리하기 때문입니다 |
| **스키마 변경** | 대부분 지원되지만 **PK 정의 변경**과 **숫자 컬럼의 precision/scale 변경**은 미지원 |
| **Aurora 리더** | 미지원 — 자체 binlog 를 유지하지 않음 |
| **인증** | username/password 만 지원 |

PostgreSQL 측 대응 제약:

| 제약 | 내용 |
|------|------|
| 멀티노드 | 미지원 (MIN/MAX = 1) |
| 인증 | username/password 만 지원 |
| identity key | PK + `REPLICA IDENTITY DEFAULT` 또는 UNIQUE 인덱스 + `REPLICA IDENTITY USING INDEX` |

---

## 7. 복제 연속성 차이

| 소스 | 중단 후 재개 동작 |
|------|------------------|
| **PostgreSQL** | 복제 슬롯이 스트림 위치를 보존 → 재시작 시 중단 지점부터 이어짐 (슬롯이 삭제·만료되지 않은 경우) |
| **MySQL** | binlog 위치를 추적 → **binlog 보존 기간 내라면** 이어짐. 보존 기간이 지나면 데이터 유실 |

> 그래서 MySQL 은 `binlog_expire_logs_seconds` 를 **3일 이상**으로 두는 것을 강력히 권장합니다.
> PostgreSQL 은 반대 방향의 주의가 필요합니다 — **비활성 복제 슬롯이 WAL 을
> 무한 축적해 소스 디스크를 채울 수 있습니다.**

---

## 8. MySQL 실습 시 변경 요약표

02~09번 문서를 그대로 쓰면서 아래 값만 치환하면 됩니다.

| 위치 | PostgreSQL 값 | MySQL 값 |
|------|--------------|----------|
| 02번 대상 DB | `CDC_LAB_PG_DB` | `CDC_LAB_MYSQL_DB` |
| 05번 Network Rule 포트 | `5432` | `3306` |
| 05번 Network Rule 이름 | `PG_SOURCE_NETWORK_RULE` | `MYSQL_SOURCE_NETWORK_RULE` |
| 05번 EAI 이름 | `PG_SOURCE_EAI` | `MYSQL_SOURCE_EAI` |
| 05번 Secret 이름 | `PG_SOURCE_SECRET` | `MYSQL_SOURCE_SECRET` |
| 06번 커넥터 정의 | `OPENFLOW_POSTGRES_CDC` | `OPENFLOW_MYSQL_CDC` |
| 06번 커넥터 이름 | `PG_CDC_CONNECTOR` | `MYSQL_CDC_CONNECTOR` |
| 07번 드라이버 | `postgresql-*.jar` | `mariadb-java-client-*.jar` |
| 07번 JDBC URL | `jdbc:postgresql://h:5432/db?sslmode=require` | `jdbc:mariadb://h:3306` |
| 07번 PUBLICATION | `openflow_pub` | (프로퍼티 없음) |
| 07번 테이블 목록 | `"public"."customers"` | `"cdclab"."customers"` |
| 07번 정규식 프로퍼티명 | `Included Table Regex` | `Included Source Table Pattern` |
| 09번 대상 스키마 | `CDC_LAB_PG_DB.PUBLIC` | `CDC_LAB_MYSQL_DB.CDCLAB` |

---


---

## 🧹 리소스 정리 — MySQL 경로로 실습했다면

> 🔴 **이 절은 2026-09-17 에 추가되었습니다.** 이 문서는 MySQL 소스에
> **사용자·권한·binlog 설정을 만들도록 안내하면서 정리 절차가 없었습니다.**
> Snowflake 쪽 정리(`98_`)만 수행하면 **소스 MySQL 에 실습 잔여물이 남습니다.**

Snowflake 쪽 객체는 `98_리소스정리.sql` 이 정본입니다. 아래는 **소스 MySQL 전용**입니다.
`98_` PART D-2 와 같은 내용이며, 어느 쪽을 실행해도 됩니다.

### (a) 계속 누적되는 것부터 — 우선순위 1

```sql
-- 이 실습이 만든 복제 사용자를 제거합니다.
-- 남겨 두면 불필요한 접근 경로가 유지되고, 복제 슬롯 성격의 자원이
-- binlog 보존을 붙잡을 수 있습니다.
DROP USER IF EXISTS 'openflow_repl'@'%';
FLUSH PRIVILEGES;
```

### (b) 실습용 스키마·데이터

```sql
-- ⚠️ 이 스키마에 실습 외 데이터를 넣었다면 실행하지 마십시오.
DROP DATABASE IF EXISTS cdclab;
```

### (c) 서버 설정 원복 — 🔴 재시작이 필요할 수 있습니다

`binlog_format` 등은 `DROP` 으로 되돌아가지 않는 **설정 변경**입니다.

```sql
-- 실습 전 값을 먼저 확인해 기록해 두었어야 합니다.
SHOW VARIABLES LIKE 'binlog_format';
SHOW VARIABLES LIKE 'binlog_row_image';
SHOW VARIABLES LIKE 'log_bin';
```

| 항목 | 실습 전 값 (기록) | 원복 방법 |
| :--- | :--- | :--- |
| `binlog_format` | `____________` | 실습 전 값으로 `SET GLOBAL binlog_format = <원래 값>;` |
| `binlog_row_image` | `____________` | 같은 방식 |
| `log_bin` | `____________` | my.cnf 수정 + **서버 재시작 필요** |

> 🔴 **실습 전 값을 기록해 두지 않았다면 원복할 수 없습니다.**
> `binlog_format` 은 MySQL 8.0 기준 기본값이 `ROW` 이므로 이미 `ROW` 였다면
> 변경 자체가 불필요했고 원복할 것도 없습니다. 값이 달랐다면
> 기록해 둔 값으로 되돌리십시오. `my.cnf` 에 영구 설정을 넣었다면
> 그 줄을 제거하고 재시작해야 합니다.

### (d) 정리 확인

```sql
SELECT user, host FROM mysql.user WHERE user = 'openflow_repl';   -- 0행이어야 합니다
SHOW DATABASES LIKE 'cdclab';                                      -- 0행이어야 합니다
```

- 남은 복제 사용자: `______` (없어야 합니다)
- 남은 실습 스키마: `______` (없어야 합니다)
- `binlog_format` 현재 값: `______` (실습 전 기록과 같아야 합니다)

---

**다음 문서**: `11_트러블슈팅.md` (참고) → `98_리소스정리.sql` (실습 종료 시 필수)
