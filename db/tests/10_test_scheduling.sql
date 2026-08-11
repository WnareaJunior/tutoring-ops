-- =============================================================================
-- 10_test_scheduling.sql -- booking, cancellation and completion rules.
--
-- Every test resets the data first so the file can be run on its own.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

BEGIN
  PKG_TEST.start_suite('scheduling: happy path');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
    l_status  VARCHAR2(20);
  BEGIN
    l_student := PKG_TEST.new_student('Happy Path');

    PKG_BILLING.purchase_package(
      p_student_id => l_student, p_hours => 10, p_amount => 500,
      p_method => 'ZELLE', p_expires_on => NULL,
      p_package_id => l_package, p_result => l_result);
    PKG_TEST.assert_equals('purchase succeeds', 'OK', l_result);
    PKG_TEST.assert_equals('balance is 10 after purchase', 10, PKG_BILLING.get_balance(l_student));

    PKG_SCHEDULING.book_session(
      p_student_id => l_student,
      p_start_time => PKG_TEST.slot(3, 10),
      p_duration   => 90,
      p_notes      => 'Reading section',
      p_tutor_id   => 1,
      p_session_id => l_session,
      p_result     => l_result);

    PKG_TEST.assert_equals('book succeeds', 'OK', l_result);
    PKG_TEST.assert_not_null('session id returned', l_session);

    SELECT STATUS INTO l_status FROM SESSIONS WHERE SESSION_ID = l_session;
    PKG_TEST.assert_equals('session is CONFIRMED', 'CONFIRMED', l_status);

    -- 90 minutes is 1.5 hours, reserved at booking time rather than at
    -- completion. This is the assertion that pins the whole hours model.
    PKG_TEST.assert_equals('balance drops to 8.5', 8.5, PKG_BILLING.get_balance(l_student));
    PKG_TEST.assert_equals('one RESERVE ledger row', 1, PKG_TEST.ledger_count(l_session, 'RESERVE'));
    PKG_TEST.assert_equals('booking raised an event', 1,
                           PKG_TEST.outbox_count('SessionBooked'));

    PKG_SCHEDULING.complete_session(l_session, l_result);
    PKG_TEST.assert_equals('complete succeeds', 'OK', l_result);

    SELECT STATUS INTO l_status FROM SESSIONS WHERE SESSION_ID = l_session;
    PKG_TEST.assert_equals('session is COMPLETED', 'COMPLETED', l_status);

    -- Completion finalises the deduction; it does not deduct a second time.
    PKG_TEST.assert_equals('balance still 8.5 after completion', 8.5,
                           PKG_BILLING.get_balance(l_student));

    PKG_TEST.assert_ledger_consistent('happy path');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('scheduling: double booking is rejected');

  PKG_TEST.reset_data;

  DECLARE
    l_student_a NUMBER;
    l_student_b NUMBER;
    l_package   NUMBER;
    l_session_a NUMBER;
    l_session_b NUMBER;
    l_result    VARCHAR2(40);
    l_start     TIMESTAMP := PKG_TEST.slot(4, 14);
  BEGIN
    l_student_a := PKG_TEST.new_student('Student A');
    l_student_b := PKG_TEST.new_student('Student B');

    PKG_BILLING.purchase_package(l_student_a, 10, 500, 'ZELLE', NULL, l_package, l_result);
    PKG_BILLING.purchase_package(l_student_b, 10, 500, 'ZELLE', NULL, l_package, l_result);

    PKG_SCHEDULING.book_session(l_student_a, l_start, 60, NULL, 1, l_session_a, l_result);
    PKG_TEST.assert_equals('first booking succeeds', 'OK', l_result);

    -- Same tutor, same hour, different student. The conflict rule is about the
    -- tutor's time, not the student's.
    PKG_SCHEDULING.book_session(l_student_b, l_start, 60, NULL, 1, l_session_b, l_result);
    PKG_TEST.assert_equals('overlapping booking rejected', 'ERR_DOUBLE_BOOKED', l_result);
    PKG_TEST.assert_null('no session row returned', l_session_b);

    -- A rejected booking must not have spent anything.
    PKG_TEST.assert_equals('student B balance untouched', 10,
                           PKG_BILLING.get_balance(l_student_b));

    -- Partial overlap: starts 30 minutes into the existing hour.
    PKG_SCHEDULING.book_session(l_student_b, l_start + INTERVAL '30' MINUTE, 60,
                                NULL, 1, l_session_b, l_result);
    PKG_TEST.assert_equals('partial overlap rejected', 'ERR_DOUBLE_BOOKED', l_result);

    -- Back to back is not an overlap: the intervals are half-open.
    PKG_SCHEDULING.book_session(l_student_b, l_start + INTERVAL '60' MINUTE, 60,
                                NULL, 1, l_session_b, l_result);
    PKG_TEST.assert_equals('adjacent booking allowed', 'OK', l_result);

    PKG_TEST.assert_ledger_consistent('double booking');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('scheduling: calendar and input rules');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
  BEGIN
    l_student := PKG_TEST.new_student('Calendar Rules');
    PKG_BILLING.purchase_package(l_student, 20, 1000, 'ZELLE', NULL, l_package, l_result);

    -- 06:00 is before opening.
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 6), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('before opening rejected', 'ERR_OUTSIDE_BUSINESS_HOURS', l_result);

    -- Starts at 20:00, would run to 22:00 -- past closing.
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 20), 120, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('overrunning closing rejected', 'ERR_OUTSIDE_BUSINESS_HOURS', l_result);

    -- Exactly up to closing is fine.
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 20), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('finishing at closing allowed', 'OK', l_result);

    -- 45 minutes is on the quarter-hour grid, so it is a legitimate lesson.
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(5, 11), 45, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('45-minute duration allowed', 'OK', l_result);

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(6, 11), 20, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('too-short duration rejected', 'ERR_INVALID_DURATION', l_result);

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(6, 12), 50, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('off-grid duration rejected', 'ERR_INVALID_DURATION', l_result);

    PKG_SCHEDULING.book_session(l_student, SYSTIMESTAMP - INTERVAL '1' HOUR, 60,
                                NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('past start rejected', 'ERR_START_IN_PAST', l_result);

    PKG_SCHEDULING.book_session(-999, PKG_TEST.slot(7, 10), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('unknown student rejected', 'ERR_STUDENT_NOT_FOUND', l_result);

    PKG_TEST.assert_ledger_consistent('calendar rules');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('scheduling: no balance');

  PKG_TEST.reset_data;

  DECLARE
    l_student   NUMBER;
    l_session   NUMBER;
    l_result    VARCHAR2(40);
    l_sessions  NUMBER;
  BEGIN
    l_student := PKG_TEST.new_student('Broke Student');

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 10), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('booking without hours rejected', 'ERR_INSUFFICIENT_HOURS', l_result);

    -- The savepoint rollback has to leave the table exactly as it was.
    SELECT COUNT(*) INTO l_sessions FROM SESSIONS;
    PKG_TEST.assert_equals('no orphaned session row', 0, l_sessions);
    PKG_TEST.assert_equals('no orphaned event', 0, PKG_TEST.outbox_count('SessionBooked'));

    -- One hour bought, ninety minutes requested: still short.
    DECLARE
      l_package NUMBER;
    BEGIN
      PKG_BILLING.purchase_package(l_student, 1, 50, 'CASH', NULL, l_package, l_result);
    END;

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 10), 90, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('partial balance rejected', 'ERR_INSUFFICIENT_HOURS', l_result);
    PKG_TEST.assert_equals('balance untouched after rejection', 1,
                           PKG_BILLING.get_balance(l_student));

    PKG_TEST.assert_ledger_consistent('no balance');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('scheduling: cancellation windows');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_early   NUMBER;
    l_late    NUMBER;
    l_result  VARCHAR2(40);
    l_status  VARCHAR2(20);
  BEGIN
    l_student := PKG_TEST.new_student('Canceller');
    PKG_BILLING.purchase_package(l_student, 10, 500, 'ZELLE', NULL, l_package, l_result);

    -- --- outside the window: hours come back ------------------------------
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(7, 10), 60, NULL, 1, l_early, l_result);
    PKG_TEST.assert_equals('balance 9 after booking', 9, PKG_BILLING.get_balance(l_student));

    PKG_SCHEDULING.cancel_session(l_early, l_result);
    PKG_TEST.assert_equals('on-time cancel succeeds', 'OK', l_result);

    SELECT STATUS INTO l_status FROM SESSIONS WHERE SESSION_ID = l_early;
    PKG_TEST.assert_equals('status is CANCELLED', 'CANCELLED', l_status);
    PKG_TEST.assert_equals('hours restored', 10, PKG_BILLING.get_balance(l_student));
    PKG_TEST.assert_equals('exactly one RELEASE row', 1, PKG_TEST.ledger_count(l_early, 'RELEASE'));

    -- Cancelling again must not credit a second time.
    PKG_SCHEDULING.cancel_session(l_early, l_result);
    PKG_TEST.assert_equals('second cancel rejected', 'ERR_INVALID_TRANSITION', l_result);
    PKG_TEST.assert_equals('still exactly one RELEASE row', 1,
                           PKG_TEST.ledger_count(l_early, 'RELEASE'));
    PKG_TEST.assert_equals('balance not double-restored', 10,
                           PKG_BILLING.get_balance(l_student));

    -- --- inside the window: hours are forfeited ---------------------------
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(7, 12), 60, NULL, 1, l_late, l_result);
    PKG_TEST.assert_equals('balance 9 after second booking', 9,
                           PKG_BILLING.get_balance(l_student));

    -- Simulate the clock advancing to two hours before the session. The
    -- calendar rules were checked at booking; moving the row only changes
    -- which side of the cancellation window we are on.
    UPDATE SESSIONS
       SET START_TIME = SYSTIMESTAMP + INTERVAL '2' HOUR
     WHERE SESSION_ID = l_late;

    PKG_SCHEDULING.cancel_session(l_late, l_result);
    PKG_TEST.assert_equals('late cancel succeeds', 'OK', l_result);

    SELECT STATUS INTO l_status FROM SESSIONS WHERE SESSION_ID = l_late;
    PKG_TEST.assert_equals('status is LATE_CANCELLED', 'LATE_CANCELLED', l_status);
    PKG_TEST.assert_equals('hours NOT restored on late cancel', 9,
                           PKG_BILLING.get_balance(l_student));
    PKG_TEST.assert_equals('no RELEASE row for late cancel', 0,
                           PKG_TEST.ledger_count(l_late, 'RELEASE'));
    PKG_TEST.assert_equals('late cancel raised its own event', 1,
                           PKG_TEST.outbox_count('SessionLateCancelled'));

    PKG_TEST.assert_ledger_consistent('cancellation windows');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('scheduling: reminder sweep is idempotent');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
    l_queued  NUMBER;
  BEGIN
    l_student := PKG_TEST.new_student('Reminder Target');
    PKG_BILLING.purchase_package(l_student, 10, 500, 'ZELLE', NULL, l_package, l_result);

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(7, 10), 60, NULL, 1, l_session, l_result);

    -- Move it inside the reminder horizon.
    UPDATE SESSIONS
       SET START_TIME = SYSTIMESTAMP + INTERVAL '6' HOUR
     WHERE SESSION_ID = l_session;

    PKG_SCHEDULING.queue_due_reminders(24, l_queued);
    PKG_TEST.assert_equals('one reminder queued', 1, l_queued);

    PKG_SCHEDULING.queue_due_reminders(24, l_queued);
    PKG_TEST.assert_equals('second sweep queues nothing', 0, l_queued);
    PKG_TEST.assert_equals('still one reminder event', 1,
                           PKG_TEST.outbox_count('SessionReminderDue'));

    COMMIT;
  END;
END;
/

SET FEEDBACK ON
