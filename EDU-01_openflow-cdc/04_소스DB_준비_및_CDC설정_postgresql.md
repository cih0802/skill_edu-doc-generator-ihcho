<!--
title: 소스 PostgreSQL 준비 및 CDC 설정
step: 04
type: md
summary: Snowflake 외부 작업. 소스 PostgreSQL 에서 wal_level=logical, 복제 사용자, PUBLICATION, 실습 테이블(PK 포함)을 설정하고 호스트명/포트를 확보한다.
requires: 03_openflow_배포_및_런타임_생성.sql
next: 05_네트워크_규칙_및_EAI_구성.sql
-->

# 04. 소스 PostgreSQL 준비 및 CDC 설정

> ⚠️ **이 문서의 모든 작업은 Snowflake 외부에서 수행합니다.**
> 소스 PostgreSQL 인스턴스에 `psql` 등으로 접속해 진행하세요.
> 여기서 얻는 **호스트명 / 포트 / 사용자명 / 비밀번호 / PUBLICATION 이름**이
> 05번 이후 문서의 입력값입니다.

> ### 검증 상태
> ⚠️ **이 문서의 SQL 은 전부 미검증입니다.** 실습 준비 시점에 접근 가능한 외부
> PostgreSQL 인스턴스가 없어 실행 검증을 하지 못했습니다. 문법은 PostgreSQL
> 공식 문서(논리 복제, `CREATE PUBLICATION`, `REPLICA IDENTITY`) 및 Snowflake
> Openflow PostgreSQL 커넥터 설정 문서로 대조 확인했습니다.
> 관리형 서비스(RDS / Cloud SQL)는 `ALTER SYSTEM` 대신 파라미터 그룹을
> 사용하므로 각 절의 해당 안내를 따르세요.

---

## 0. 이 단계의 목표와 산출물

이 문서를 마치면 다음 5개 값을 손에 넣게 됩니다. 05~07번 문서에서 그대로 사용합니다.

| # | 산출물 | 예시 | 사용처 |
|---|--------|------|--------|
| 1 | 소스 호스트명 | `pg-cdc-lab.abcdefg.ap-northeast-1.rds.amazonaws.com` | 05번 Network Rule |
| 2 | 포트 | `5432` | 05번 Network Rule |
| 3 | 소스 DB 이름 | `cdclab` | 07번 JDBC URL |
| 4 | 복제 사용자 / 비밀번호 | `openflow_repl` / `********` | 05번 Secret, 07번 config |
| 5 | PUBLICATION 이름 | `openflow_pub` | 07번 config |

기록해 두세요.

```
HOSTNAME    = ______________________________________
PORT        = ______________________________________
DATABASE    = ______________________________________
REPL_USER   = ______________________________________
PUBLICATION = ______________________________________
```

---

## 1. 전제조건 확인 (가장 중요)

> ⚠️ **실습 실패 1순위 원인입니다. 반드시 먼저 확인하세요.**
>
> 05번 문서에서 실행할 `CREATE NETWORK RULE ... MODE = EGRESS` 는
> **생성 시점에 `VALUE_LIST` 의 모든 호스트를 DNS 검증**합니다.
> 해석되지 않으면 `invalid value for property 'VALUE_LIST'` 로 실패합니다.
>
> 따라서 소스 PostgreSQL 은:
> - **기동 중**이어야 하고,
> - **호스트명이 공개 DNS 로 해석**되어야 하며,
> - **퍼블릭 인터넷에서 해당 포트로 접근 가능**해야 합니다.

로컬에서 확인:

```bash
# DNS 해석 확인
nslookup <HOSTNAME>

# 포트 도달 확인
nc -zv <HOSTNAME> <PORT>

# 실제 접속 확인
psql "host=<HOSTNAME> port=<PORT> dbname=<DATABASE> user=<ADMIN_USER> sslmode=require"
```

### 사설망 / 온프레미스 소스인 경우

이 실습 범위 밖입니다. 다음 중 하나가 필요합니다.

