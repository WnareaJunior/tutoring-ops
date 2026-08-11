-- =============================================================================
-- 02_pkg_validation.sql -- PKG_VALIDATION
--
-- Shared vocabulary for the other packages: the result codes the API maps onto
-- HTTP status codes, the legal session status transitions, and the calendar
-- rules. Nothing here writes data.
--
-- Result codes are VARCHAR2 rather than numbers so a failed call is readable in
-- a log without a lookup table, and BOOLEAN never appears in a public signature
-- because ODP.NET cannot bind PL/SQL BOOLEAN.
-- =============================================================================

CREATE OR REPLACE PACKAGE PKG_VALIDATION AS

  -- --- session statuses -----------------------------------------------------
  c_status_requested       CONSTANT VARCHAR2(20) := 'REQUESTED';
  c_status_confirmed       CONSTANT VARCHAR2(20) := 'CONFIRMED';
  c_status_completed       CONSTANT VARCHAR2(20) := 'COMPLETED';
  c_status_cancelled       CONSTANT VARCHAR2(20) := 'CANCELLED';
  c_status_late_cancelled  CONSTANT VARCHAR2(20) := 'LATE_CANCELLED';

  -- --- result codes ---------------------------------------------------------
  c_ok                     CONSTANT VARCHAR2(40) := 'OK';
  c_err_invalid_input      CONSTANT VARCHAR2(40) := 'ERR_INVALID_INPUT';
  c_err_student_not_found  CONSTANT VARCHAR2(40) := 'ERR_STUDENT_NOT_FOUND';
  c_err_student_inactive   CONSTANT VARCHAR2(40) := 'ERR_STUDENT_INACTIVE';
  c_err_session_not_found  CONSTANT VARCHAR2(40) := 'ERR_SESSION_NOT_FOUND';
  c_err_package_not_found  CONSTANT VARCHAR2(40) := 'ERR_PACKAGE_NOT_FOUND';
  c_err_payment_not_found  CONSTANT VARCHAR2(40) := 'ERR_PAYMENT_NOT_FOUND';
  c_err_double_booked      CONSTANT VARCHAR2(40) := 'ERR_DOUBLE_BOOKED';
  c_err_outside_hours      CONSTANT VARCHAR2(40) := 'ERR_OUTSIDE_BUSINESS_HOURS';
  c_err_insufficient_hours CONSTANT VARCHAR2(40) := 'ERR_INSUFFICIENT_HOURS';
  c_err_invalid_transition CONSTANT VARCHAR2(40) := 'ERR_INVALID_TRANSITION';
  c_err_invalid_duration   CONSTANT VARCHAR2(40) := 'ERR_INVALID_DURATION';
  c_err_start_in_past      CONSTANT VARCHAR2(40) := 'ERR_START_IN_PAST';

  -- --- calendar policy ------------------------------------------------------
  -- Sessions may start no earlier than c_open_hour and must END by
  -- c_close_hour. Sunday is closed.
  c_open_hour              CONSTANT PLS_INTEGER := 8;
  c_close_hour             CONSTANT PLS_INTEGER := 21;

  -- Hours inside this many hours of the start time are forfeited on cancel.
  c_late_cancel_hours      CONSTANT PLS_INTEGER := 24;

  -- 'Y' when the transition is one the business allows. Notably COMPLETED and
  -- the two cancelled states are terminal: a completed session can never be
  -- walked back to cancelled, which is what stops "cancel it after the fact so
  -- I get my hour back" from ever being a supported operation.
  FUNCTION is_valid_transition (
    p_from_status IN VARCHAR2,
    p_to_status   IN VARCHAR2
  ) RETURN VARCHAR2 DETERMINISTIC;

  -- Same rule, shaped for callers that want a result code.
  PROCEDURE check_transition (
    p_from_status IN  VARCHAR2,
    p_to_status   IN  VARCHAR2,
    p_result      OUT VARCHAR2
  );

  -- c_ok, or the code explaining why this slot is not bookable.
  FUNCTION check_business_hours (
    p_start_time IN TIMESTAMP,
    p_duration   IN NUMBER
  ) RETURN VARCHAR2;

  FUNCTION check_duration (
    p_duration IN NUMBER
  ) RETURN VARCHAR2;

  -- Minutes -> hours, rounded to the 2dp the money and hours columns use.
  FUNCTION minutes_to_hours (
    p_minutes IN NUMBER
  ) RETURN NUMBER DETERMINISTIC;

  -- 'Y' when the cancellation lands inside the late window.
  FUNCTION is_late_cancellation (
    p_start_time IN TIMESTAMP
  ) RETURN VARCHAR2;

