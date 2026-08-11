-- =============================================================================
-- 40_test_consistency.sql -- the edge case this project exists to answer.
--
-- The question an interviewer asks is "why does the business logic live in the
-- database?" The answer is this file: the invariant survives callers that get
-- it wrong, transactions that roll back, and operations applied twice, because
-- it is enforced by constraints and locks rather than by discipline in the
-- application layer.
--
-- The genuinely concurrent version of this -- two transactions racing -- is in
-- run_concurrency.sh, which needs more than one session to be meaningful.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

BEGIN
  PKG_TEST.start_suite('consistency: releasing hours twice credits them once');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
  BEGIN
    l_student := PKG_TEST.new_student('Double Release');
    PKG_BILLING.purchase_package(l_student, 2, 100, 'ZELLE', NULL, l_package, l_result);

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(6, 10), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('balance after booking', 1, PKG_BILLING.get_balance(l_student));

    -- Go under cancel_session and call the billing primitive directly, twice.
    -- The status guard in cancel_session is not what protects the balance
    -- here; the NOT EXISTS predicate and the unique index are.
    PKG_BILLING.release_hours(l_session, l_result);
    PKG_TEST.assert_equals('first release succeeds', 'OK', l_result);
    PKG_TEST.assert_equals('balance restored once', 2, PKG_BILLING.get_balance(l_student));

    PKG_BILLING.release_hours(l_session, l_result);
    PKG_TEST.assert_equals('second release is a no-op, not an error', 'OK', l_result);
    PKG_TEST.assert_equals('balance still 2, not 3', 2, PKG_BILLING.get_balance(l_student));
    PKG_TEST.assert_equals('exactly one RELEASE row', 1,
                           PKG_TEST.ledger_count(l_session, 'RELEASE'));

    PKG_TEST.assert_ledger_consistent('double release');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('consistency: the constraints hold without the packages');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
    l_raised  VARCHAR2(20);
  BEGIN
    l_student := PKG_TEST.new_student('Constraint Probe');
    PKG_BILLING.purchase_package(l_student, 2, 100, 'ZELLE', NULL, l_package, l_result);
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(6, 10), 60, NULL, 1, l_session, l_result);
    COMMIT;

    -- A second RELEASE row for the same session and package is impossible even
    -- if someone writes it by hand. This is the difference between a rule and
    -- a convention.
    l_raised := 'none';
    BEGIN
      INSERT INTO PACKAGE_LEDGER (PACKAGE_ID, SESSION_ID, ENTRY_TYPE, HOURS_DELTA)
      VALUES (l_package, l_session, 'RESERVE', -1);
    EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN
        l_raised := 'duplicate';
    END;
    ROLLBACK;
    PKG_TEST.assert_equals('duplicate ledger entry rejected', 'duplicate', l_raised);

    -- Driving the balance negative by hand is a check constraint violation.
    l_raised := 'none';
    BEGIN
      UPDATE PACKAGES SET HOURS_REMAINING = -1 WHERE PACKAGE_ID = l_package;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE = -2290 THEN
          l_raised := 'check';
        ELSE
          RAISE;
        END IF;
    END;
    ROLLBACK;
    PKG_TEST.assert_equals('negative balance rejected', 'check', l_raised);

    -- A release with a negative delta would be a disguised deduction.
    l_raised := 'none';
    BEGIN
      INSERT INTO PACKAGE_LEDGER (PACKAGE_ID, SESSION_ID, ENTRY_TYPE, HOURS_DELTA)
      VALUES (l_package, l_session, 'RELEASE', -5);
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE = -2290 THEN
          l_raised := 'check';
        ELSE
          RAISE;
        END IF;
    END;
    ROLLBACK;
    PKG_TEST.assert_equals('wrong-signed ledger entry rejected', 'check', l_raised);

    PKG_TEST.assert_ledger_consistent('constraint probe');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('consistency: a cancel and a purchase in one transaction');

  PKG_TEST.reset_data;

  DECLARE
    l_student  NUMBER;
    l_package  NUMBER;
    l_package2 NUMBER;
    l_session  NUMBER;
    l_result   VARCHAR2(40);
  BEGIN
    l_student := PKG_TEST.new_student('Interleaved');
    PKG_BILLING.purchase_package(l_student, 2, 100, 'ZELLE', NULL, l_package, l_result);
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(6, 10), 60, NULL, 1, l_session, l_result);
    COMMIT;

    PKG_TEST.assert_equals('starting balance', 1, PKG_BILLING.get_balance(l_student));

    -- Restore an hour and buy five more in the same transaction, then throw
    -- the whole thing away. Neither half may survive.
    PKG_SCHEDULING.cancel_session(l_session, l_result);
    PKG_TEST.assert_equals('cancel succeeds', 'OK', l_result);
    PKG_BILLING.purchase_package(l_student, 5, 250, 'CASH', NULL, l_package2, l_result);
    PKG_TEST.assert_equals('purchase succeeds', 'OK', l_result);
    PKG_TEST.assert_equals('uncommitted balance is 7', 7, PKG_BILLING.get_balance(l_student));

    ROLLBACK;

    PKG_TEST.assert_equals('rollback undoes both', 1, PKG_BILLING.get_balance(l_student));
    PKG_TEST.assert_equals('the restore is gone too', 0,
                           PKG_TEST.ledger_count(l_session, 'RELEASE'));

    PKG_TEST.assert_ledger_consistent('interleaved rollback');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('consistency: an event never outlives its transaction');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
  BEGIN
    l_student := PKG_TEST.new_student('Outbox Atomicity');
    PKG_BILLING.purchase_package(l_student, 5, 250, 'ZELLE', NULL, l_package, l_result);
    COMMIT;

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(6, 11), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('booking succeeds', 'OK', l_result);
    PKG_TEST.assert_equals('event is pending in this transaction', 1,
                           PKG_TEST.outbox_count('SessionBooked'));

    ROLLBACK;

    -- This is the whole argument for the outbox. A message bus publish inside
    -- the same code path would already have been sent by now, telling a parent
    -- about a lesson that does not exist.
    PKG_TEST.assert_equals('rolled-back booking left no event', 0,
                           PKG_TEST.outbox_count('SessionBooked'));

    DECLARE
      l_sessions NUMBER;
    BEGIN
      SELECT COUNT(*) INTO l_sessions FROM SESSIONS;
      PKG_TEST.assert_equals('and no session', 0, l_sessions);
    END;

    COMMIT;
  END;
END;
/

SET FEEDBACK ON
