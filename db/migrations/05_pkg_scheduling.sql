-- =============================================================================
-- 05_pkg_scheduling.sql -- PKG_SCHEDULING
--
-- The calendar rules. Calls PKG_BILLING for anything involving hours or money.
--
-- Transaction policy: nothing in this package commits. The caller owns the
-- transaction, which is what lets a SESSIONS row and its EVENT_OUTBOX row be
-- written atomically -- the event cannot survive a rolled-back booking, and a
-- committed booking cannot lose its event.
--
-- A rejected booking uses ROLLBACK TO SAVEPOINT rather than an exception, so
-- the caller gets a clean result code and no orphaned session row.
--
-- Lock ordering is STUDENTS then TUTORS, everywhere, so two bookings racing
-- for the same slot queue up instead of deadlocking.
-- =============================================================================

CREATE OR REPLACE PACKAGE PKG_SCHEDULING AS

  -- Tutor-initiated booking: goes straight to CONFIRMED and reserves the hours.
  PROCEDURE book_session (
    p_student_id IN  NUMBER,
    p_start_time IN  TIMESTAMP,
    p_duration   IN  NUMBER,
    p_notes      IN  VARCHAR2 DEFAULT NULL,
    p_tutor_id   IN  NUMBER   DEFAULT 1,
    p_session_id OUT NUMBER,
    p_result     OUT VARCHAR2
  );

  -- Parent-initiated request: holds the slot and the hours as REQUESTED until
  -- the tutor confirms. Same conflict and balance rules as a booking, because
  -- a request that cannot be honoured is worse than a refusal.
  PROCEDURE request_session (
    p_student_id IN  NUMBER,
    p_start_time IN  TIMESTAMP,
    p_duration   IN  NUMBER,
    p_notes      IN  VARCHAR2 DEFAULT NULL,
    p_tutor_id   IN  NUMBER   DEFAULT 1,
    p_session_id OUT NUMBER,
    p_result     OUT VARCHAR2
  );

  PROCEDURE confirm_session (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  );

  -- Inside the 24 hour window the hours are forfeited (LATE_CANCELLED);
  -- outside it they go back on the package (CANCELLED).
  PROCEDURE cancel_session (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  );

  PROCEDURE complete_session (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  );

  PROCEDURE get_session (
    p_session_id IN  NUMBER,
    p_cursor     OUT SYS_REFCURSOR,
    p_result     OUT VARCHAR2
  );

  -- Queues a reminder event for every confirmed session starting inside the
  -- next p_hours_ahead hours that does not already have one. Driven by the
  -- nightly timer function; idempotent so a double run sends nothing twice.
  PROCEDURE queue_due_reminders (
    p_hours_ahead  IN  NUMBER DEFAULT 24,
    p_queued_count OUT NUMBER
  );

END PKG_SCHEDULING;
/

