-- =============================================================================
-- 30_test_transitions.sql -- the status machine.
--
-- The rule worth protecting: COMPLETED is terminal. If a completed session
-- could be walked back to CANCELLED, every completed lesson would be
-- refundable after the fact and the hour accounting would mean nothing.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

BEGIN
  PKG_TEST.start_suite('transitions: the rule table');

  PKG_TEST.assert_equals('REQUESTED -> CONFIRMED',
    'Y', PKG_VALIDATION.is_valid_transition('REQUESTED', 'CONFIRMED'));
  PKG_TEST.assert_equals('REQUESTED -> CANCELLED',
    'Y', PKG_VALIDATION.is_valid_transition('REQUESTED', 'CANCELLED'));
  PKG_TEST.assert_equals('CONFIRMED -> COMPLETED',
    'Y', PKG_VALIDATION.is_valid_transition('CONFIRMED', 'COMPLETED'));
  PKG_TEST.assert_equals('CONFIRMED -> CANCELLED',
    'Y', PKG_VALIDATION.is_valid_transition('CONFIRMED', 'CANCELLED'));
  PKG_TEST.assert_equals('CONFIRMED -> LATE_CANCELLED',
    'Y', PKG_VALIDATION.is_valid_transition('CONFIRMED', 'LATE_CANCELLED'));

  PKG_TEST.assert_equals('COMPLETED -> CANCELLED is forbidden',
    'N', PKG_VALIDATION.is_valid_transition('COMPLETED', 'CANCELLED'));
  PKG_TEST.assert_equals('COMPLETED -> LATE_CANCELLED is forbidden',
    'N', PKG_VALIDATION.is_valid_transition('COMPLETED', 'LATE_CANCELLED'));
  PKG_TEST.assert_equals('CANCELLED -> COMPLETED is forbidden',
    'N', PKG_VALIDATION.is_valid_transition('CANCELLED', 'COMPLETED'));
  PKG_TEST.assert_equals('CANCELLED -> CANCELLED is forbidden',
    'N', PKG_VALIDATION.is_valid_transition('CANCELLED', 'CANCELLED'));
  PKG_TEST.assert_equals('REQUESTED -> COMPLETED skips confirmation',
    'N', PKG_VALIDATION.is_valid_transition('REQUESTED', 'COMPLETED'));
  PKG_TEST.assert_equals('null is not a status',
    'N', PKG_VALIDATION.is_valid_transition(NULL, 'CONFIRMED'));
END;
/

BEGIN
  PKG_TEST.start_suite('transitions: enforced end to end');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_session NUMBER;
    l_result  VARCHAR2(40);
    l_status  VARCHAR2(20);
  BEGIN
    l_student := PKG_TEST.new_student('Transition Student');
    PKG_BILLING.purchase_package(l_student, 10, 500, 'ZELLE', NULL, l_package, l_result);

    -- --- request -> confirm -> complete ------------------------------------
    PKG_SCHEDULING.request_session(l_student, PKG_TEST.slot(4, 10), 60,
                                   'parent asked', 1, l_session, l_result);
    PKG_TEST.assert_equals('request succeeds', 'OK', l_result);

    SELECT STATUS INTO l_status FROM SESSIONS WHERE SESSION_ID = l_session;
    PKG_TEST.assert_equals('status is REQUESTED', 'REQUESTED', l_status);

    -- A request holds the hours too. Offering a slot that cannot be paid for
    -- is worse than declining it.
    PKG_TEST.assert_equals('request reserves hours', 9, PKG_BILLING.get_balance(l_student));

    PKG_SCHEDULING.complete_session(l_session, l_result);
    PKG_TEST.assert_equals('cannot complete an unconfirmed session',
                           'ERR_INVALID_TRANSITION', l_result);

    PKG_SCHEDULING.confirm_session(l_session, l_result);
    PKG_TEST.assert_equals('confirm succeeds', 'OK', l_result);

    PKG_SCHEDULING.confirm_session(l_session, l_result);
    PKG_TEST.assert_equals('second confirm rejected', 'ERR_INVALID_TRANSITION', l_result);

    -- Confirming moved no hours; they were taken at request time.
    PKG_TEST.assert_equals('balance unchanged by confirm', 9,
                           PKG_BILLING.get_balance(l_student));

    PKG_SCHEDULING.complete_session(l_session, l_result);
    PKG_TEST.assert_equals('complete succeeds', 'OK', l_result);

    -- --- the one that matters ----------------------------------------------
    PKG_SCHEDULING.cancel_session(l_session, l_result);
    PKG_TEST.assert_equals('a completed session cannot be cancelled',
                           'ERR_INVALID_TRANSITION', l_result);
    PKG_TEST.assert_equals('no hours refunded', 9, PKG_BILLING.get_balance(l_student));
    PKG_TEST.assert_equals('no RELEASE row exists', 0,
                           PKG_TEST.ledger_count(l_session, 'RELEASE'));

    PKG_SCHEDULING.complete_session(l_session, l_result);
    PKG_TEST.assert_equals('re-completing rejected', 'ERR_INVALID_TRANSITION', l_result);

    PKG_SCHEDULING.cancel_session(-999, l_result);
    PKG_TEST.assert_equals('unknown session rejected', 'ERR_SESSION_NOT_FOUND', l_result);

    PKG_TEST.assert_ledger_consistent('transitions');
    COMMIT;
  END;
END;
/

BEGIN
  PKG_TEST.start_suite('transitions: cancelling a request frees the slot');

  PKG_TEST.reset_data;

  DECLARE
    l_student NUMBER;
    l_package NUMBER;
    l_first   NUMBER;
    l_second  NUMBER;
    l_result  VARCHAR2(40);
    l_start   TIMESTAMP := PKG_TEST.slot(5, 13);
  BEGIN
    l_student := PKG_TEST.new_student('Slot Holder');
    PKG_BILLING.purchase_package(l_student, 10, 500, 'ZELLE', NULL, l_package, l_result);

    PKG_SCHEDULING.request_session(l_student, l_start, 60, NULL, 1, l_first, l_result);
    PKG_TEST.assert_equals('request holds the slot', 'OK', l_result);

    PKG_SCHEDULING.book_session(l_student, l_start, 60, NULL, 1, l_second, l_result);
    PKG_TEST.assert_equals('cannot book over a request', 'ERR_DOUBLE_BOOKED', l_result);

    PKG_SCHEDULING.cancel_session(l_first, l_result);
    PKG_TEST.assert_equals('cancelling the request succeeds', 'OK', l_result);

    PKG_SCHEDULING.book_session(l_student, l_start, 60, NULL, 1, l_second, l_result);
    PKG_TEST.assert_equals('slot is bookable again', 'OK', l_result);

    PKG_TEST.assert_ledger_consistent('slot release');
    COMMIT;
  END;
END;
/

SET FEEDBACK ON
