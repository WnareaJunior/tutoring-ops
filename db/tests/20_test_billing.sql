-- =============================================================================
-- 20_test_billing.sql -- FIFO hour consumption, package splitting, and the
-- pay-per-session path.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

BEGIN
  PKG_TEST.start_suite('billing: oldest package is spent first');

  PKG_TEST.reset_data;

  DECLARE
    l_student   NUMBER;
    l_old_pkg   NUMBER;
    l_new_pkg   NUMBER;
    l_session   NUMBER;
    l_result    VARCHAR2(40);
    l_old_left  NUMBER;
    l_new_left  NUMBER;
    l_old_state VARCHAR2(20);
  BEGIN
    l_student := PKG_TEST.new_student('FIFO Student');

    PKG_BILLING.purchase_package(l_student, 1, 60, 'CASH',  NULL, l_old_pkg, l_result);
    PKG_BILLING.purchase_package(l_student, 5, 250, 'ZELLE', NULL, l_new_pkg, l_result);

    -- Make the ordering unambiguous rather than relying on two purchases
    -- landing on different microseconds.
    UPDATE PACKAGES
       SET PURCHASED_DATE = SYSTIMESTAMP - INTERVAL '30' DAY
     WHERE PACKAGE_ID = l_old_pkg;

    PKG_TEST.assert_equals('combined balance is 6', 6, PKG_BILLING.get_balance(l_student));

    -- One hour, and the older package holds exactly one hour.
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 9), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('booking succeeds', 'OK', l_result);

    SELECT HOURS_REMAINING, STATUS INTO l_old_left, l_old_state
      FROM PACKAGES WHERE PACKAGE_ID = l_old_pkg;
    SELECT HOURS_REMAINING INTO l_new_left
      FROM PACKAGES WHERE PACKAGE_ID = l_new_pkg;

    PKG_TEST.assert_equals('older package drained first', 0, l_old_left);
    PKG_TEST.assert_equals('newer package untouched', 5, l_new_left);
    PKG_TEST.assert_equals('drained package marked EXHAUSTED', 'EXHAUSTED', l_old_state);
    PKG_TEST.assert_equals('exhaustion raised an event', 1,
                           PKG_TEST.outbox_count('PackageExhausted'));

    -- The session records the package the hours actually came from.
    DECLARE
      l_recorded NUMBER;
    BEGIN
      SELECT PACKAGE_ID INTO l_recorded FROM SESSIONS WHERE SESSION_ID = l_session;
      PKG_TEST.assert_equals('session points at the older package', l_old_pkg, l_recorded);
    END;

    PKG_TEST.assert_ledger_consistent('fifo');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('billing: a booking may span two packages');

  PKG_TEST.reset_data;

  DECLARE
    l_student  NUMBER;
    l_old_pkg  NUMBER;
    l_new_pkg  NUMBER;
    l_session  NUMBER;
    l_result   VARCHAR2(40);
    l_old_left NUMBER;
    l_new_left NUMBER;
  BEGIN
    l_student := PKG_TEST.new_student('Split Student');

    PKG_BILLING.purchase_package(l_student, 1, 60, 'CASH',  NULL, l_old_pkg, l_result);
    PKG_BILLING.purchase_package(l_student, 5, 250, 'ZELLE', NULL, l_new_pkg, l_result);
    UPDATE PACKAGES
       SET PURCHASED_DATE = SYSTIMESTAMP - INTERVAL '30' DAY
     WHERE PACKAGE_ID = l_old_pkg;

    -- 90 minutes against a 1-hour package: one hour from the old, half from
    -- the new. This is the edge case that a single PACKAGE_ID column on
    -- SESSIONS could not represent on its own, which is why the ledger exists.
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 9), 90, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('split booking succeeds', 'OK', l_result);

    SELECT HOURS_REMAINING INTO l_old_left FROM PACKAGES WHERE PACKAGE_ID = l_old_pkg;
    SELECT HOURS_REMAINING INTO l_new_left FROM PACKAGES WHERE PACKAGE_ID = l_new_pkg;

    PKG_TEST.assert_equals('old package fully used', 0, l_old_left);
    PKG_TEST.assert_equals('new package gave up half an hour', 4.5, l_new_left);
    PKG_TEST.assert_equals('two RESERVE rows written', 2,
                           PKG_TEST.ledger_count(l_session, 'RESERVE'));
    PKG_TEST.assert_equals('balance is 4.5', 4.5, PKG_BILLING.get_balance(l_student));

    -- Cancelling has to unwind both halves, and exactly once each.
    PKG_SCHEDULING.cancel_session(l_session, l_result);
    PKG_TEST.assert_equals('cancel succeeds', 'OK', l_result);
    PKG_TEST.assert_equals('two RELEASE rows written', 2,
                           PKG_TEST.ledger_count(l_session, 'RELEASE'));
    PKG_TEST.assert_equals('full balance restored', 6, PKG_BILLING.get_balance(l_student));

    DECLARE
      l_old_state VARCHAR2(20);
    BEGIN
      SELECT STATUS INTO l_old_state FROM PACKAGES WHERE PACKAGE_ID = l_old_pkg;
      PKG_TEST.assert_equals('refilled package is ACTIVE again', 'ACTIVE', l_old_state);
    END;

    PKG_TEST.assert_ledger_consistent('split booking');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('billing: pay-per-session students');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_payment NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
    l_applied VARCHAR2(1);
    l_linked  NUMBER;
  BEGIN
    l_student := PKG_TEST.new_student('Pay As You Go');

    -- No package, so a booking has nothing to draw on yet.
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 15), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('no credit means no booking', 'ERR_INSUFFICIENT_HOURS', l_result);

    PKG_BILLING.record_payment(l_student, 60, 'VENMO', 'single lesson', l_payment, l_result);
    PKG_TEST.assert_equals('payment recorded', 'OK', l_result);
    PKG_TEST.assert_equals('credit is unapplied', 60,
                           PKG_BILLING.get_unapplied_credit(l_student));

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 15), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('booking succeeds on credit', 'OK', l_result);

    SELECT APPLIED_FLAG INTO l_applied FROM PAYMENTS WHERE PAYMENT_ID = l_payment;
    SELECT PAYMENT_ID   INTO l_linked  FROM SESSIONS WHERE SESSION_ID = l_session;
    PKG_TEST.assert_equals('payment is now applied', 'Y', l_applied);
    PKG_TEST.assert_equals('session links to the payment', l_payment, l_linked);
    PKG_TEST.assert_equals('no unapplied credit left', 0,
                           PKG_BILLING.get_unapplied_credit(l_student));

    -- No package was involved, so no hours moved.
    PKG_TEST.assert_equals('no ledger reservation', 0,
                           PKG_TEST.ledger_count(l_session, 'RESERVE'));

    PKG_SCHEDULING.cancel_session(l_session, l_result);
    PKG_TEST.assert_equals('cancel succeeds', 'OK', l_result);

    SELECT APPLIED_FLAG INTO l_applied FROM PAYMENTS WHERE PAYMENT_ID = l_payment;
    PKG_TEST.assert_equals('credit returned to the pool', 'N', l_applied);
    PKG_TEST.assert_equals('unapplied credit is back', 60,
                           PKG_BILLING.get_unapplied_credit(l_student));

    PKG_TEST.assert_ledger_consistent('pay per session');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('billing: package hours are preferred over cash credit');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_payment NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
  BEGIN
    l_student := PKG_TEST.new_student('Both Options');

    PKG_BILLING.purchase_package(l_student, 2, 100, 'ZELLE', NULL, l_package, l_result);
    PKG_BILLING.record_payment(l_student, 60, 'CASH', NULL, l_payment, l_result);

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 16), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('booking succeeds', 'OK', l_result);

    -- Prepaid hours are the thing the parent already bought; spend those
    -- before touching loose cash.
    PKG_TEST.assert_equals('hours were used', 1, PKG_BILLING.get_balance(l_student));
    PKG_TEST.assert_equals('cash credit untouched', 60,
                           PKG_BILLING.get_unapplied_credit(l_student));

    PKG_TEST.assert_ledger_consistent('preference order');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('billing: a comped package books but records no payment');

  PKG_TEST.reset_data;

  DECLARE
    l_student  NUMBER;
    l_package  NUMBER;
    l_session  NUMBER;
    l_result   VARCHAR2(40);
    l_payments NUMBER;
  BEGIN
    l_student := PKG_TEST.new_student('Comped Hours');

    -- Makeup hours after a lesson the tutor moved. PACKAGES.PRICE allows zero;
    -- PAYMENTS.AMOUNT does not, so no payment row may be written.
    PKG_BILLING.purchase_package(l_student, 2, 0, 'CASH', NULL, l_package, l_result);
    PKG_TEST.assert_equals('comped purchase succeeds', 'OK', l_result);
    PKG_TEST.assert_not_null('package created', l_package);
    PKG_TEST.assert_equals('hours are usable', 2, PKG_BILLING.get_balance(l_student));

    SELECT COUNT(*) INTO l_payments FROM PAYMENTS WHERE STUDENT_ID = l_student;
    PKG_TEST.assert_equals('no payment recorded for a free package', 0, l_payments);

    -- And the hours behave like any others.
    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 10), 60, NULL, 1,
                                l_session, l_result);
    PKG_TEST.assert_equals('comped hours are bookable', 'OK', l_result);
    PKG_TEST.assert_equals('balance drops normally', 1, PKG_BILLING.get_balance(l_student));

    -- A negative price is still nonsense.
    PKG_BILLING.purchase_package(l_student, 2, -5, 'CASH', NULL, l_package, l_result);
    PKG_TEST.assert_equals('negative amount rejected', 'ERR_INVALID_INPUT', l_result);

    PKG_TEST.assert_ledger_consistent('comped package');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('billing: expired packages are not spendable');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
  BEGIN
    l_student := PKG_TEST.new_student('Expired Package');

    PKG_BILLING.purchase_package(l_student, 5, 250, 'ZELLE',
                                 TRUNC(SYSDATE) - 1, l_package, l_result);
    PKG_TEST.assert_equals('purchase succeeds', 'OK', l_result);
    PKG_TEST.assert_equals('expired hours do not count', 0,
                           PKG_BILLING.get_balance(l_student));

    PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(3, 10), 60, NULL, 1, l_session, l_result);
    PKG_TEST.assert_equals('cannot book on expired hours', 'ERR_INSUFFICIENT_HOURS', l_result);

    COMMIT;
  END;
END;
/

SET FEEDBACK ON