CREATE OR REPLACE PACKAGE BODY PKG_SCHEDULING AS

  -- Shared by book_session and request_session. p_target_status decides which
  -- of the two this is; everything else about the two paths is identical.
  PROCEDURE create_session_internal (
    p_student_id    IN  NUMBER,
    p_start_time    IN  TIMESTAMP,
    p_duration      IN  NUMBER,
    p_notes         IN  VARCHAR2,
    p_tutor_id      IN  NUMBER,
    p_target_status IN  VARCHAR2,
    p_session_id    OUT NUMBER,
    p_result        OUT VARCHAR2
  )
  IS
    l_is_active   STUDENTS.IS_ACTIVE%TYPE;
    l_tutor_id    TUTORS.TUTOR_ID%TYPE;
    l_end_time    TIMESTAMP;
    l_conflicts   PLS_INTEGER;
    l_hours       NUMBER;
    l_package_id  PACKAGES.PACKAGE_ID%TYPE;
    l_payment_id  PAYMENTS.PAYMENT_ID%TYPE;
    l_bill_result VARCHAR2(40);
  BEGIN
    p_session_id := NULL;

    -- --- cheap checks before any lock is taken ------------------------------
    IF p_student_id IS NULL OR p_start_time IS NULL THEN
      p_result := PKG_VALIDATION.c_err_invalid_input;
      RETURN;
    END IF;

    -- Past-ness before business hours: a start in the past is in the past no
    -- matter what hour of day it fell on, and the more specific error wins.
    IF p_start_time <= SYSTIMESTAMP THEN
      p_result := PKG_VALIDATION.c_err_start_in_past;
      RETURN;
    END IF;

    p_result := PKG_VALIDATION.check_business_hours(p_start_time, p_duration);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    -- --- lock student, then tutor (never the other order) -------------------
    BEGIN
      SELECT IS_ACTIVE
        INTO l_is_active
        FROM STUDENTS
       WHERE STUDENT_ID = p_student_id
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_result := PKG_VALIDATION.c_err_student_not_found;
        RETURN;
    END;

    IF l_is_active = 'N' THEN
      p_result := PKG_VALIDATION.c_err_student_inactive;
      RETURN;
    END IF;

    -- Holding the tutor row is what makes the overlap check below a decision
    -- rather than a guess: no second transaction can insert a competing
    -- session between the count and the insert.
    BEGIN
      SELECT TUTOR_ID
        INTO l_tutor_id
        FROM TUTORS
       WHERE TUTOR_ID = NVL(p_tutor_id, 1)
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        p_result := PKG_VALIDATION.c_err_invalid_input;
        RETURN;
    END;

    l_end_time := p_start_time + NUMTODSINTERVAL(p_duration, 'MINUTE');

    -- Standard half-open overlap: two intervals collide when each starts
    -- before the other ends. Back-to-back sessions therefore do not collide.
    -- REQUESTED counts as occupying the slot; an unconfirmed request that
    -- someone else can book over is not holding anything.
    SELECT COUNT(*)
      INTO l_conflicts
      FROM SESSIONS
     WHERE TUTOR_ID   = l_tutor_id
       AND STATUS     IN (PKG_VALIDATION.c_status_requested,
                          PKG_VALIDATION.c_status_confirmed)
       AND START_TIME <  l_end_time
       AND END_TIME   >  p_start_time;

    IF l_conflicts > 0 THEN
      p_result := PKG_VALIDATION.c_err_double_booked;
      RETURN;
    END IF;

    -- --- past this point we write, so give ourselves a way back ------------
    SAVEPOINT before_session;

    l_hours := PKG_VALIDATION.minutes_to_hours(p_duration);

    INSERT INTO SESSIONS (
      STUDENT_ID, TUTOR_ID, START_TIME, DURATION_MINUTES,
      STATUS, HOURS_RESERVED, NOTES
    ) VALUES (
      p_student_id, l_tutor_id, p_start_time, p_duration,
      p_target_status, 0, p_notes
    )
    RETURNING SESSION_ID INTO p_session_id;

    -- Package hours first; an unapplied payment is the fallback for the
    -- pay-per-session students who never buy a block.
    PKG_BILLING.reserve_hours(
      p_student_id => p_student_id,
      p_session_id => p_session_id,
      p_hours      => l_hours,
      p_package_id => l_package_id,
      p_result     => l_bill_result);

    IF l_bill_result = PKG_VALIDATION.c_err_insufficient_hours THEN
      PKG_BILLING.apply_payment(
        p_student_id => p_student_id,
        p_session_id => p_session_id,
        p_payment_id => l_payment_id,
        p_result     => l_bill_result);
    END IF;

    IF l_bill_result <> PKG_VALIDATION.c_ok THEN
      -- Undo the session row so a rejected booking leaves nothing behind.
      ROLLBACK TO SAVEPOINT before_session;
      p_session_id := NULL;
      p_result     := l_bill_result;
      RETURN;
    END IF;

    UPDATE SESSIONS
       SET PACKAGE_ID     = l_package_id,
           HOURS_RESERVED = CASE WHEN l_package_id IS NULL THEN 0 ELSE l_hours END,
           UPDATED_AT     = SYSTIMESTAMP
     WHERE SESSION_ID = p_session_id;

    PKG_EVENTS.enqueue_session_event(p_session_id, PKG_EVENTS.c_evt_session_booked);

    p_result := PKG_VALIDATION.c_ok;
  END create_session_internal;


  PROCEDURE book_session (
    p_student_id IN  NUMBER,
    p_start_time IN  TIMESTAMP,
    p_duration   IN  NUMBER,
    p_notes      IN  VARCHAR2 DEFAULT NULL,
    p_tutor_id   IN  NUMBER   DEFAULT 1,
    p_session_id OUT NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
  BEGIN
    create_session_internal(
      p_student_id    => p_student_id,
      p_start_time    => p_start_time,
      p_duration      => p_duration,
      p_notes         => p_notes,
      p_tutor_id      => p_tutor_id,
      p_target_status => PKG_VALIDATION.c_status_confirmed,
      p_session_id    => p_session_id,
      p_result        => p_result);
  END book_session;


  PROCEDURE request_session (
    p_student_id IN  NUMBER,
    p_start_time IN  TIMESTAMP,
    p_duration   IN  NUMBER,
    p_notes      IN  VARCHAR2 DEFAULT NULL,
    p_tutor_id   IN  NUMBER   DEFAULT 1,
    p_session_id OUT NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
  BEGIN
    create_session_internal(
      p_student_id    => p_student_id,
      p_start_time    => p_start_time,
      p_duration      => p_duration,
      p_notes         => p_notes,
      p_tutor_id      => p_tutor_id,
      p_target_status => PKG_VALIDATION.c_status_requested,
      p_session_id    => p_session_id,
      p_result        => p_result);
  END request_session;


  -- Locks the student first (to keep the global ordering) and then the session
  -- row itself. Returns the current status so callers can validate transitions.
  PROCEDURE lock_session (
    p_session_id IN  NUMBER,
    p_student_id OUT NUMBER,
    p_status     OUT VARCHAR2,
    p_start_time OUT TIMESTAMP,
    p_result     OUT VARCHAR2
  )
  IS
    l_student_id SESSIONS.STUDENT_ID%TYPE;
  BEGIN
    SELECT STUDENT_ID
      INTO l_student_id
      FROM SESSIONS
     WHERE SESSION_ID = p_session_id;

    -- Take the balance lock before the session lock, matching book_session.
    SELECT STUDENT_ID
      INTO p_student_id
      FROM STUDENTS
     WHERE STUDENT_ID = l_student_id
       FOR UPDATE;

    SELECT STATUS, START_TIME
      INTO p_status, p_start_time
      FROM SESSIONS
     WHERE SESSION_ID = p_session_id
       FOR UPDATE;

    p_result := PKG_VALIDATION.c_ok;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result := PKG_VALIDATION.c_err_session_not_found;
  END lock_session;


  PROCEDURE confirm_session (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    l_student_id NUMBER;
    l_status     VARCHAR2(20);
    l_start_time TIMESTAMP;
  BEGIN
    lock_session(p_session_id, l_student_id, l_status, l_start_time, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    PKG_VALIDATION.check_transition(l_status, PKG_VALIDATION.c_status_confirmed, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    UPDATE SESSIONS
       SET STATUS     = PKG_VALIDATION.c_status_confirmed,
           UPDATED_AT = SYSTIMESTAMP
     WHERE SESSION_ID = p_session_id;

    -- The hours were already reserved when the slot was requested, so
    -- confirming moves no money and no hours.
    PKG_EVENTS.enqueue_session_event(p_session_id, PKG_EVENTS.c_evt_session_booked);

    p_result := PKG_VALIDATION.c_ok;
  END confirm_session;


  PROCEDURE cancel_session (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    l_student_id    NUMBER;
    l_status        VARCHAR2(20);
    l_start_time    TIMESTAMP;
    l_target_status VARCHAR2(20);
    l_is_late       VARCHAR2(1);
    l_bill_result   VARCHAR2(40);
  BEGIN
    lock_session(p_session_id, l_student_id, l_status, l_start_time, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    l_is_late := PKG_VALIDATION.is_late_cancellation(l_start_time);
    l_target_status := CASE l_is_late
                         WHEN 'Y' THEN PKG_VALIDATION.c_status_late_cancelled
                         ELSE          PKG_VALIDATION.c_status_cancelled
                       END;

    -- Rejects the second cancel of an already-cancelled session and any
    -- attempt to walk a COMPLETED session back. This is the check that stops
    -- hours being restored twice even before the ledger constraint is reached.
    PKG_VALIDATION.check_transition(l_status, l_target_status, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    IF l_is_late = 'N' THEN
      -- On time: the hours and any pay-per-session credit go back.
      PKG_BILLING.release_hours(p_session_id, l_bill_result);
      IF l_bill_result <> PKG_VALIDATION.c_ok THEN
        p_result := l_bill_result;
        RETURN;
      END IF;

      PKG_BILLING.release_payment(p_session_id, l_bill_result);
      IF l_bill_result <> PKG_VALIDATION.c_ok THEN
        p_result := l_bill_result;
        RETURN;
      END IF;
    END IF;
    -- Late: nothing is released. The reservation made at booking simply stands,
    -- which is what "the hour is still charged" means in this schema.

    UPDATE SESSIONS
       SET STATUS       = l_target_status,
           CANCELLED_AT = SYSTIMESTAMP,
           UPDATED_AT   = SYSTIMESTAMP
     WHERE SESSION_ID = p_session_id;

    PKG_EVENTS.enqueue_session_event(
      p_session_id,
      CASE l_is_late
        WHEN 'Y' THEN PKG_EVENTS.c_evt_session_late_cancel
        ELSE          PKG_EVENTS.c_evt_session_cancelled
      END);

    p_result := PKG_VALIDATION.c_ok;
  END cancel_session;


  PROCEDURE complete_session (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    l_student_id NUMBER;
    l_status     VARCHAR2(20);
    l_start_time TIMESTAMP;
  BEGIN
    lock_session(p_session_id, l_student_id, l_status, l_start_time, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    PKG_VALIDATION.check_transition(l_status, PKG_VALIDATION.c_status_completed, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    -- No ledger entry here on purpose. The hours left the package when the
    -- session was booked; completing it is what makes that deduction final
    -- rather than releasable. The absence of a RELEASE row *is* the deduction.
    UPDATE SESSIONS
       SET STATUS       = PKG_VALIDATION.c_status_completed,
           COMPLETED_AT = SYSTIMESTAMP,
           UPDATED_AT   = SYSTIMESTAMP
     WHERE SESSION_ID = p_session_id;

    PKG_EVENTS.enqueue_session_event(p_session_id, PKG_EVENTS.c_evt_session_completed);

    p_result := PKG_VALIDATION.c_ok;
  END complete_session;


  PROCEDURE get_session (
    p_session_id IN  NUMBER,
    p_cursor     OUT SYS_REFCURSOR,
    p_result     OUT VARCHAR2
  )
  IS
    l_exists PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_exists
      FROM SESSIONS
     WHERE SESSION_ID = p_session_id;

    IF l_exists = 0 THEN
      p_result := PKG_VALIDATION.c_err_session_not_found;
      RETURN;
    END IF;

    OPEN p_cursor FOR
      SELECT se.SESSION_ID,
             se.STUDENT_ID,
             st.FULL_NAME AS STUDENT_NAME,
             se.START_TIME,
             se.END_TIME,
             se.DURATION_MINUTES,
             se.STATUS,
             se.PACKAGE_ID,
             se.NOTES
        FROM SESSIONS se
        JOIN STUDENTS st ON st.STUDENT_ID = se.STUDENT_ID
       WHERE se.SESSION_ID = p_session_id;

    p_result := PKG_VALIDATION.c_ok;
  END get_session;


  PROCEDURE queue_due_reminders (
    p_hours_ahead  IN  NUMBER DEFAULT 24,
    p_queued_count OUT NUMBER
  )
  IS
    l_count PLS_INTEGER := 0;
  BEGIN
    FOR r IN (
      SELECT s.SESSION_ID
        FROM SESSIONS s
       WHERE s.STATUS = PKG_VALIDATION.c_status_confirmed
         AND s.START_TIME > SYSTIMESTAMP
         AND s.START_TIME <= SYSTIMESTAMP + NUMTODSINTERVAL(p_hours_ahead, 'HOUR')
         -- Idempotency: one reminder per session, ever. A second nightly run,
         -- or a retry after a crash, queues nothing.
         AND NOT EXISTS (
               SELECT 1
                 FROM EVENT_OUTBOX e
                WHERE e.AGGREGATE_TYPE = 'SESSION'
                  AND e.AGGREGATE_ID   = s.SESSION_ID
                  AND e.EVENT_TYPE     = PKG_EVENTS.c_evt_session_reminder)
       ORDER BY s.START_TIME
    ) LOOP
      PKG_EVENTS.enqueue_session_event(r.SESSION_ID, PKG_EVENTS.c_evt_session_reminder);
      l_count := l_count + 1;
    END LOOP;

    p_queued_count := l_count;
  END queue_due_reminders;

END PKG_SCHEDULING;
/

SHOW ERRORS PACKAGE PKG_SCHEDULING
SHOW ERRORS PACKAGE BODY PKG_SCHEDULING
