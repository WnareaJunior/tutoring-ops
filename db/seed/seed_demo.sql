-- =============================================================================
-- seed_demo.sql -- a small, realistic dataset so the UI has something to show.
--
--   cd db && ./seed.sh
--
-- Everything goes through the packages, so the seed exercises the same rules a
-- real booking does. If the seed breaks, the business logic broke.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

DECLARE
  TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  l_students t_ids;
  l_package  NUMBER;
  l_payment  NUMBER;
  l_session  NUMBER;
  l_result   VARCHAR2(40);
  l_code     VARCHAR2(12);

  PROCEDURE check_ok (p_what IN VARCHAR2, p_result IN VARCHAR2) IS
  BEGIN
    IF p_result <> 'OK' THEN
      RAISE_APPLICATION_ERROR(-20700, p_what || ' failed: ' || p_result);
    END IF;
  END check_ok;

  -- Next occurrence of a weekday at a given hour, always in the future.
  FUNCTION slot (p_days IN PLS_INTEGER, p_hour IN PLS_INTEGER) RETURN TIMESTAMP IS
    l_date DATE := TRUNC(SYSDATE) + GREATEST(p_days, 1);
  BEGIN
    WHILE TO_CHAR(l_date, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH') = 'SUN' LOOP
      l_date := l_date + 1;
    END LOOP;
    RETURN CAST(l_date AS TIMESTAMP) + NUMTODSINTERVAL(p_hour * 60, 'MINUTE');
  END slot;
BEGIN
  -- Start from nothing so the seed is repeatable.
  DELETE FROM PACKAGE_LEDGER;
  DELETE FROM EVENT_OUTBOX;
  DELETE FROM SESSIONS;
  DELETE FROM PAYMENTS;
  DELETE FROM PACKAGES;
  DELETE FROM STUDENTS;

  -- --- roster ---------------------------------------------------------------
  PKG_STUDENTS.create_student('Maria Rodriguez', 'rodriguez.family@example.com',
                              '555-0101', 'ES', l_students(1), l_code, l_result);
  check_ok('create Maria', l_result);
  DBMS_OUTPUT.PUT_LINE('Maria Rodriguez   access code: ' || l_code);

  PKG_STUDENTS.create_student('James Chen', 'chen.parents@example.com',
                              '555-0102', 'EN', l_students(2), l_code, l_result);
  check_ok('create James', l_result);
  DBMS_OUTPUT.PUT_LINE('James Chen        access code: ' || l_code);

  PKG_STUDENTS.create_student('Aisha Okafor', 'okafor.home@example.com',
                              '555-0103', 'EN', l_students(3), l_code, l_result);
  check_ok('create Aisha', l_result);
  DBMS_OUTPUT.PUT_LINE('Aisha Okafor      access code: ' || l_code);

  PKG_STUDENTS.create_student('Diego Fernandez', 'fernandez.d@example.com',
                              '555-0104', 'ES', l_students(4), l_code, l_result);
  check_ok('create Diego', l_result);
  DBMS_OUTPUT.PUT_LINE('Diego Fernandez   access code: ' || l_code);

  -- --- packages -------------------------------------------------------------
  -- Maria is most of the way through a 20 hour block bought in the spring.
  PKG_BILLING.purchase_package(l_students(1), 20, 1200, 'ZELLE', NULL, l_package, l_result);
  check_ok('Maria package', l_result);
  UPDATE PACKAGES SET PURCHASED_DATE = SYSTIMESTAMP - INTERVAL '60' DAY
   WHERE PACKAGE_ID = l_package;

  -- James has a leftover single hour from an old block plus a fresh one, which
  -- is what makes the FIFO rule visible in the UI: his next lesson drains the
  -- old package before it touches the new one.
  PKG_BILLING.purchase_package(l_students(2), 1, 60, 'CARD', NULL, l_package, l_result);
  check_ok('James old package', l_result);
  UPDATE PACKAGES SET PURCHASED_DATE = SYSTIMESTAMP - INTERVAL '90' DAY
   WHERE PACKAGE_ID = l_package;

  PKG_BILLING.purchase_package(l_students(2), 12, 720, 'ZELLE', NULL, l_package, l_result);
  check_ok('James new package', l_result);

  -- Aisha pays per session.
  PKG_BILLING.record_payment(l_students(3), 75, 'VENMO', 'single lesson', l_payment, l_result);
  check_ok('Aisha payment', l_result);
  PKG_BILLING.record_payment(l_students(3), 75, 'VENMO', 'single lesson', l_payment, l_result);
  check_ok('Aisha payment 2', l_result);

  -- Diego has just bought his first block.
  PKG_BILLING.purchase_package(l_students(4), 8, 480, 'CASH', NULL, l_package, l_result);
  check_ok('Diego package', l_result);

  COMMIT;

  -- --- the week ahead -------------------------------------------------------
  PKG_SCHEDULING.book_session(l_students(1), slot(1, 16), 90, 'Reading comprehension',
                              1, l_session, l_result);
  check_ok('Maria Monday', l_result);

  PKG_SCHEDULING.book_session(l_students(2), slot(1, 18), 60, 'Math: functions',
                              1, l_session, l_result);
  check_ok('James Monday', l_result);

  PKG_SCHEDULING.book_session(l_students(3), slot(2, 17), 60, 'Full practice review',
                              1, l_session, l_result);
  check_ok('Aisha Tuesday', l_result);

  PKG_SCHEDULING.book_session(l_students(4), slot(2, 19), 90, 'Grammar and writing',
                              1, l_session, l_result);
  check_ok('Diego Tuesday', l_result);

  PKG_SCHEDULING.book_session(l_students(1), slot(4, 16), 90, 'Timed section',
                              1, l_session, l_result);
  check_ok('Maria Thursday', l_result);

  -- A parent-requested slot waiting on confirmation.
  PKG_SCHEDULING.request_session(l_students(2), slot(5, 18), 60, 'Parent requested',
                                 1, l_session, l_result);
  check_ok('James request', l_result);

  COMMIT;

  -- --- history so the dashboard is not empty --------------------------------
  -- Booked in the future, then walked backwards and completed, because the
  -- rules correctly refuse to book a lesson in the past.
  FOR i IN 1 .. 3 LOOP
    PKG_SCHEDULING.book_session(l_students(1), slot(30 + i, 16), 90, 'Past lesson',
                                1, l_session, l_result);
    check_ok('Maria history ' || i, l_result);

    UPDATE SESSIONS
       SET START_TIME = SYSTIMESTAMP - NUMTODSINTERVAL(7 * i, 'DAY')
     WHERE SESSION_ID = l_session;

    PKG_SCHEDULING.complete_session(l_session, l_result);
    check_ok('Maria history complete ' || i, l_result);
  END LOOP;

  COMMIT;

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('Seed complete.');
  DBMS_OUTPUT.PUT_LINE('  Maria balance: ' || PKG_BILLING.get_balance(l_students(1)));
  DBMS_OUTPUT.PUT_LINE('  James balance: ' || PKG_BILLING.get_balance(l_students(2)));
  DBMS_OUTPUT.PUT_LINE('  Aisha credit:  ' || PKG_BILLING.get_unapplied_credit(l_students(3)));
  DBMS_OUTPUT.PUT_LINE('  Diego balance: ' || PKG_BILLING.get_balance(l_students(4)));
  DBMS_OUTPUT.PUT_LINE('  Pending events: ' || PKG_OUTBOX.pending_count);
END;
/

exit
