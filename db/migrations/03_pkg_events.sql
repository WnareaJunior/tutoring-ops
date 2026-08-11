-- =============================================================================
-- 03_pkg_events.sql -- PKG_EVENTS
--
-- The only writer of EVENT_OUTBOX. Business procedures call it in the same
-- transaction as the state change they are recording, so an event exists if and
-- only if the change it describes was committed.
--
-- Payloads are assembled here rather than in the caller so every consumer sees
-- the same field names for the same concept. The API's outbox publisher copies
-- PAYLOAD to Service Bus verbatim and never reshapes it.
--
-- Timestamps are business-local wall clock, formatted ISO 8601 without an
-- offset. The whole business runs in one timezone; the day that stops being
-- true this is the place to add it.
-- =============================================================================

CREATE OR REPLACE PACKAGE PKG_EVENTS AS

  c_evt_session_booked        CONSTANT VARCHAR2(60) := 'SessionBooked';
  c_evt_session_cancelled     CONSTANT VARCHAR2(60) := 'SessionCancelled';
  c_evt_session_late_cancel   CONSTANT VARCHAR2(60) := 'SessionLateCancelled';
  c_evt_session_completed     CONSTANT VARCHAR2(60) := 'SessionCompleted';
  c_evt_session_reminder      CONSTANT VARCHAR2(60) := 'SessionReminderDue';
  c_evt_package_purchased     CONSTANT VARCHAR2(60) := 'PackagePurchased';
  c_evt_package_exhausted     CONSTANT VARCHAR2(60) := 'PackageExhausted';
  c_evt_payment_recorded      CONSTANT VARCHAR2(60) := 'PaymentRecorded';

  -- Builds the full session payload from current state and queues it.
  PROCEDURE enqueue_session_event (
    p_session_id IN NUMBER,
    p_event_type IN VARCHAR2
  );

  PROCEDURE enqueue_package_event (
    p_package_id IN NUMBER,
    p_event_type IN VARCHAR2
  );

  PROCEDURE enqueue_payment_event (
    p_payment_id IN NUMBER,
    p_event_type IN VARCHAR2
  );

  -- Escape hatch for callers with a payload of their own. Kept narrow on
  -- purpose -- if you reach for this twice, add a typed procedure instead.
  PROCEDURE enqueue_raw (
    p_event_type     IN VARCHAR2,
    p_aggregate_type IN VARCHAR2,
    p_aggregate_id   IN NUMBER,
    p_payload        IN CLOB
  );

END PKG_EVENTS;
/

