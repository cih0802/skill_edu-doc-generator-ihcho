/*
title: 커넥터 커밋, 검증, 기동
step: 08
type: sql
summary: config.json 을 COMMIT 하고 VALIDATE CONFIGURATION 으로 사전 검증한 뒤 커넥터를 START 하여 RUNNING 상태까지 대기한다. START_FAILED 진단 쿼리 포함.
requires: 07_커넥터_설정_config_json.md
next: 09_적재결과_검증.sql
*/

-- =============================================================
-- 08. 커넥터 커밋 / 검증 / 기동
-- =============================================================
-- 실행 위치 : Snowflake (Snowsight 워크시트)
-- 필요 권한 : OPENFLOW_EDU_DE_RL (Runtime USAGE)
--
-- 검증 상태 :
--   ⚠️ 커넥터가 존재하지 않아 실제 실행 검증을 하지 못했습니다.
--      문법은 공식 문서(ALTER OPENFLOW CONNECTOR /
--      EXECUTE OPENFLOW CONNECTOR)로 대조 확인했습니다.
-- =============================================================


-- =============================================================
-- STEP 1. 커밋 (config.json 적용)
-- =============================================================
USE ROLE OPENFLOW_EDU_DE_RL;
USE DATABASE OPENFLOW_EDU_DB;
USE SCHEMA OPENFLOW_EDU_SCH;

-- 1-1. 현재 상태 확인 — STOPPED 여야 합니다.
SHOW OPENFLOW CONNECTORS IN SCHEMA OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH;

-- 1-2. 커밋
ALTER OPENFLOW CONNECTOR OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR COMMIT;

-- 1-3. STOPPED 로 돌아올 때까지 대기
SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'STOPPED',
  'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');

-- ❌ UPDATE_FAILED 가 되면
--    가장 흔한 원인: config.json 이 유효한 JSON 이 아님
--      → 07번 문서 5-3(1) 의 백슬래시 이중화를 건너뛴 경우
--      → 오류 메시지: Invalid connector configuration file at location: 'config.json'
--    복구 절차:
--      (a) 원인을 먼저 고칩니다 (config.json 재생성)
--      (b) ALTER OPENFLOW CONNECTOR <fqn> ADD LIVE VERSION FROM LAST;
--      (c) config.json 을 다시 업로드
--      (d) ALTER OPENFLOW CONNECTOR <fqn> COMMIT;
--    ⚠️ 같은 config 로 COMMIT 만 반복하지 마세요. 해결되지 않습니다.
--
-- ⚠️ 참고: 한 번도 커밋되지 않은 커넥터에는 ABORT 를 쓸 수 없습니다
--    (기본 버전이 없어 "Cannot abort live version" 오류).
--    이 경우 live config 를 덮어쓰고 다시 커밋하는 것이 유일한 방법입니다.
--
-- ⚠️ 커밋 후에는 GET '<...>/versions/live/config.json' 이 실패합니다
--    ("version live is not found"). 커밋이 live 버전을 소비하기 때문입니다.
--    커밋된 설정을 확인하려면 아래를 사용하세요.
--      SHOW VERSIONS IN OPENFLOW CONNECTOR
--        OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR;
--      GET '<...>/versions/version$N/config.json' 'file:///tmp/';


-- =============================================================
-- STEP 2. 설정 검증 (기동 전 필수)
-- =============================================================
-- 접속 가능성과 자격증명을 미리 확인합니다. 기동 후 실패보다
-- 여기서 잡는 것이 훨씬 빠릅니다.
EXECUTE OPENFLOW CONNECTOR
  OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR
  VALIDATE CONFIGURATION;

-- ⚠️ VALIDATE CONFIGURATION 의 한계
--    검증됨   : 네트워크 도달성, 인증(사용자/비밀번호), JDBC URL 형식
--    검증 안 됨: wal_level 설정, PUBLICATION 존재 여부, REPLICA IDENTITY
--                → 이들은 데이터가 흐르기 시작할 때 비로소 드러납니다.
--                  04번 문서 8장의 체크리스트로 미리 확인했어야 합니다.
--
-- ❌ 실패 시 오류별 대응 (11번 문서에 전체 표 있음)
--    FATAL: database "X" does not exist        → JDBC URL 의 DB 이름 수정
--    FATAL: password authentication failed     → Secret 값 또는 사용자명 확인
--    PSQLException: Connection refused         → Network Rule 의 host:port 확인
--    FATAL: no pg_hba.conf entry               → 소스 pg_hba.conf / SG 확인
--    Cannot create PoolableConnectionFactory   → 드라이버 JAR 업로드 확인
--
-- 검증을 통과하지 못하면 START 하지 마세요.


