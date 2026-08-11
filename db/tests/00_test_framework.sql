-- =============================================================================
-- 00_test_framework.sql -- PKG_TEST
--
-- A small assertion harness so the test scripts read as assertions rather than
-- as SELECTs a human has to eyeball. Deliberately not utPLSQL: one fewer thing
-- to install on a fresh box, and the whole harness fits on a screen.
--
-- PKG_TEST.summary raises when anything failed, so a runner script with
-- WHENEVER SQLERROR EXIT FAILURE exits non-zero and CI notices.
-- =============================================================================

CREATE OR REPLACE PACKAGE PKG_TEST AS

  g_passed  PLS_INTEGER := 0;
  g_failed  PLS_INTEGER := 0;

  PROCEDURE reset;
  PROCEDURE start_suite (p_name IN VARCHAR2);

  PROCEDURE assert_equals (p_label IN VARCHAR2, p_expected IN NUMBER,   p_actual IN NUMBER);
  PROCEDURE assert_equals (p_label IN VARCHAR2, p_expected IN VARCHAR2, p_actual IN VARCHAR2);
  PROCEDURE assert_not_null (p_label IN VARCHAR2, p_actual IN NUMBER);
  PROCEDURE assert_null     (p_label IN VARCHAR2, p_actual IN NUMBER);

  PROCEDURE summary;

  -- --- fixtures -------------------------------------------------------------

  -- Wipes every transactional table. Tutors survive; they are reference data.
  PROCEDURE reset_data;

  FUNCTION new_student (
    p_name     IN VARCHAR2 DEFAULT 'Test Student',
    p_language IN VARCHAR2 DEFAULT 'EN'
  ) RETURN NUMBER;

  -- A bookable slot p_days_ahead from today at p_hour, skipping Sunday.
  FUNCTION slot (
    p_days_ahead IN PLS_INTEGER,
    p_hour       IN PLS_INTEGER DEFAULT 10
  ) RETURN TIMESTAMP;

  -- The invariant that must hold after every single test: for every package,
  -- the materialised balance equals the sum of its ledger entries, and no
  -- balance is negative. If a test can break this, the schema is wrong.
  PROCEDURE assert_ledger_consistent (p_label IN VARCHAR2 DEFAULT 'ledger');

  -- Count of ledger rows of a given type for a session -- the direct way to
  -- prove hours were restored exactly once.
  FUNCTION ledger_count (
    p_session_id IN NUMBER,
    p_entry_type IN VARCHAR2
  ) RETURN NUMBER;

  FUNCTION outbox_count (
    p_event_type IN VARCHAR2 DEFAULT NULL
  ) RETURN NUMBER;

END PKG_TEST;
/