CREATE OR REPLACE PACKAGE BODY PKG_EVENTS AS

  c_iso_format CONSTANT VARCHAR2(40) := 'YYYY-MM-DD"T"HH24:MI:SS';


  PROCEDURE enqueue_raw (
    p_event_type     IN VARCHAR2,
    p_aggregate_type IN VARCHAR2,
    p_aggregate_id   IN NUMBER,
    p_payload        IN CLOB
  )
  IS
  BEGIN
    INSERT INTO EVENT_OUTBOX (
      EVENT_TYPE, AGGREGATE_TYPE, AGGREGATE_ID, PAYLOAD
    ) VALUES (
      p_event_type, p_aggregate_type, p_aggregate_id, p_payload
    );
  END enqueue_raw;


  PROCEDURE enqueue_session_event (
    p_session_id IN NUMBER,
    p_event_type IN VARCHAR2
  )
  IS
    l_payload CLOB;
  BEGIN
    -- One query so the payload is a consistent snapshot of the row as it
    -- stands inside this transaction. hoursRemaining is the student's whole
    -- balance, which is what the billing consumer needs to refresh the
    -- dashboard without calling back into the database for it.
    SELECT JSON_OBJECT(
             'eventType'         VALUE p_event_type,
             'sessionId'         VALUE s.SESSION_ID,
             'studentId'         VALUE s.STUDENT_ID,
             'studentName'       VALUE st.FULL_NAME,
             'parentContact'     VALUE st.PARENT_CONTACT,
             'preferredLanguage' VALUE st.PREFERRED_LANGUAGE,
             'packageId'         VALUE s.PACKAGE_ID,
             'startTime'         VALUE TO_CHAR(s.START_TIME, c_iso_format),
             'endTime'           VALUE TO_CHAR(s.END_TIME,   c_iso_format),
             'durationMinutes'   VALUE s.DURATION_MINUTES,
             'status'            VALUE s.STATUS,
             'hoursReserved'     VALUE s.HOURS_RESERVED,
             'hoursRemaining'    VALUE NVL((SELECT SUM(p.HOURS_REMAINING)
                                              FROM PACKAGES p
                                             WHERE p.STUDENT_ID = s.STUDENT_ID
                                               AND p.STATUS = 'ACTIVE'), 0),
             'occurredAt'        VALUE TO_CHAR(SYSTIMESTAMP, c_iso_format)
             RETURNING CLOB)
      INTO l_payload
      FROM SESSIONS s
      JOIN STUDENTS st ON st.STUDENT_ID = s.STUDENT_ID
     WHERE s.SESSION_ID = p_session_id;

    enqueue_raw(p_event_type, 'SESSION', p_session_id, l_payload);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      -- Callers always pass a session they just wrote in this transaction, so
      -- this is a programming error rather than a business outcome.
      RAISE_APPLICATION_ERROR(-20001,
        'PKG_EVENTS.enqueue_session_event: session ' || p_session_id || ' not found');
  END enqueue_session_event;


  PROCEDURE enqueue_package_event (
    p_package_id IN NUMBER,
    p_event_type IN VARCHAR2
  )
  IS
    l_payload CLOB;
  BEGIN
    SELECT JSON_OBJECT(
             'eventType'         VALUE p_event_type,
             'packageId'         VALUE p.PACKAGE_ID,
             'studentId'         VALUE p.STUDENT_ID,
             'studentName'       VALUE st.FULL_NAME,
             'parentContact'     VALUE st.PARENT_CONTACT,
             'preferredLanguage' VALUE st.PREFERRED_LANGUAGE,
             'hoursPurchased'    VALUE p.HOURS_PURCHASED,
             'hoursRemaining'    VALUE p.HOURS_REMAINING,
             'price'             VALUE p.PRICE,
             'status'            VALUE p.STATUS,
             'purchasedDate'     VALUE TO_CHAR(p.PURCHASED_DATE, c_iso_format),
             'occurredAt'        VALUE TO_CHAR(SYSTIMESTAMP, c_iso_format)
             RETURNING CLOB)
      INTO l_payload
      FROM PACKAGES p
      JOIN STUDENTS st ON st.STUDENT_ID = p.STUDENT_ID
     WHERE p.PACKAGE_ID = p_package_id;

    enqueue_raw(p_event_type, 'PACKAGE', p_package_id, l_payload);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20002,
        'PKG_EVENTS.enqueue_package_event: package ' || p_package_id || ' not found');
  END enqueue_package_event;


  PROCEDURE enqueue_payment_event (
    p_payment_id IN NUMBER,
    p_event_type IN VARCHAR2
  )
  IS
    l_payload CLOB;
  BEGIN
    SELECT JSON_OBJECT(
             'eventType'         VALUE p_event_type,
             'paymentId'         VALUE pay.PAYMENT_ID,
             'studentId'         VALUE pay.STUDENT_ID,
             'studentName'       VALUE st.FULL_NAME,
             'parentContact'     VALUE st.PARENT_CONTACT,
             'preferredLanguage' VALUE st.PREFERRED_LANGUAGE,
             'packageId'         VALUE pay.PACKAGE_ID,
             'amount'            VALUE pay.AMOUNT,
             'method'            VALUE pay.METHOD,
             'appliedFlag'       VALUE pay.APPLIED_FLAG,
             'paidDate'          VALUE TO_CHAR(pay.PAID_DATE, c_iso_format),
             'occurredAt'        VALUE TO_CHAR(SYSTIMESTAMP, c_iso_format)
             RETURNING CLOB)
      INTO l_payload
      FROM PAYMENTS pay
      JOIN STUDENTS st ON st.STUDENT_ID = pay.STUDENT_ID
     WHERE pay.PAYMENT_ID = p_payment_id;

    enqueue_raw(p_event_type, 'PAYMENT', p_payment_id, l_payload);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20003,
        'PKG_EVENTS.enqueue_payment_event: payment ' || p_payment_id || ' not found');
  END enqueue_payment_event;

END PKG_EVENTS;
/

SHOW ERRORS PACKAGE PKG_EVENTS
SHOW ERRORS PACKAGE BODY PKG_EVENTS