END PKG_VALIDATION;
/

CREATE OR REPLACE PACKAGE BODY PKG_VALIDATION AS

  FUNCTION is_valid_transition (
    p_from_status IN VARCHAR2,
    p_to_status   IN VARCHAR2
  ) RETURN VARCHAR2 DETERMINISTIC
  IS
  BEGIN
    IF p_from_status IS NULL OR p_to_status IS NULL THEN
      RETURN 'N';
    END IF;

    -- A no-op transition is not an error, but it is not a transition either.
    -- Callers treat it as illegal so that double-cancel is rejected loudly.
    RETURN CASE
             WHEN p_from_status = c_status_requested
              AND p_to_status IN (c_status_confirmed,
                                  c_status_cancelled,
                                  c_status_late_cancelled) THEN 'Y'
             WHEN p_from_status = c_status_confirmed
              AND p_to_status IN (c_status_completed,
                                  c_status_cancelled,
                                  c_status_late_cancelled) THEN 'Y'
             ELSE 'N'
           END;
  END is_valid_transition;


  PROCEDURE check_transition (
    p_from_status IN  VARCHAR2,
    p_to_status   IN  VARCHAR2,
    p_result      OUT VARCHAR2
  )
  IS
  BEGIN
    IF is_valid_transition(p_from_status, p_to_status) = 'Y' THEN
      p_result := c_ok;
    ELSE
      p_result := c_err_invalid_transition;
    END IF;
  END check_transition;


  FUNCTION check_duration (
    p_duration IN NUMBER
  ) RETURN VARCHAR2
  IS
  BEGIN
    IF p_duration IS NULL
       OR p_duration < 30
       OR p_duration > 300
       OR MOD(p_duration, 15) <> 0
    THEN
      RETURN c_err_invalid_duration;
    END IF;
    RETURN c_ok;
  END check_duration;


  FUNCTION check_business_hours (
    p_start_time IN TIMESTAMP,
    p_duration   IN NUMBER
  ) RETURN VARCHAR2
  IS
    l_day           VARCHAR2(3);
    l_start_minutes PLS_INTEGER;
    l_end_minutes   PLS_INTEGER;
    l_duration_code VARCHAR2(40);
  BEGIN
    IF p_start_time IS NULL THEN
      RETURN c_err_invalid_input;
    END IF;

    l_duration_code := check_duration(p_duration);
    IF l_duration_code <> c_ok THEN
      RETURN l_duration_code;
    END IF;

    -- Pin the language so this does not start failing on a Spanish-locale box.
    l_day := TO_CHAR(p_start_time, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH');
    IF l_day = 'SUN' THEN
      RETURN c_err_outside_hours;
    END IF;

    l_start_minutes := EXTRACT(HOUR   FROM p_start_time) * 60
                     + EXTRACT(MINUTE FROM p_start_time);
    l_end_minutes   := l_start_minutes + p_duration;

    -- The session must both start after opening and finish before closing, so
    -- a 19:00 three-hour block is rejected rather than silently running late.
    IF l_start_minutes < c_open_hour * 60
       OR l_end_minutes > c_close_hour * 60
    THEN
      RETURN c_err_outside_hours;
    END IF;

    RETURN c_ok;
  END check_business_hours;


  FUNCTION minutes_to_hours (
    p_minutes IN NUMBER
  ) RETURN NUMBER DETERMINISTIC
  IS
  BEGIN
    RETURN ROUND(p_minutes / 60, 2);
  END minutes_to_hours;


  FUNCTION is_late_cancellation (
    p_start_time IN TIMESTAMP
  ) RETURN VARCHAR2
  IS
  BEGIN
    -- Already started counts as late, which is the honest reading of the rule.
    IF p_start_time <= SYSTIMESTAMP + NUMTODSINTERVAL(c_late_cancel_hours, 'HOUR') THEN
      RETURN 'Y';
    END IF;
    RETURN 'N';
  END is_late_cancellation;

END PKG_VALIDATION;
/

SHOW ERRORS PACKAGE PKG_VALIDATION
SHOW ERRORS PACKAGE BODY PKG_VALIDATION