CREATE OR REPLACE PACKAGE BODY PKG_TEST AS

  PROCEDURE reset
  IS
  BEGIN
    g_passed := 0;
    g_failed := 0;
  END reset;


  PROCEDURE start_suite (p_name IN VARCHAR2)
  IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== ' || p_name || ' ===');
  END start_suite;


  PROCEDURE pass (p_label IN VARCHAR2)
  IS
  BEGIN
    g_passed := g_passed + 1;
    DBMS_OUTPUT.PUT_LINE('  PASS  ' || p_label);
  END pass;


  PROCEDURE fail (p_label IN VARCHAR2, p_expected IN VARCHAR2, p_actual IN VARCHAR2)
  IS
  BEGIN
    g_failed := g_failed + 1;
    DBMS_OUTPUT.PUT_LINE('  FAIL  ' || p_label ||
                         ' | expected [' || NVL(p_expected, '<null>') ||
                         '] actual [' || NVL(p_actual, '<null>') || ']');
  END fail;


  PROCEDURE assert_equals (p_label IN VARCHAR2, p_expected IN NUMBER, p_actual IN NUMBER)
  IS
  BEGIN
    -- Nulls compare equal here; a null-vs-null assertion is a pass, not a trap.
    IF (p_expected IS NULL AND p_actual IS NULL)
       OR (p_expected = p_actual)
    THEN
      pass(p_label);
    ELSE
      fail(p_label, TO_CHAR(p_expected), TO_CHAR(p_actual));
    END IF;
  END assert_equals;


  PROCEDURE assert_equals (p_label IN VARCHAR2, p_expected IN VARCHAR2, p_actual IN VARCHAR2)
  IS
  BEGIN
    IF (p_expected IS NULL AND p_actual IS NULL)
       OR (p_expected = p_actual)
    THEN
      pass(p_label);
    ELSE
      fail(p_label, p_expected, p_actual);
    END IF;
  END assert_equals;


  PROCEDURE assert_not_null (p_label IN VARCHAR2, p_actual IN NUMBER)
  IS
  BEGIN
    IF p_actual IS NULL THEN
      fail(p_label, 'not null', '<null>');
    ELSE
      pass(p_label);
    END IF;
  END assert_not_null;


  PROCEDURE assert_null (p_label IN VARCHAR2, p_actual IN NUMBER)
  IS
  BEGIN
    IF p_actual IS NULL THEN
      pass(p_label);
    ELSE
      fail(p_label, '<null>', TO_CHAR(p_actual));
    END IF;
  END assert_null;


  PROCEDURE summary
  IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-----------------------------------------');
    DBMS_OUTPUT.PUT_LINE('  passed: ' || g_passed || '   failed: ' || g_failed);
    DBMS_OUTPUT.PUT_LINE('-----------------------------------------');

    IF g_failed > 0 THEN
      RAISE_APPLICATION_ERROR(-20900, g_failed || ' assertion(s) failed');
    END IF;
  END summary;


  PROCEDURE reset_data
  IS
  BEGIN
    -- Reverse dependency order: ledger, then sessions (which point at payments
    -- and packages), then payments, then packages, then students.
    DELETE FROM PACKAGE_LEDGER;
    DELETE FROM EVENT_OUTBOX;
    DELETE FROM SESSIONS;
    DELETE FROM PAYMENTS;
    DELETE FROM PACKAGES;
    DELETE FROM STUDENTS;
    COMMIT;
  END reset_data;


  FUNCTION new_student (
    p_name     IN VARCHAR2 DEFAULT 'Test Student',
    p_language IN VARCHAR2 DEFAULT 'EN'
  ) RETURN NUMBER
  IS
    l_student_id  NUMBER;
    l_access_code VARCHAR2(12);
    l_result      VARCHAR2(40);
  BEGIN
    PKG_STUDENTS.create_student(
      p_full_name      => p_name,
      p_parent_contact => 'parent@example.com',
      p_parent_phone   => NULL,
      p_language       => p_language,
      p_student_id     => l_student_id,
      p_access_code    => l_access_code,
      p_result         => l_result);

    IF l_result <> PKG_VALIDATION.c_ok THEN
      RAISE_APPLICATION_ERROR(-20901, 'fixture new_student failed: ' || l_result);
    END IF;

    RETURN l_student_id;
  END new_student;


  FUNCTION slot (
    p_days_ahead IN PLS_INTEGER,
    p_hour       IN PLS_INTEGER DEFAULT 10
  ) RETURN TIMESTAMP
  IS
    l_date DATE := TRUNC(SYSDATE) + GREATEST(p_days_ahead, 1);
  BEGIN
    -- Sunday is closed, so slide forward rather than produce a slot the
    -- business rules will reject for a reason the test did not intend.
    WHILE TO_CHAR(l_date, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH') = 'SUN' LOOP
      l_date := l_date + 1;
    END LOOP;

    RETURN CAST(l_date AS TIMESTAMP) + NUMTODSINTERVAL(p_hour * 60, 'MINUTE');
  END slot;


  PROCEDURE assert_ledger_consistent (p_label IN VARCHAR2 DEFAULT 'ledger')
  IS
    l_mismatches PLS_INTEGER;
    l_negative   PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_mismatches
      FROM PACKAGES p
     WHERE p.HOURS_REMAINING <> (
             SELECT NVL(SUM(l.HOURS_DELTA), 0)
               FROM PACKAGE_LEDGER l
              WHERE l.PACKAGE_ID = p.PACKAGE_ID);

    assert_equals(p_label || ': balance equals ledger sum', 0, l_mismatches);

    SELECT COUNT(*)
      INTO l_negative
      FROM PACKAGES
     WHERE HOURS_REMAINING < 0;

    assert_equals(p_label || ': no negative balances', 0, l_negative);
  END assert_ledger_consistent;


  FUNCTION ledger_count (
    p_session_id IN NUMBER,
    p_entry_type IN VARCHAR2
  ) RETURN NUMBER
  IS
    l_count NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO l_count
      FROM PACKAGE_LEDGER
     WHERE SESSION_ID = p_session_id
       AND ENTRY_TYPE = p_entry_type;

    RETURN l_count;
  END ledger_count;


  FUNCTION outbox_count (
    p_event_type IN VARCHAR2 DEFAULT NULL
  ) RETURN NUMBER
  IS
    l_count NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO l_count
      FROM EVENT_OUTBOX
     WHERE p_event_type IS NULL OR EVENT_TYPE = p_event_type;

    RETURN l_count;
  END outbox_count;

END PKG_TEST;
/

SHOW ERRORS PACKAGE PKG_TEST
SHOW ERRORS PACKAGE BODY PKG_TEST
