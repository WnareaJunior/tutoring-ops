-- =============================================================================
-- 07_pkg_outbox.sql -- PKG_OUTBOX
--
-- The API's background publisher drains EVENT_OUTBOX through this package. The
-- contract it relies on:
--
--   1. claim_batch locks the rows it hands back, so a second publisher instance
--      blocks rather than sending the same event twice.
--   2. The publisher keeps the transaction open across the Service Bus send and
--      the mark_published call, then commits once.
--   3. If the send fails, the whole batch rolls back and the rows are picked up
--      again on the next poll. Duplicate delivery is still possible -- the send
--      can succeed and the commit still fail -- so consumers are written to be
--      idempotent. At-least-once, not exactly-once, and the design says so out
--      loud rather than pretending otherwise.
-- =============================================================================

CREATE OR REPLACE PACKAGE PKG_OUTBOX AS

  -- Claims up to p_limit unpublished events, oldest first, and returns them.
  -- The rows stay locked until the caller commits or rolls back.
  PROCEDURE claim_batch (
    p_limit  IN  NUMBER DEFAULT 50,
    p_cursor OUT SYS_REFCURSOR
  );

  PROCEDURE mark_published (
    p_event_id IN NUMBER
  );

  -- Records why an event could not be sent. Autonomous, so the note survives
  -- the rollback of the batch that failed.
  PROCEDURE mark_failed (
    p_event_id IN NUMBER,
    p_error    IN VARCHAR2
  );

  FUNCTION pending_count RETURN NUMBER;

  -- Housekeeping: published events older than p_days are history, not state.
  PROCEDURE purge_published (
    p_days          IN  NUMBER DEFAULT 30,
    p_deleted_count OUT NUMBER
  );

END PKG_OUTBOX;
/

CREATE OR REPLACE PACKAGE BODY PKG_OUTBOX AS

  PROCEDURE claim_batch (
    p_limit  IN  NUMBER DEFAULT 50,
    p_cursor OUT SYS_REFCURSOR
  )
  IS
    l_ids SYS.ODCINUMBERLIST;
  BEGIN
    -- The UPDATE is the claim: it takes the row locks and bumps the attempt
    -- counter in one statement, which avoids the restrictions on combining
    -- FOR UPDATE with a row-limiting clause.
    UPDATE EVENT_OUTBOX
       SET ATTEMPT_COUNT = ATTEMPT_COUNT + 1
     WHERE PUBLISHED_FLAG = 'N'
       AND EVENT_ID IN (
             SELECT EVENT_ID
               FROM (SELECT EVENT_ID
                       FROM EVENT_OUTBOX
                      WHERE PUBLISHED_FLAG = 'N'
                      ORDER BY EVENT_ID)
              WHERE ROWNUM <= NVL(p_limit, 50))
    RETURNING EVENT_ID BULK COLLECT INTO l_ids;

    OPEN p_cursor FOR
      SELECT EVENT_ID,
             EVENT_TYPE,
             AGGREGATE_TYPE,
             AGGREGATE_ID,
             PAYLOAD,
             CREATED_AT,
             ATTEMPT_COUNT
        FROM EVENT_OUTBOX
       WHERE EVENT_ID IN (SELECT COLUMN_VALUE FROM TABLE(l_ids))
       ORDER BY EVENT_ID;
  END claim_batch;


  PROCEDURE mark_published (
    p_event_id IN NUMBER
  )
  IS
  BEGIN
    UPDATE EVENT_OUTBOX
       SET PUBLISHED_FLAG = 'Y',
           PUBLISHED_AT   = SYSTIMESTAMP,
           LAST_ERROR     = NULL
     WHERE EVENT_ID = p_event_id;
  END mark_published;


  PROCEDURE mark_failed (
    p_event_id IN NUMBER,
    p_error    IN VARCHAR2
  )
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE EVENT_OUTBOX
       SET LAST_ERROR = SUBSTR(p_error, 1, 2000)
     WHERE EVENT_ID = p_event_id;
    COMMIT;
  END mark_failed;


  FUNCTION pending_count RETURN NUMBER
  IS
    l_count NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO l_count
      FROM EVENT_OUTBOX
     WHERE PUBLISHED_FLAG = 'N';

    RETURN l_count;
  END pending_count;


  PROCEDURE purge_published (
    p_days          IN  NUMBER DEFAULT 30,
    p_deleted_count OUT NUMBER
  )
  IS
  BEGIN
    DELETE FROM EVENT_OUTBOX
     WHERE PUBLISHED_FLAG = 'Y'
       AND PUBLISHED_AT < SYSTIMESTAMP - NUMTODSINTERVAL(NVL(p_days, 30), 'DAY');

    p_deleted_count := SQL%ROWCOUNT;
  END purge_published;

END PKG_OUTBOX;
/

SHOW ERRORS PACKAGE PKG_OUTBOX
SHOW ERRORS PACKAGE BODY PKG_OUTBOX
