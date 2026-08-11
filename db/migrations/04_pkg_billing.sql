-- =============================================================================
-- 04_pkg_billing.sql -- PKG_BILLING
--
-- Owns every movement of hours and money. PKG_SCHEDULING calls into this
-- package; nothing here calls back out to scheduling.
--
-- Locking discipline (the reason concurrent bookings and purchases cannot
-- corrupt a balance): every procedure that changes a student's hours takes
-- SELECT ... FOR UPDATE on that student's STUDENTS row first. All balance
-- mutations for one student therefore serialise on a single row. Callers that
-- also need the schedule lock take STUDENTS before TUTORS, always, so two
-- concurrent bookings can never deadlock against each other.
--
-- FIFO: hours come off the oldest usable package first. A booking that is
-- larger than the oldest package spills into the next one and writes a ledger
-- row per package, so a 1.5 hour session can legitimately be paid for out of
-- two packages at once.
-- =============================================================================

CREATE OR REPLACE PACKAGE PKG_BILLING AS

  -- Buys a block of hours and records the payment that paid for it.
  PROCEDURE purchase_package (
    p_student_id IN  NUMBER,
    p_hours      IN  NUMBER,
    p_amount     IN  NUMBER,
    p_method     IN  VARCHAR2 DEFAULT 'ZELLE',
    p_expires_on IN  DATE     DEFAULT NULL,
    p_package_id OUT NUMBER,
    p_result     OUT VARCHAR2
  );

  -- Money in from a pay-per-session student, not attached to a package. Sits
  -- unapplied until a booking claims it.
  PROCEDURE record_payment (
    p_student_id IN  NUMBER,
    p_amount     IN  NUMBER,
    p_method     IN  VARCHAR2 DEFAULT 'ZELLE',
    p_notes      IN  VARCHAR2 DEFAULT NULL,
    p_payment_id OUT NUMBER,
    p_result     OUT VARCHAR2
  );

  -- Hours left across all usable packages.
  FUNCTION get_balance (
    p_student_id IN NUMBER
  ) RETURN NUMBER;

  -- Money paid but not yet spoken for by a package or a session.
  FUNCTION get_unapplied_credit (
    p_student_id IN NUMBER
  ) RETURN NUMBER;

  -- Takes p_hours off the student's packages, oldest first, and records the
  -- movement against p_session_id. p_package_id returns the first package
  -- touched, which is what SESSIONS.PACKAGE_ID displays.
  PROCEDURE reserve_hours (
    p_student_id IN  NUMBER,
    p_session_id IN  NUMBER,
    p_hours      IN  NUMBER,
    p_package_id OUT NUMBER,
    p_result     OUT VARCHAR2
  );

  -- Puts back exactly what this session reserved, once. Safe to call twice;
  -- the second call is a no-op rather than a second credit.
  PROCEDURE release_hours (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  );

  -- Claims the oldest unapplied payment for a pay-per-session booking.
  PROCEDURE apply_payment (
    p_student_id IN  NUMBER,
    p_session_id IN  NUMBER,
    p_payment_id OUT NUMBER,
    p_result     OUT VARCHAR2
  );

  -- Returns a claimed payment to the unapplied pool on an on-time cancel.
  PROCEDURE release_payment (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  );

END PKG_BILLING;
/