| 방법 | 조건 |
|------|------|
| Data Connectivity Proxy (DCP) | `MODE = DATA_CONNECTIVITY_PROXY_EGRESS` 네트워크 규칙 + 터널 에이전트 |
| Outbound PrivateLink | `TYPE = PRIVATE_HOST_PORT`, **Business Critical Edition 이상** |
| Openflow BYOC 배포 | Runtime 을 자체 VPC 에 배치 (EAI 불필요) |

### 실습 환경이 없는 경우 — 권장 구성

| 옵션 | 설정 요점 | 비고 |
|------|-----------|------|
| AWS RDS PostgreSQL | Publicly accessible = Yes, Security Group 에 인바운드 5432 허용 | 파라미터 그룹으로 설정 변경, 재부팅 필요 |
| GCP Cloud SQL for PostgreSQL | 공개 IP 활성, 승인된 네트워크 추가 | `cloudsql.logical_decoding = on` |
| 퍼블릭 IP EC2/VM + PostgreSQL | `postgresql.conf`, `pg_hba.conf` 직접 수정 | 가장 자유도가 높음 |

---

## 2. `wal_level = logical` 설정

PostgreSQL 논리 복제의 필수 조건입니다.

### 2-1. 현재 값 확인

```sql
SHOW wal_level;
```

`logical` 이면 3장으로 넘어갑니다. `replica` 또는 `minimal` 이면 변경이 필요합니다.

### 2-2. 자체 관리 PostgreSQL

```sql
ALTER SYSTEM SET wal_level = 'logical';
```

**변경 후 PostgreSQL 재시작이 필요합니다.** (reload 로는 적용되지 않습니다.)

```bash
sudo systemctl restart postgresql
```

### 2-3. 관리형 서비스

| 서비스 | 설정 | 적용 |
|--------|------|------|
| AWS RDS / Aurora PostgreSQL | 파라미터 그룹에서 `rds.logical_replication = 1` | **재부팅 필요** |
| GCP Cloud SQL | 플래그 `cloudsql.logical_decoding = on` | **재시작 필요** |
| Azure Database for PostgreSQL | 서버 파라미터에서 `wal_level = logical` | **재시작 필요** |

### 2-4. 재시작 후 재확인

```sql
SHOW wal_level;   -- logical 이어야 함
```

---

## 3. 실습용 테이블 생성 (PK 필수)

CDC 검증을 위해 UPDATE / DELETE 가 복제되어야 하므로 **반드시 PRIMARY KEY 를 둡니다.**

```sql
-- 실습 대상 DB 에 접속한 상태에서 실행
CREATE TABLE IF NOT EXISTS public.customers (
    customer_id   INTEGER      PRIMARY KEY,
    customer_name VARCHAR(100) NOT NULL,
    email         VARCHAR(200),
    grade         VARCHAR(20)  DEFAULT 'BRONZE',
    updated_at    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.orders (
    order_id     INTEGER        PRIMARY KEY,
    customer_id  INTEGER        NOT NULL,
    product_name VARCHAR(100),
    amount       NUMERIC(12,2),
    order_status VARCHAR(20)    DEFAULT 'NEW',
    created_at   TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
);

-- 스냅샷 단계에서 적재될 초기 데이터
INSERT INTO public.customers (customer_id, customer_name, email, grade) VALUES
    (1, '김철수', 'chulsoo@example.com', 'GOLD'),
    (2, '이영희', 'younghee@example.com', 'SILVER'),
    (3, '박민수', 'minsoo@example.com',   'BRONZE')
ON CONFLICT (customer_id) DO NOTHING;

INSERT INTO public.orders (order_id, customer_id, product_name, amount, order_status) VALUES
    (1001, 1, '노트북',     1500000.00, 'SHIPPED'),
    (1002, 2, '키보드',       89000.00, 'NEW'),
    (1003, 1, '모니터',      420000.00, 'NEW')
ON CONFLICT (order_id) DO NOTHING;

-- 확인
SELECT COUNT(*) AS customers_cnt FROM public.customers;   -- 3
SELECT COUNT(*) AS orders_cnt    FROM public.orders;      -- 3
```

### Identity Key 확인

```sql
-- PK 가 있는 테이블 목록
SELECT tc.table_schema, tc.table_name
FROM information_schema.table_constraints tc
WHERE tc.constraint_type = 'PRIMARY KEY'
  AND tc.table_schema = 'public';

-- replica identity 설정 (d=default, i=index, f=full, n=nothing)
SELECT c.relname, c.relreplident
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r';
```

