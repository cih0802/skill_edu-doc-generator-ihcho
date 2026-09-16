/*
title: 적재 결과 검증
step: 09
type: sql
summary: 스냅샷 단계에서 대상 스키마/테이블 자동 생성과 초기 행 수를 확인하고, 소스의 INSERT/UPDATE/DELETE 가 CDC 로 반영되는지 단계별로 검증한다.
requires: 08_커넥터_커밋_및_기동.sql
next: 10_부록_MySQL_차이점.md
*/

-- =============================================================
-- 09. 적재 결과 검증 — 이 실습의 실제 목표
-- =============================================================
-- 실행 위치 : Snowflake + 소스 PostgreSQL (교차 실행)
-- 필요 권한 : OPENFLOW_EDU_DE_RL (CDC_LAB_PG_DB 조회 권한)
--
-- 검증 상태 :
--   ⚠️ 커넥터가 기동되지 않아 실제 실행 검증을 하지 못했습니다.
--      아래 SELECT / SHOW 문은 모두 표준 Snowflake 구문입니다.
-- =============================================================


-- =============================================================
-- PHASE 1. 스냅샷 단계 검증
-- =============================================================
-- Ingestion Type = full 이므로 커넥터는 먼저 초기 전량(스냅샷)을 적재합니다.
USE ROLE OPENFLOW_EDU_DE_RL;
USE WAREHOUSE OPENFLOW_EDU_WH;

-- 1-1. 대상 스키마가 자동 생성되었는지 확인
-- 커넥터가 소스 스키마 이름(public)으로 Snowflake 스키마를 만듭니다.
SHOW SCHEMAS IN DATABASE CDC_LAB_PG_DB;
-- 기대: PUBLIC 스키마 존재
--       (Object Identifier Resolution = CASE_INSENSITIVE 이므로 대문자)
--
-- ⏳ 아직 없으면 커넥터가 스냅샷을 시작하지 않은 것입니다.
--    1~2분 기다린 뒤 다시 조회하세요.

-- 1-2. 대상 테이블이 자동 생성되었는지 확인
SHOW TABLES IN SCHEMA CDC_LAB_PG_DB.PUBLIC;
-- 기대: CUSTOMERS, ORDERS

-- 1-3. 테이블 구조 확인 (소스 컬럼이 매핑되었는지)
DESCRIBE TABLE CDC_LAB_PG_DB.PUBLIC.CUSTOMERS;
DESCRIBE TABLE CDC_LAB_PG_DB.PUBLIC.ORDERS;
-- 기대 컬럼 (CUSTOMERS):
--   CUSTOMER_ID, CUSTOMER_NAME, EMAIL, GRADE, UPDATED_AT
-- 커넥터가 추가하는 메타데이터 컬럼이 함께 보일 수 있습니다.

-- 1-4. 초기 행 수 확인 — 소스와 일치해야 합니다
SELECT 'CUSTOMERS' AS table_name, COUNT(*) AS row_count
FROM CDC_LAB_PG_DB.PUBLIC.CUSTOMERS
UNION ALL
SELECT 'ORDERS' AS table_name, COUNT(*) AS row_count
FROM CDC_LAB_PG_DB.PUBLIC.ORDERS;
-- 기대: 각 3건 (04번 문서 3장에서 삽입한 초기 데이터)

-- 1-5. 실제 데이터 확인
SELECT * FROM CDC_LAB_PG_DB.PUBLIC.CUSTOMERS ORDER BY CUSTOMER_ID;
SELECT * FROM CDC_LAB_PG_DB.PUBLIC.ORDERS    ORDER BY ORDER_ID;

-- 1-6. 복제 상태를 Event Table 로 확인 (선택)
USE ROLE OPENFLOW_EDU_ADMIN_RL;
SELECT TIMESTAMP
     , RECORD:severity_text::string   AS severity
     , VALUE:formattedMessage::string AS message
FROM OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.EVENTS
WHERE TIMESTAMP > DATEADD('hour', -1, CURRENT_TIMESTAMP())
ORDER BY TIMESTAMP DESC
LIMIT 30;
-- 스냅샷 진행/완료 관련 메시지를 확인할 수 있습니다.

-- ✅ PHASE 1 통과 조건: 두 테이블이 자동 생성되고 각 3건이 적재되었다.
--    통과하지 못하면 PHASE 2 로 가지 말고 11번 문서로 진단하세요.