CREATE OR REPLACE PACKAGE BODY PKG_BILLING AS

  -- Serialises everything that touches this student's money or hours.
  -- Re-taking a lock already held by this transaction is free, so procedures
  -- call it defensively even when their caller has already done so.
  PROCEDURE lock_student (
    p_student_id IN  NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    l_is_active STUDENTS.IS_ACTIVE%TYPE;
  BEGIN
    SELECT IS_ACTIVE
      INTO l_is_active
      FROM STUDENTS
     WHERE STUDENT_ID = p_student_id
       FOR UPDATE;

    IF l_is_active = 'N' THEN
      p_result := PKG_VALIDATION.c_err_student_inactive;
    ELSE
      p_result := PKG_VALIDATION.c_ok;
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result := PKG_VALIDATION.c_err_student_not_found;
  END lock_student;


  -- A package with nothing left is EXHAUSTED; one that gets hours back is
  -- ACTIVE again. Kept in one place so the two callers cannot disagree.
  PROCEDURE refresh_package_status (
    p_package_id IN NUMBER
  )
  IS
    l_hours_remaining PACKAGES.HOURS_REMAINING%TYPE;
    l_old_status      PACKAGES.STATUS%TYPE;
    l_new_status      PACKAGES.STATUS%TYPE;
  BEGIN
    SELECT HOURS_REMAINING, STATUS
      INTO l_hours_remaining, l_old_status
      FROM PACKAGES
     WHERE PACKAGE_ID = p_package_id;

    -- A refunded or expired package is not something a balance change revives.
    IF l_old_status IN ('REFUNDED','EXPIRED') THEN
      RETURN;
    END IF;

    l_new_status := CASE WHEN l_hours_remaining <= 0 THEN 'EXHAUSTED' ELSE 'ACTIVE' END;

    IF l_new_status <> l_old_status THEN
      UPDATE PACKAGES
         SET STATUS     = l_new_status,
             UPDATED_AT = SYSTIMESTAMP
       WHERE PACKAGE_ID = p_package_id;

      -- The hook the Event Grid stretch goal hangs off: the moment a student
      -- runs out is the moment to sell the next package.
      IF l_new_status = 'EXHAUSTED' THEN
        PKG_EVENTS.enqueue_package_event(p_package_id, PKG_EVENTS.c_evt_package_exhausted);
      END IF;
    END IF;
  END refresh_package_status;


  FUNCTION get_balance (
    p_student_id IN NUMBER
  ) RETURN NUMBER
  IS
    l_hours NUMBER;
  BEGIN
    SELECT NVL(SUM(HOURS_REMAINING), 0)
      INTO l_hours
      FROM PACKAGES
     WHERE STUDENT_ID = p_student_id
       AND STATUS     = 'ACTIVE'
       AND (EXPIRES_ON IS NULL OR EXPIRES_ON >= TRUNC(SYSDATE));

    RETURN l_hours;
  END get_balance;


  FUNCTION get_unapplied_credit (
    p_student_id IN NUMBER
  ) RETURN NUMBER
  IS
    l_amount NUMBER;
  BEGIN
    SELECT NVL(SUM(AMOUNT), 0)
      INTO l_amount
      FROM PAYMENTS
     WHERE STUDENT_ID   = p_student_id
       AND APPLIED_FLAG = 'N';

    RETURN l_amount;
  END get_unapplied_credit;


  PROCEDURE purchase_package (
    p_student_id IN  NUMBER,
    p_hours      IN  NUMBER,
    p_amount     IN  NUMBER,
    p_method     IN  VARCHAR2 DEFAULT 'ZELLE',
    p_expires_on IN  DATE     DEFAULT NULL,
    p_package_id OUT NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    l_payment_id PAYMENTS.PAYMENT_ID%TYPE;
  BEGIN
    p_package_id := NULL;

    IF p_hours IS NULL OR p_hours <= 0 OR p_amount IS NULL OR p_amount < 0 THEN
      p_result := PKG_VALIDATION.c_err_invalid_input;
      RETURN;
    END IF;

    lock_student(p_student_id, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    INSERT INTO PACKAGES (
      STUDENT_ID, HOURS_PURCHASED, HOURS_REMAINING, PRICE, EXPIRES_ON, STATUS
    ) VALUES (
      p_student_id, p_hours, p_hours, p_amount, p_expires_on, 'ACTIVE'
    )
    RETURNING PACKAGE_ID INTO p_package_id;

    -- Balance and ledger move together, always.
    INSERT INTO PACKAGE_LEDGER (PACKAGE_ID, SESSION_ID, ENTRY_TYPE, HOURS_DELTA)
    VALUES (p_package_id, NULL, 'PURCHASE', p_hours);

    INSERT INTO PAYMENTS (
      STUDENT_ID, PACKAGE_ID, AMOUNT, METHOD, APPLIED_FLAG, NOTES
    ) VALUES (
      p_student_id, p_package_id, p_amount, NVL(p_method,'ZELLE'), 'Y',
      'Package purchase: ' || p_hours || ' hours'
    )
    RETURNING PAYMENT_ID INTO l_payment_id;

    PKG_EVENTS.enqueue_package_event(p_package_id, PKG_EVENTS.c_evt_package_purchased);

    p_result := PKG_VALIDATION.c_ok;
  END purchase_package;


  PROCEDURE record_payment (
    p_student_id IN  NUMBER,
    p_amount     IN  NUMBER,
    p_method     IN  VARCHAR2 DEFAULT 'ZELLE',
    p_notes      IN  VARCHAR2 DEFAULT NULL,
    p_payment_id OUT NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
  BEGIN
    p_payment_id := NULL;

    IF p_amount IS NULL OR p_amount <= 0 THEN
      p_result := PKG_VALIDATION.c_err_invalid_input;
      RETURN;
    END IF;

    lock_student(p_student_id, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    INSERT INTO PAYMENTS (
      STUDENT_ID, PACKAGE_ID, AMOUNT, METHOD, APPLIED_FLAG, NOTES
    ) VALUES (
      p_student_id, NULL, p_amount, NVL(p_method,'ZELLE'), 'N', p_notes
    )
    RETURNING PAYMENT_ID INTO p_payment_id;

    PKG_EVENTS.enqueue_payment_event(p_payment_id, PKG_EVENTS.c_evt_payment_recorded);

    p_result := PKG_VALIDATION.c_ok;
  END record_payment;


  PROCEDURE reserve_hours (
    p_student_id IN  NUMBER,
    p_session_id IN  NUMBER,
    p_hours      IN  NUMBER,
    p_package_id OUT NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    -- FOR UPDATE holds every candidate package for the life of the
    -- transaction, so the balance checked below is the balance spent.
    CURSOR c_packages IS
      SELECT PACKAGE_ID, HOURS_REMAINING
        FROM PACKAGES
       WHERE STUDENT_ID = p_student_id
         AND STATUS     = 'ACTIVE'
         AND HOURS_REMAINING > 0
         AND (EXPIRES_ON IS NULL OR EXPIRES_ON >= TRUNC(SYSDATE))
       ORDER BY PURCHASED_DATE, PACKAGE_ID
         FOR UPDATE;

    l_outstanding NUMBER := p_hours;
    l_take        NUMBER;
    l_available   NUMBER;
  BEGIN
    p_package_id := NULL;

    IF p_hours IS NULL OR p_hours <= 0 THEN
      p_result := PKG_VALIDATION.c_err_invalid_input;
      RETURN;
    END IF;

    lock_student(p_student_id, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    -- Check the whole balance before spending any of it, so a booking that
    -- cannot be covered leaves no half-applied reservations behind.
    l_available := get_balance(p_student_id);
    IF l_available < p_hours THEN
      p_result := PKG_VALIDATION.c_err_insufficient_hours;
      RETURN;
    END IF;

    FOR r IN c_packages LOOP
      EXIT WHEN l_outstanding <= 0;

      l_take := LEAST(r.HOURS_REMAINING, l_outstanding);

      UPDATE PACKAGES
         SET HOURS_REMAINING = HOURS_REMAINING - l_take,
             UPDATED_AT      = SYSTIMESTAMP
       WHERE PACKAGE_ID = r.PACKAGE_ID;

      -- Unique index on (SESSION_ID, PACKAGE_ID, ENTRY_TYPE) means a repeated
      -- reservation for the same session raises instead of double-spending.
      INSERT INTO PACKAGE_LEDGER (PACKAGE_ID, SESSION_ID, ENTRY_TYPE, HOURS_DELTA)
      VALUES (r.PACKAGE_ID, p_session_id, 'RESERVE', -l_take);

      IF p_package_id IS NULL THEN
        p_package_id := r.PACKAGE_ID;
      END IF;

      l_outstanding := l_outstanding - l_take;

      refresh_package_status(r.PACKAGE_ID);
    END LOOP;

    -- get_balance said there was enough and we held the rows throughout, so
    -- this cannot fire. It is here because a silent under-reservation would be
    -- the one bug in this system nobody would notice for months.
    IF l_outstanding > 0 THEN
      RAISE_APPLICATION_ERROR(-20010,
        'PKG_BILLING.reserve_hours: balance check passed but ' || l_outstanding ||
        ' hours could not be reserved for student ' || p_student_id);
    END IF;

    p_result := PKG_VALIDATION.c_ok;
  END reserve_hours;


  PROCEDURE release_hours (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    -- Only reservations with no matching release. This predicate is what makes
    -- the procedure idempotent; the unique index is what makes it provable.
    CURSOR c_reserved IS
      SELECT l.PACKAGE_ID, l.HOURS_DELTA
        FROM PACKAGE_LEDGER l
       WHERE l.SESSION_ID = p_session_id
         AND l.ENTRY_TYPE = 'RESERVE'
         AND NOT EXISTS (
               SELECT 1
                 FROM PACKAGE_LEDGER r
                WHERE r.SESSION_ID = l.SESSION_ID
                  AND r.PACKAGE_ID = l.PACKAGE_ID
                  AND r.ENTRY_TYPE = 'RELEASE');

    l_student_id SESSIONS.STUDENT_ID%TYPE;
  BEGIN
    SELECT STUDENT_ID
      INTO l_student_id
      FROM SESSIONS
     WHERE SESSION_ID = p_session_id;

    lock_student(l_student_id, p_result);
    -- An inactive student can still have a session cancelled and refunded;
    -- only a missing student is a genuine failure here.
    IF p_result = PKG_VALIDATION.c_err_student_not_found THEN
      RETURN;
    END IF;

    FOR r IN c_reserved LOOP
      -- HOURS_DELTA on a RESERVE row is negative, so negating it gives back
      -- exactly what was taken -- not a recomputed figure that could drift.
      UPDATE PACKAGES
         SET HOURS_REMAINING = HOURS_REMAINING + (-r.HOURS_DELTA),
             UPDATED_AT      = SYSTIMESTAMP
       WHERE PACKAGE_ID = r.PACKAGE_ID;

      INSERT INTO PACKAGE_LEDGER (PACKAGE_ID, SESSION_ID, ENTRY_TYPE, HOURS_DELTA)
      VALUES (r.PACKAGE_ID, p_session_id, 'RELEASE', -r.HOURS_DELTA);

      refresh_package_status(r.PACKAGE_ID);
    END LOOP;

    p_result := PKG_VALIDATION.c_ok;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result := PKG_VALIDATION.c_err_session_not_found;
  END release_hours;


  PROCEDURE apply_payment (
    p_student_id IN  NUMBER,
    p_session_id IN  NUMBER,
    p_payment_id OUT NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    CURSOR c_credit IS
      SELECT PAYMENT_ID
        FROM PAYMENTS
       WHERE STUDENT_ID   = p_student_id
         AND APPLIED_FLAG = 'N'
       ORDER BY PAID_DATE, PAYMENT_ID
         FOR UPDATE;
  BEGIN
    p_payment_id := NULL;

    lock_student(p_student_id, p_result);
    IF p_result <> PKG_VALIDATION.c_ok THEN
      RETURN;
    END IF;

    -- Oldest credit first, same FIFO reasoning as the packages.
    OPEN c_credit;
    FETCH c_credit INTO p_payment_id;
    IF c_credit%NOTFOUND THEN
      CLOSE c_credit;
      p_result := PKG_VALIDATION.c_err_insufficient_hours;
      RETURN;
    END IF;
    CLOSE c_credit;

    UPDATE PAYMENTS
       SET APPLIED_FLAG = 'Y'
     WHERE PAYMENT_ID = p_payment_id;

    UPDATE SESSIONS
       SET PAYMENT_ID = p_payment_id,
           UPDATED_AT = SYSTIMESTAMP
     WHERE SESSION_ID = p_session_id;

    p_result := PKG_VALIDATION.c_ok;
  END apply_payment;


  PROCEDURE release_payment (
    p_session_id IN  NUMBER,
    p_result     OUT VARCHAR2
  )
  IS
    l_payment_id SESSIONS.PAYMENT_ID%TYPE;
    l_student_id SESSIONS.STUDENT_ID%TYPE;
  BEGIN
    SELECT PAYMENT_ID, STUDENT_ID
      INTO l_payment_id, l_student_id
      FROM SESSIONS
     WHERE SESSION_ID = p_session_id;

    IF l_payment_id IS NULL THEN
      -- Package booking, nothing to hand back here.
      p_result := PKG_VALIDATION.c_ok;
      RETURN;
    END IF;

    lock_student(l_student_id, p_result);
    IF p_result = PKG_VALIDATION.c_err_student_not_found THEN
      RETURN;
    END IF;

    UPDATE PAYMENTS
       SET APPLIED_FLAG = 'N'
     WHERE PAYMENT_ID = l_payment_id;

    UPDATE SESSIONS
       SET PAYMENT_ID = NULL,
           UPDATED_AT = SYSTIMESTAMP
     WHERE SESSION_ID = p_session_id;

    p_result := PKG_VALIDATION.c_ok;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result := PKG_VALIDATION.c_err_session_not_found;
  END release_payment;

END PKG_BILLING;
/

SHOW ERRORS PACKAGE PKG_BILLING
SHOW ERRORS PACKAGE BODY PKG_BILLING