`relreplident = 'd'` (default) + PK 존재 → UPDATE / DELETE 복제 가능. 정상입니다.

> **PK 가 없는 테이블은** INSERT 만 복제되고 UPDATE / DELETE 는 유실됩니다.
> 이 경우 UNIQUE 인덱스를 만들고
> `ALTER TABLE <t> REPLICA IDENTITY USING INDEX <idx>` 를 설정하거나,
> 커넥터 설정에서 논리 키(logical key)를 지정해야 합니다.

---

## 4. 복제 사용자 생성

Openflow 커넥터가 사용할 전용 사용자입니다. 관리자 계정을 그대로 쓰지 마세요(최소 권한 원칙).

```sql
-- 4-1. 사용자 생성 (비밀번호는 강한 값으로 교체)
CREATE USER openflow_repl WITH
    LOGIN
    REPLICATION
    PASSWORD 'CHANGE_ME_STRONG_PASSWORD';

-- 4-2. 스키마 및 테이블 읽기 권한
GRANT CONNECT ON DATABASE <DATABASE> TO openflow_repl;
GRANT USAGE   ON SCHEMA public       TO openflow_repl;
GRANT SELECT  ON ALL TABLES IN SCHEMA public TO openflow_repl;

-- 4-3. 앞으로 만들 테이블에도 자동 적용
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO openflow_repl;
```

### 검증

```sql
SELECT rolname, rolreplication, rolcanlogin
FROM pg_roles
WHERE rolname = 'openflow_repl';
```

`rolreplication` 과 `rolcanlogin` 이 **둘 다 `t`** 여야 합니다.

기존 사용자에 권한만 추가하는 경우:

```sql
ALTER ROLE openflow_repl WITH REPLICATION LOGIN;
```

### AWS RDS 주의사항

RDS 에서는 `REPLICATION` 속성을 직접 부여할 수 없습니다. 대신 다음을 사용합니다.

```sql
GRANT rds_replication TO openflow_repl;
```

---

## 5. PUBLICATION 생성

논리 복제로 발행할 테이블 집합을 정의합니다.

### 5-1. 기존 PUBLICATION 확인

```sql
SELECT pubname, puballtables FROM pg_publication;
```

### 5-2. 생성

이 실습에서는 대상 테이블을 명시적으로 지정합니다(범위가 명확해 권장).

```sql
CREATE PUBLICATION openflow_pub
    FOR TABLE public.customers, public.orders
    WITH (publish_via_partition_root = true);
```

전체 테이블을 대상으로 하려면:

```sql
CREATE PUBLICATION openflow_pub
    FOR ALL TABLES
    WITH (publish_via_partition_root = true);
```

> `publish_via_partition_root = true` 는 **파티션 테이블에 필수**입니다.
> 파티션이 없어도 설정해 두면 이후 파티셔닝 시 문제가 없습니다.

### 5-3. 검증

```sql
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
FROM pg_publication
WHERE pubname = 'openflow_pub';

-- 발행 대상 테이블 확인
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'openflow_pub';
```

`pubinsert`, `pubupdate`, `pubdelete` 가 모두 `t` 여야 CDC 3종이 모두 잡힙니다.

---

## 6. 복제 슬롯 (선택)

커넥터가 자동 생성하므로 **직접 만들 필요는 없습니다.** 참고용 확인 쿼리입니다.

```sql
-- 슬롯 상한 확인 (기본 10)
SHOW max_replication_slots;

-- 현재 슬롯 목록 (커넥터 기동 후 여기에 나타납니다)
SELECT slot_name, plugin, slot_type, active, restart_lsn
FROM pg_replication_slots;
```

> ⚠️ **비활성 복제 슬롯은 WAL 을 계속 축적해 소스 디스크를 채웁니다.**
> 실습 종료 후 커넥터를 삭제했다면 남은 슬롯을 반드시 정리하세요
> (11번 문서 참고).

---

## 7. 네트워크 접근 허용

Openflow Runtime 이 소스에 접속할 수 있어야 합니다.