-- =============================================================
-- PHASE 2. CDC — INSERT 반영 검증
-- =============================================================
-- ⚠️ 아래 블록은 **소스 PostgreSQL** 에서 실행합니다 (psql 등).
-- -------------------------------------------------------------
-- INSERT INTO public.customers (customer_id, customer_name, email, grade)
-- VALUES (4, '최지우', 'jiwoo@example.com', 'GOLD');
--
-- INSERT INTO public.orders (order_id, customer_id, product_name, amount, order_status)
-- VALUES (1004, 4, '마우스', 45000.00, 'NEW');
--
-- SELECT COUNT(*) FROM public.customers;   -- 4
-- SELECT COUNT(*) FROM public.orders;      -- 4
-- -------------------------------------------------------------

-- ⏳ Merge Task Schedule CRON 기본값이 매초이므로 보통 수 초~수십 초 내
--    반영됩니다. Warehouse 가 suspend 되어 있으면 재개 시간이 더 걸립니다.

-- 2-1. Snowflake 에서 반영 확인
USE ROLE OPENFLOW_EDU_DE_RL;
USE WAREHOUSE OPENFLOW_EDU_WH;

SELECT * FROM CDC_LAB_PG_DB.PUBLIC.CUSTOMERS ORDER BY CUSTOMER_ID;
-- 기대: CUSTOMER_ID = 4, '최지우' 행이 나타남

SELECT COUNT(*) AS customers_cnt FROM CDC_LAB_PG_DB.PUBLIC.CUSTOMERS;  -- 4
SELECT COUNT(*) AS orders_cnt    FROM CDC_LAB_PG_DB.PUBLIC.ORDERS;     -- 4

-- ❌ 반영되지 않으면
--    (a) 커넥터 상태 확인
--        DESCRIBE OPENFLOW CONNECTOR
--          OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR;   -- RUNNING?
--    (b) 대상 테이블이 PUBLICATION 에 포함되어 있는지 (소스에서)
--        SELECT * FROM pg_publication_tables WHERE pubname = 'openflow_pub';
--    (c) 복제 슬롯이 active 인지 (소스에서)
--        SELECT slot_name, active, restart_lsn FROM pg_replication_slots;
--    (d) Warehouse 가 재개 가능한지 — execute-as Role 에 OPERATE 가 있는가


-- =============================================================
-- PHASE 3. CDC — UPDATE 반영 검증
-- =============================================================
-- UPDATE 복제는 소스 테이블의 identity key(PK)에 의존합니다.
--
-- ⚠️ 아래 블록은 **소스 PostgreSQL** 에서 실행합니다.
-- -------------------------------------------------------------
-- UPDATE public.customers
-- SET grade = 'PLATINUM',
--     email = 'chulsoo.new@example.com',
--     updated_at = CURRENT_TIMESTAMP
-- WHERE customer_id = 1;
--
-- UPDATE public.orders
-- SET order_status = 'DELIVERED'
-- WHERE order_id = 1002;
--
-- SELECT customer_id, grade, email FROM public.customers WHERE customer_id = 1;
-- -------------------------------------------------------------

-- 3-1. Snowflake 에서 반영 확인
SELECT CUSTOMER_ID, CUSTOMER_NAME, EMAIL, GRADE
FROM CDC_LAB_PG_DB.PUBLIC.CUSTOMERS
WHERE CUSTOMER_ID = 1;
-- 기대: GRADE = 'PLATINUM', EMAIL = 'chulsoo.new@example.com'

SELECT ORDER_ID, ORDER_STATUS
FROM CDC_LAB_PG_DB.PUBLIC.ORDERS
WHERE ORDER_ID = 1002;
-- 기대: ORDER_STATUS = 'DELIVERED'

-- ❌ UPDATE 가 반영되지 않으면 (INSERT 는 되는데 UPDATE 만 안 되는 경우)
--    → identity key 문제입니다. 소스에서 확인:
--        SELECT c.relname, c.relreplident
--        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--        WHERE n.nspname = 'public' AND c.relkind = 'r';
--      relreplident = 'n' (nothing) 이면 UPDATE/DELETE 가 유실됩니다.
--      PK 를 추가하거나 REPLICA IDENTITY USING INDEX 를 설정해야 합니다.
--    → 또한 PUBLICATION 의 pubupdate 가 t 인지 확인:
--        SELECT pubname, pubupdate, pubdelete FROM pg_publication;


-- =============================================================
-- PHASE 4. CDC — DELETE 반영 검증
-- =============================================================
-- ⚠️ 아래 블록은 **소스 PostgreSQL** 에서 실행합니다.
-- -------------------------------------------------------------
-- DELETE FROM public.orders    WHERE order_id = 1003;
-- DELETE FROM public.customers WHERE customer_id = 3;
--
-- SELECT COUNT(*) FROM public.customers;   -- 3
-- SELECT COUNT(*) FROM public.orders;      -- 3
-- -------------------------------------------------------------

