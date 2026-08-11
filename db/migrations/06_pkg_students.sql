-- =============================================================================
-- 06_pkg_students.sql -- PKG_STUDENTS
--
-- Roster management plus the read queries the API exposes. Read paths return
-- SYS_REFCURSOR so the C# layer stays a thin mapper: it never assembles a
-- result set out of several round trips.
-- =============================================================================

CREATE OR REPLACE PACKAGE PKG_STUDENTS AS

  PROCEDURE create_student (
    p_full_name      IN  VARCHAR2,
    p_parent_contact IN  VARCHAR2,
    p_parent_phone   IN  VARCHAR2 DEFAULT NULL,
    p_language       IN  VARCHAR2 DEFAULT 'EN',
    p_student_id     OUT NUMBER,
    p_access_code    OUT VARCHAR2,
    p_result         OUT VARCHAR2
  );

  PROCEDURE set_active (
    p_student_id IN  NUMBER,
    p_is_active  IN  VARCHAR2,
    p_result     OUT VARCHAR2
  );

  PROCEDURE get_student (
    p_student_id IN  NUMBER,
    p_cursor     OUT SYS_REFCURSOR,
    p_result     OUT VARCHAR2
  );

  PROCEDURE list_students (
    p_active_only IN  VARCHAR2 DEFAULT 'Y',
    p_cursor      OUT SYS_REFCURSOR
  );

  -- Everything the parent status page and the Cosmos read model need, in three
  -- cursors off one call.
  PROCEDURE get_dashboard (
    p_student_id IN  NUMBER,
    p_summary    OUT SYS_REFCURSOR,
    p_sessions   OUT SYS_REFCURSOR,
    p_payments   OUT SYS_REFCURSOR,
    p_result     OUT VARCHAR2
  );

  -- Admin calendar: every session in a date range, across all students.
  PROCEDURE get_schedule (
    p_from_date IN  DATE,
    p_to_date   IN  DATE,
    p_tutor_id  IN  NUMBER DEFAULT 1,
    p_cursor    OUT SYS_REFCURSOR
  );

  -- The parent status page's "auth": a per-student code, not an identity
  -- system. Deliberately minimal -- see docs/design-decisions.md.
  PROCEDURE resolve_access_code (
    p_access_code IN  VARCHAR2,
    p_student_id  OUT NUMBER,
    p_result      OUT VARCHAR2
  );

END PKG_STUDENTS;
/