### 자체 관리 PostgreSQL

`postgresql.conf`:
```ini
listen_addresses = '*'
```

`pg_hba.conf` — 복제 사용자의 접속 허용:
```
# TYPE  DATABASE   USER            ADDRESS      METHOD
host    all        openflow_repl   0.0.0.0/0    scram-sha-256
```

> `0.0.0.0/0` 은 실습 편의를 위한 설정입니다. 운영 환경에서는 Snowflake
> egress IP 범위로 제한하십시오.

변경 후 reload:
```bash
sudo systemctl reload postgresql
```

### 관리형 서비스

- **AWS RDS**: Security Group 인바운드 규칙에 TCP 5432 추가
- **GCP Cloud SQL**: 연결 → 승인된 네트워크(Authorized networks) 추가
- **Azure**: 방화벽 규칙 추가

---

## 8. 최종 확인 체크리스트

다음 항목이 **모두** 충족되어야 05번 문서로 진행합니다.

- [ ] `SHOW wal_level;` → `logical`
- [ ] 실습 테이블 `public.customers`, `public.orders` 존재 + **각각 PK 보유**
- [ ] 초기 데이터 각 3건 삽입 완료
- [ ] `pg_roles` 에서 `openflow_repl` 의 `rolreplication` = `t`, `rolcanlogin` = `t`
- [ ] `openflow_repl` 이 대상 테이블에 `SELECT` 권한 보유
- [ ] `pg_publication` 에 `openflow_pub` 존재, `pubinsert/pubupdate/pubdelete` = `t`
- [ ] 로컬에서 `nslookup <HOSTNAME>` 성공 (**05번의 DNS 검증 통과 조건**)
- [ ] 로컬에서 `nc -zv <HOSTNAME> <PORT>` 성공
- [ ] `psql` 로 `openflow_repl` 계정 접속 성공
- [ ] 0장의 5개 산출물을 기록해 두었다

> ⚠️ Openflow 의 `VALIDATE CONFIGURATION` 은 접속과 인증은 검증하지만,
> **`wal_level` 이나 PUBLICATION 문제는 데이터가 흐르기 시작할 때까지
> 잡아내지 못합니다.** 그래서 지금 확인하는 것이 중요합니다.

---

## 🧹 리소스 정리 (이 문서에서 만든 것)

> ⚠️ 정본은 `98_리소스정리.sql` **PART D-1** 입니다. 전체 정리는 그 문서를 따르세요.
> 아래는 **이 문서까지만 진행하고 중단한 경우** 소스 DB 를 되돌리기 위한 것입니다.
> Snowflake 가 아니라 **소스 PostgreSQL 에서** 실행합니다.

```sql
-- 이 문서에서 만든 것: PUBLICATION, 실습 테이블 2개, 복제 사용자, wal_level 변경
DROP PUBLICATION IF EXISTS openflow_pub;

DROP TABLE IF EXISTS public.orders;
DROP TABLE IF EXISTS public.customers;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM openflow_repl;
REVOKE ALL ON SCHEMA public              FROM openflow_repl;
DROP USER IF EXISTS openflow_repl;

-- 설정 원복 — ⚠️ 재시작 필요. 1장에서 기록한 실습 전 값으로 되돌리세요.
ALTER SYSTEM SET wal_level = 'replica';
--   RDS      : rds.logical_replication = 0 후 재부팅
--   Cloud SQL: cloudsql.logical_decoding = off 후 재시작
--   pg_hba.conf 의 openflow_repl 항목과 listen_addresses 변경도 원복

-- 확인 — 모두 비어 있어야 합니다
SELECT * FROM pg_publication;
SELECT * FROM pg_replication_slots;
SELECT usename FROM pg_user WHERE usename = 'openflow_repl';
```

> 🔴 커넥터를 한 번이라도 기동했다면 **복제 슬롯**이 자동 생성되어 있습니다.
> 슬롯을 남겨 두면 WAL 이 무한 축적되어 소스 디스크를 채웁니다.
> `98_` PART D-1 (a) 를 반드시 수행하세요.

---

**다음 문서**: `05_네트워크_규칙_및_EAI_구성.sql` (Snowflake 로 복귀)