-- 4-1. Snowflake 에서 반영 확인
SELECT COUNT(*) AS customers_cnt FROM CDC_LAB_PG_DB.PUBLIC.CUSTOMERS;  -- 3
SELECT COUNT(*) AS orders_cnt    FROM CDC_LAB_PG_DB.PUBLIC.ORDERS;     -- 3

SELECT * FROM CDC_LAB_PG_DB.PUBLIC.CUSTOMERS ORDER BY CUSTOMER_ID;
-- 기대: CUSTOMER_ID = 3 ('박민수') 행이 사라짐

SELECT * FROM CDC_LAB_PG_DB.PUBLIC.ORDERS ORDER BY ORDER_ID;
-- 기대: ORDER_ID = 1003 행이 사라짐

-- ⚠️ 커넥터 설정에 따라 DELETE 가 물리 삭제 대신 소프트 삭제 컬럼으로
--    표현될 수 있습니다. DESCRIBE TABLE 결과에 삭제 표시 메타데이터
--    컬럼이 있는지 확인하세요.


-- =============================================================
-- PHASE 5. 최종 정합성 대조
-- =============================================================
-- 소스와 대상의 최종 상태를 나란히 비교합니다.

-- 5-1. Snowflake 측 요약
SELECT 'CUSTOMERS'                    AS tbl
     , COUNT(*)                       AS cnt
     , MIN(CUSTOMER_ID)               AS min_id
     , MAX(CUSTOMER_ID)               AS max_id
     , COUNT(DISTINCT GRADE)          AS distinct_grades
FROM CDC_LAB_PG_DB.PUBLIC.CUSTOMERS
UNION ALL
SELECT 'ORDERS'
     , COUNT(*)
     , MIN(ORDER_ID)
     , MAX(ORDER_ID)
     , COUNT(DISTINCT ORDER_STATUS)
FROM CDC_LAB_PG_DB.PUBLIC.ORDERS;

-- 5-2. 소스에서 동일 쿼리 실행 후 비교 (소스 PostgreSQL)
-- -------------------------------------------------------------
-- SELECT 'customers' AS tbl, COUNT(*) AS cnt,
--        MIN(customer_id), MAX(customer_id), COUNT(DISTINCT grade)
-- FROM public.customers
-- UNION ALL
-- SELECT 'orders', COUNT(*),
--        MIN(order_id), MAX(order_id), COUNT(DISTINCT order_status)
-- FROM public.orders;
-- -------------------------------------------------------------

-- 5-3. 최종 기대 상태
--   CUSTOMERS: 3건 — id 1(PLATINUM), 2(SILVER), 4(GOLD)   ← 3 삭제됨
--   ORDERS   : 3건 — id 1001(SHIPPED), 1002(DELIVERED), 1004(NEW)  ← 1003 삭제됨


-- =============================================================
-- PHASE 6. 커넥터 상태 및 처리량 확인
-- =============================================================
USE ROLE OPENFLOW_EDU_ADMIN_RL;

-- 6-1. 커넥터 최종 상태
DESCRIBE OPENFLOW CONNECTOR OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR;
-- 확인: status = RUNNING

-- 6-2. 오류 없이 동작 중인지 확인
SELECT RECORD:severity_text::string AS severity
     , COUNT(*)                     AS cnt
FROM OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.EVENTS
WHERE TIMESTAMP > DATEADD('hour', -1, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 2 DESC;
-- 기대: ERROR 가 0 이거나, 있다면 스냅샷 초기의 일시적 경고 수준


-- =============================================================
-- ✅ 실습 완료 체크리스트
-- =============================================================
-- [ ] PHASE 1: 대상 스키마/테이블이 자동 생성되고 초기 3건씩 적재되었다
-- [ ] PHASE 2: 소스 INSERT 가 대상에 반영되었다
-- [ ] PHASE 3: 소스 UPDATE 가 대상에 반영되었다
-- [ ] PHASE 4: 소스 DELETE 가 대상에 반영되었다
-- [ ] PHASE 5: 소스와 대상의 행 수·값이 일치한다
-- [ ] PHASE 6: 커넥터가 RUNNING 이고 ERROR 로그가 없다
--
-- 🎉 여기까지 통과하면 Openflow Gen 2 CDC 파이프라인 구축을 완료한 것입니다.
--
-- ⚠️ Runtime 은 계속 크레딧을 소비합니다.
--    실습을 마쳤다면 반드시 98_리소스정리.sql 을 수행하세요.
--    급하면 98_ PART A (Runtime SUSPEND) 만으로도 크레딧이 멈춥니다.
--
-- 다음 문서: 10_부록_MySQL_차이점.md (참고)
--            11_트러블슈팅.md (참고)
--            98_리소스정리.sql (필수 — 실습 종료 시)