CREATE OR REPLACE PACKAGE BODY PKG_STUDENTS AS

  -- Short, unambiguous code for the parent page. Excludes characters that get
  -- misread over the phone (0/O, 1/I/L) because these get read aloud a lot.
  FUNCTION generate_access_code RETURN VARCHAR2
  IS
    c_alphabet CONSTANT VARCHAR2(40) := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    l_code     VARCHAR2(12) := '';
  BEGIN
    FOR i IN 1 .. 8 LOOP
      l_code := l_code || SUBSTR(c_alphabet,
                                 TRUNC(DBMS_RANDOM.VALUE(1, LENGTH(c_alphabet) + 1)),
                                 1);
    END LOOP;
    RETURN l_code;
  END generate_access_code;


  PROCEDURE create_student (
    p_full_name      IN  VARCHAR2,
    p_parent_contact IN  VARCHAR2,
    p_parent_phone   IN  VARCHAR2 DEFAULT NULL,
    p_language       IN  VARCHAR2 DEFAULT 'EN',
    p_student_id     OUT NUMBER,
    p_access_code    OUT VARCHAR2,
    p_result         OUT VARCHAR2
  )
  IS
    l_language STUDENTS.PREFERRED_LANGUAGE%TYPE;
  BEGIN
    p_student_id  := NULL;
    p_access_code := NULL;

    IF p_full_name IS NULL OR p_parent_contact IS NULL THEN
      p_result := PKG_VALIDATION.c_err_invalid_input;
      RETURN;
    END IF;

    l_language := UPPER(NVL(p_language, 'EN'));
    IF l_language NOT IN ('EN','ES') THEN
      p_result := PKG_VALIDATION.c_err_invalid_input;
      RETURN;
    END IF;

    -- The unique index on ACCESS_CODE is the arbiter; retry on the rare clash
    -- rather than pretending a random code can never collide.
    FOR attempt IN 1 .. 5 LOOP
      BEGIN
        p_access_code := generate_access_code();

        INSERT INTO STUDENTS (
          FULL_NAME, PARENT_CONTACT, PARENT_PHONE, PREFERRED_LANGUAGE,
          IS_ACTIVE, ACCESS_CODE
        ) VALUES (
          p_full_name, p_parent_contact, p_parent_phone, l_language,
          'Y', p_access_code
        )
        RETURNING STUDENT_ID INTO p_student_id;

        p_result := PKG_VALIDATION.c_ok;
        RETURN;
      EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
          NULL;  -- try another code
      END;
    END LOOP;

    RAISE_APPLICATION_ERROR(-20020,
      'PKG_STUDENTS.create_student: could not allocate a unique access code');
  EXCEPTION
    -- The CHECK on PARENT_CONTACT is the one a caller can realistically trip.
    WHEN OTHERS THEN
      IF SQLCODE = -2290 THEN
        p_result := PKG_VALIDATION.c_err_invalid_input;
      ELSE
        RAISE;
      END IF;
  END create_student;


  PROCEDURE set_active (
    p_student_id IN  NUMBER,
    p_is_active  IN  VARCHAR2,
    p_result     OUT VARCHAR2
  )
  IS
  BEGIN
    IF NVL(p_is_active, 'X') NOT IN ('Y','N') THEN
      p_result := PKG_VALIDATION.c_err_invalid_input;
      RETURN;
    END IF;

    UPDATE STUDENTS
       SET IS_ACTIVE  = p_is_active,
           UPDATED_AT = SYSTIMESTAMP
     WHERE STUDENT_ID = p_student_id;

    IF SQL%ROWCOUNT = 0 THEN
      p_result := PKG_VALIDATION.c_err_student_not_found;
    ELSE
      p_result := PKG_VALIDATION.c_ok;
    END IF;
  END set_active;


  PROCEDURE get_student (
    p_student_id IN  NUMBER,
    p_cursor     OUT SYS_REFCURSOR,
    p_result     OUT VARCHAR2
  )
  IS
    l_exists PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_exists
      FROM STUDENTS
     WHERE STUDENT_ID = p_student_id;

    IF l_exists = 0 THEN
      p_result := PKG_VALIDATION.c_err_student_not_found;
      RETURN;
    END IF;

    OPEN p_cursor FOR
      SELECT s.STUDENT_ID,
             s.FULL_NAME,
             s.PARENT_CONTACT,
             s.PARENT_PHONE,
             s.PREFERRED_LANGUAGE,
             s.IS_ACTIVE,
             s.ACCESS_CODE,
             s.CREATED_AT,
             PKG_BILLING.get_balance(s.STUDENT_ID)         AS HOURS_REMAINING,
             PKG_BILLING.get_unapplied_credit(s.STUDENT_ID) AS UNAPPLIED_CREDIT
        FROM STUDENTS s
       WHERE s.STUDENT_ID = p_student_id;

    p_result := PKG_VALIDATION.c_ok;
  END get_student;


  PROCEDURE list_students (
    p_active_only IN  VARCHAR2 DEFAULT 'Y',
    p_cursor      OUT SYS_REFCURSOR
  )
  IS
  BEGIN
    OPEN p_cursor FOR
      SELECT s.STUDENT_ID,
             s.FULL_NAME,
             s.PARENT_CONTACT,
             s.PREFERRED_LANGUAGE,
             s.IS_ACTIVE,
             PKG_BILLING.get_balance(s.STUDENT_ID) AS HOURS_REMAINING
        FROM STUDENTS s
       WHERE (NVL(p_active_only,'Y') = 'N' OR s.IS_ACTIVE = 'Y')
       ORDER BY s.FULL_NAME;
  END list_students;


  PROCEDURE get_dashboard (
    p_student_id IN  NUMBER,
    p_summary    OUT SYS_REFCURSOR,
    p_sessions   OUT SYS_REFCURSOR,
    p_payments   OUT SYS_REFCURSOR,
    p_result     OUT VARCHAR2
  )
  IS
    l_exists PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO l_exists
      FROM STUDENTS
     WHERE STUDENT_ID = p_student_id;

    IF l_exists = 0 THEN
      p_result := PKG_VALIDATION.c_err_student_not_found;
      RETURN;
    END IF;

    OPEN p_summary FOR
      SELECT s.STUDENT_ID,
             s.FULL_NAME,
             s.PARENT_CONTACT,
             s.PREFERRED_LANGUAGE,
             PKG_BILLING.get_balance(s.STUDENT_ID)          AS HOURS_REMAINING,
             PKG_BILLING.get_unapplied_credit(s.STUDENT_ID)  AS UNAPPLIED_CREDIT,
             (SELECT COUNT(*)
                FROM SESSIONS x
               WHERE x.STUDENT_ID = s.STUDENT_ID
                 AND x.STATUS = 'COMPLETED')                 AS SESSIONS_COMPLETED
        FROM STUDENTS s
       WHERE s.STUDENT_ID = p_student_id;

    OPEN p_sessions FOR
      SELECT SESSION_ID,
             START_TIME,
             END_TIME,
             DURATION_MINUTES,
             STATUS,
             NOTES
        FROM SESSIONS
       WHERE STUDENT_ID = p_student_id
         AND STATUS IN ('REQUESTED','CONFIRMED')
         AND START_TIME >= SYSTIMESTAMP
       ORDER BY START_TIME;

    OPEN p_payments FOR
      SELECT PAYMENT_ID,
             AMOUNT,
             METHOD,
             PAID_DATE,
             PACKAGE_ID,
             APPLIED_FLAG
        FROM PAYMENTS
       WHERE STUDENT_ID = p_student_id
       ORDER BY PAID_DATE DESC
       FETCH FIRST 10 ROWS ONLY;

    p_result := PKG_VALIDATION.c_ok;
  END get_dashboard;


  PROCEDURE get_schedule (
    p_from_date IN  DATE,
    p_to_date   IN  DATE,
    p_tutor_id  IN  NUMBER DEFAULT 1,
    p_cursor    OUT SYS_REFCURSOR
  )
  IS
  BEGIN
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
       WHERE se.TUTOR_ID   = NVL(p_tutor_id, 1)
         AND se.START_TIME >= CAST(p_from_date AS TIMESTAMP)
         -- Inclusive of the whole end day, which is what a week view means.
         AND se.START_TIME <  CAST(p_to_date AS TIMESTAMP) + INTERVAL '1' DAY
       ORDER BY se.START_TIME;
  END get_schedule;


  PROCEDURE resolve_access_code (
    p_access_code IN  VARCHAR2,
    p_student_id  OUT NUMBER,
    p_result      OUT VARCHAR2
  )
  IS
  BEGIN
    p_student_id := NULL;

    IF p_access_code IS NULL THEN
      p_result := PKG_VALIDATION.c_err_invalid_input;
      RETURN;
    END IF;

    SELECT STUDENT_ID
      INTO p_student_id
      FROM STUDENTS
     WHERE ACCESS_CODE = UPPER(TRIM(p_access_code))
       AND IS_ACTIVE   = 'Y';

    p_result := PKG_VALIDATION.c_ok;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result := PKG_VALIDATION.c_err_student_not_found;
  END resolve_access_code;

END PKG_STUDENTS;
/

SHOW ERRORS PACKAGE PKG_STUDENTS
SHOW ERRORS PACKAGE BODY PKG_STUDENTS