-- =============================================================
-- STEP 3. 기동
-- =============================================================
ALTER OPENFLOW CONNECTOR OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR START;

-- 3-1. RUNNING 까지 대기
SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'RUNNING',
  'OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR');

-- 3-2. 상태 확인
DESCRIBE OPENFLOW CONNECTOR OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.PG_CDC_CONNECTOR;
-- 확인: status = RUNNING


-- =============================================================
-- STEP 4. START_FAILED 진단
-- =============================================================
-- STEP 3 에서 START_FAILED 가 되면 Event Table 에서 실제 오류를 찾습니다.
USE ROLE OPENFLOW_EDU_ADMIN_RL;

SELECT TIMESTAMP
     , RESOURCE_ATTRIBUTES:"snow.openflow.connector.name"::string AS connector
     , RECORD:severity_text::string                              AS severity
     , VALUE:formattedMessage::string                             AS message
FROM OPENFLOW_EDU_DB.OPENFLOW_EDU_SCH.EVENTS
WHERE TIMESTAMP > DATEADD('hour', -1, CURRENT_TIMESTAMP())
  AND RECORD:severity_text::string IN ('ERROR', 'WARN')
ORDER BY TIMESTAMP DESC
LIMIT 50;

-- Event Table 을 Deployment 에 연결하지 않았다면 계정 Event Table 을 조회:
-- SELECT TIMESTAMP, RECORD:severity_text::string AS severity,
--        VALUE:formattedMessage::string AS message
-- FROM SNOWFLAKE.TELEMETRY.EVENTS
-- WHERE TIMESTAMP > DATEADD('hour', -1, CURRENT_TIMESTAMP())
--   AND RECORD:severity_text::string IN ('ERROR', 'WARN')
-- ORDER BY TIMESTAMP DESC
-- LIMIT 50;

-- START_FAILED 의 PostgreSQL 특이 원인 (체크 순서):
--   1. JDBC 드라이버 에셋 누락 — 커밋 전에 업로드되어야 합니다
--   2. Secret 참조 오류 — fullyQualifiedSecretName 이 db.schema.secret 형식인가
--   3. Network Rule 에 소스 host:port 가 없음
--   4. 소스에 PUBLICATION 이 없거나 사용자에 REPLICATION 권한 없음
--   5. SSL 필요한데 URL 에 ?sslmode=require 누락

-- 4-1. 수정 후 재시도 절차
--   ALTER OPENFLOW CONNECTOR <fqn> ADD LIVE VERSION FROM LAST;
--   → config.json 수정 및 업로드 (07번 문서)
--   → ALTER OPENFLOW CONNECTOR <fqn> COMMIT;
--   → EXECUTE OPENFLOW CONNECTOR <fqn> VALIDATE CONFIGURATION;
--   → ALTER OPENFLOW CONNECTOR <fqn> START;
--
-- ⚠️ 설정 편집은 STOPPED 상태에서만 가능합니다. RUNNING 이면 먼저 STOP 하고
--    STOPPING 이 끝날 때까지 대기해야 합니다. 대기를 건너뛰면
--    ADD LIVE VERSION FROM LAST 가 실패합니다.
--      ALTER OPENFLOW CONNECTOR <fqn> STOP;
--      SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'STOPPED', '<fqn>');


-- =============================================================
-- ✅ 완료 체크리스트
-- =============================================================
-- [ ] COMMIT 후 status = STOPPED 로 돌아왔다 (UPDATE_FAILED 아님)
-- [ ] VALIDATE CONFIGURATION 을 통과했다
-- [ ] START 후 status = RUNNING 이다
--
-- 다음 문서: 09_적재결과_검증.sql
