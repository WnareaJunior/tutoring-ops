#!/usr/bin/env bash
# =============================================================================
# The consistency edge case, run for real.
#
# 40_test_consistency.sql proves the rules hold against a caller that gets them
# wrong. This script proves they hold against callers that get them wrong *at
# the same time*, which is the only version an interviewer actually cares about.
#
# Three races, each run from independent sqlplus sessions:
#
#   A  Six transactions cancel the same session while four buy packages.
#      Asserts: exactly one cancellation, exactly one RELEASE ledger row, and a
#      balance that accounts for every purchase. This is the checklist's
#      "cancelled inside the window while a package purchase is mid-flight".
#
#   B  Six transactions each book a different slot against a two-hour balance.
#      Asserts: exactly two succeed, balance lands on zero, never negative.
#
#   C  Six transactions book the identical slot.
#      Asserts: exactly one wins.
#
# Exits non-zero on any failed assertion.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

RACERS="${RACERS:-6}"
BUYERS="${BUYERS:-4}"

# Each racer's sqlplus output is kept, not discarded: when a race goes wrong
# the racers' own errors are the only evidence of why.
RACE_OUT="$(mktemp -d /tmp/tutoring-race.XXXXXX)"
echo "racer session logs: $RACE_OUT"

db_wait_for_ready 12

echo "--- installing the assertion harness"
db_script tests/00_test_framework.sql

# -----------------------------------------------------------------------------
# Race A: concurrent cancellation of one session, alongside concurrent purchases
# -----------------------------------------------------------------------------
echo
echo "=== Race A: $RACERS cancels + $BUYERS purchases, all at once"

db_exec >/dev/null <<'SQL'
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE RACE_LOG PURGE';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

CREATE TABLE RACE_LOG (
  PHASE   VARCHAR2(1),
  RACER   NUMBER,
  ACTION  VARCHAR2(20),
  RESULT  VARCHAR2(40),
  LOGGED_AT TIMESTAMP DEFAULT SYSTIMESTAMP
);

BEGIN
  PKG_TEST.reset_data;
END;
/

DECLARE
  l_student NUMBER;
  l_package NUMBER;
  l_session NUMBER;
  l_result  VARCHAR2(40);
BEGIN
  l_student := PKG_TEST.new_student('Race Student');
  PKG_BILLING.purchase_package(l_student, 3, 150, 'ZELLE', NULL, l_package, l_result);
  PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(7, 10), 60, NULL, 1,
                              l_session, l_result);
  IF l_result <> 'OK' THEN
    RAISE_APPLICATION_ERROR(-20800, 'race setup failed: ' || l_result);
  END IF;
  COMMIT;
END;
/
exit
SQL

pids=()

for ((i = 1; i <= RACERS; i++)); do
  db_exec >"$RACE_OUT/A-cancel-$i.log" 2>&1 <<SQL &
SET FEEDBACK OFF
DECLARE
  l_session NUMBER;
  l_result  VARCHAR2(40);
BEGIN
  SELECT s.SESSION_ID
    INTO l_session
    FROM SESSIONS s
    JOIN STUDENTS st ON st.STUDENT_ID = s.STUDENT_ID
   WHERE st.FULL_NAME = 'Race Student'
     AND ROWNUM = 1;

  PKG_SCHEDULING.cancel_session(l_session, l_result);

  INSERT INTO RACE_LOG (PHASE, RACER, ACTION, RESULT)
  VALUES ('A', $i, 'CANCEL', l_result);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    -- SQLCODE cannot appear inside a SQL statement (ORA-00984);
    -- it has to land in a variable first.
    l_result := 'EXCEPTION ' || SQLCODE;
    INSERT INTO RACE_LOG (PHASE, RACER, ACTION, RESULT)
    VALUES ('A', $i, 'CANCEL', l_result);
    COMMIT;
END;
/
exit
SQL
  pids+=($!)
done

for ((i = 1; i <= BUYERS; i++)); do
  db_exec >"$RACE_OUT/A-buy-$i.log" 2>&1 <<SQL &
SET FEEDBACK OFF
DECLARE
  l_student NUMBER;
  l_package NUMBER;
  l_result  VARCHAR2(40);
BEGIN
  SELECT STUDENT_ID INTO l_student FROM STUDENTS WHERE FULL_NAME = 'Race Student';

  PKG_BILLING.purchase_package(l_student, 1, 50, 'CASH', NULL, l_package, l_result);

  INSERT INTO RACE_LOG (PHASE, RACER, ACTION, RESULT)
  VALUES ('A', $i, 'PURCHASE', l_result);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    -- SQLCODE cannot appear inside a SQL statement (ORA-00984);
    -- it has to land in a variable first.
    l_result := 'EXCEPTION ' || SQLCODE;
    INSERT INTO RACE_LOG (PHASE, RACER, ACTION, RESULT)
    VALUES ('A', $i, 'PURCHASE', l_result);
    COMMIT;
END;
/
exit
SQL
  pids+=($!)
done

for p in "${pids[@]}"; do wait "$p"; done

# -----------------------------------------------------------------------------
# Race B: everyone wants the last two hours
# -----------------------------------------------------------------------------
echo "=== Race B: $RACERS bookings against a two-hour balance"

db_exec >/dev/null <<'SQL'
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE
DECLARE
  l_student NUMBER;
  l_package NUMBER;
  l_result  VARCHAR2(40);
BEGIN
  l_student := PKG_TEST.new_student('Scarce Student');
  PKG_BILLING.purchase_package(l_student, 2, 100, 'ZELLE', NULL, l_package, l_result);
  COMMIT;
END;
/
exit
SQL

pids=()
for ((i = 1; i <= RACERS; i++)); do
  # Each racer takes a different day, so nothing is rejected for overlapping --
  # the only scarce resource in this race is the balance. Two days apart, not
  # one: slot() slides a Sunday to the Monday after it, and six consecutive
  # days always contain a Sunday, which would put two racers on the same day.
  db_exec >"$RACE_OUT/B-book-$i.log" 2>&1 <<SQL &
SET FEEDBACK OFF
DECLARE
  l_student NUMBER;
  l_session NUMBER;
  l_result  VARCHAR2(40);
BEGIN
  SELECT STUDENT_ID INTO l_student FROM STUDENTS WHERE FULL_NAME = 'Scarce Student';

  PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(14 + 2 * $i, 10), 60, NULL, 1,
                              l_session, l_result);

  INSERT INTO RACE_LOG (PHASE, RACER, ACTION, RESULT)
  VALUES ('B', $i, 'BOOK', l_result);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    -- SQLCODE cannot appear inside a SQL statement (ORA-00984);
    -- it has to land in a variable first.
    l_result := 'EXCEPTION ' || SQLCODE;
    INSERT INTO RACE_LOG (PHASE, RACER, ACTION, RESULT)
    VALUES ('B', $i, 'BOOK', l_result);
    COMMIT;
END;
/
exit
SQL
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

# -----------------------------------------------------------------------------
# Race C: everyone wants the same slot
# -----------------------------------------------------------------------------
echo "=== Race C: $RACERS bookings for one identical slot"

db_exec >/dev/null <<'SQL'
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE
DECLARE
  l_student NUMBER;
  l_package NUMBER;
  l_result  VARCHAR2(40);
BEGIN
  l_student := PKG_TEST.new_student('Slot Rush');
  PKG_BILLING.purchase_package(l_student, 20, 1000, 'ZELLE', NULL, l_package, l_result);
  COMMIT;
END;
/
exit
SQL

pids=()
for ((i = 1; i <= RACERS; i++)); do
  db_exec >"$RACE_OUT/C-book-$i.log" 2>&1 <<SQL &
SET FEEDBACK OFF
DECLARE
  l_student NUMBER;
  l_session NUMBER;
  l_result  VARCHAR2(40);
BEGIN
  SELECT STUDENT_ID INTO l_student FROM STUDENTS WHERE FULL_NAME = 'Slot Rush';

  PKG_SCHEDULING.book_session(l_student, PKG_TEST.slot(40, 15), 60, NULL, 1,
                              l_session, l_result);

  INSERT INTO RACE_LOG (PHASE, RACER, ACTION, RESULT)
  VALUES ('C', $i, 'BOOK', l_result);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    -- SQLCODE cannot appear inside a SQL statement (ORA-00984);
    -- it has to land in a variable first.
    l_result := 'EXCEPTION ' || SQLCODE;
    INSERT INTO RACE_LOG (PHASE, RACER, ACTION, RESULT)
    VALUES ('C', $i, 'BOOK', l_result);
    COMMIT;
END;
/
exit
SQL
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

# -----------------------------------------------------------------------------
# Verdict
# -----------------------------------------------------------------------------
echo
db_exec <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET LINESIZE 200
WHENEVER SQLERROR EXIT FAILURE

COLUMN action FORMAT A12
COLUMN result FORMAT A26
PROMPT --- what each racer saw
SELECT PHASE, ACTION, RESULT, COUNT(*) AS RACERS
  FROM RACE_LOG
 GROUP BY PHASE, ACTION, RESULT
 ORDER BY PHASE, ACTION, RESULT;

DECLARE
  l_student  NUMBER;
  l_session  NUMBER;
  l_n        NUMBER;
BEGIN
  PKG_TEST.reset;
  PKG_TEST.start_suite('race A: cancel storm during purchases');

  SELECT STUDENT_ID INTO l_student FROM STUDENTS WHERE FULL_NAME = 'Race Student';
  SELECT SESSION_ID INTO l_session FROM SESSIONS WHERE STUDENT_ID = l_student;

  SELECT COUNT(*) INTO l_n FROM RACE_LOG
   WHERE PHASE='A' AND ACTION='CANCEL' AND RESULT='OK';
  PKG_TEST.assert_equals('exactly one cancellation won', 1, l_n);

  SELECT COUNT(*) INTO l_n FROM RACE_LOG
   WHERE PHASE='A' AND ACTION='CANCEL' AND RESULT='ERR_INVALID_TRANSITION';
  PKG_TEST.assert_equals('every other cancel was refused cleanly', $RACERS - 1, l_n);

  SELECT COUNT(*) INTO l_n FROM RACE_LOG
   WHERE PHASE='A' AND ACTION='PURCHASE' AND RESULT='OK';
  PKG_TEST.assert_equals('every purchase committed', $BUYERS, l_n);

  -- The headline assertion: the hour came back exactly once, no matter how
  -- many transactions tried to give it back.
  PKG_TEST.assert_equals('exactly one RELEASE ledger row', 1,
                         PKG_TEST.ledger_count(l_session, 'RELEASE'));

  -- 3 bought - 1 booked + 1 restored + BUYERS x 1 purchased
  PKG_TEST.assert_equals('balance accounts for every movement',
                         3 - 1 + 1 + $BUYERS, PKG_BILLING.get_balance(l_student));

  PKG_TEST.start_suite('race B: contention for the last two hours');

  SELECT STUDENT_ID INTO l_student FROM STUDENTS WHERE FULL_NAME = 'Scarce Student';

  SELECT COUNT(*) INTO l_n FROM RACE_LOG
   WHERE PHASE='B' AND RESULT='OK';
  PKG_TEST.assert_equals('exactly two bookings succeeded', 2, l_n);

  SELECT COUNT(*) INTO l_n FROM RACE_LOG
   WHERE PHASE='B' AND RESULT='ERR_INSUFFICIENT_HOURS';
  PKG_TEST.assert_equals('the rest were told there was no balance', $RACERS - 2, l_n);

  PKG_TEST.assert_equals('balance landed exactly on zero', 0,
                         PKG_BILLING.get_balance(l_student));

  SELECT COUNT(*) INTO l_n FROM SESSIONS
   WHERE STUDENT_ID = l_student AND STATUS = 'CONFIRMED';
  PKG_TEST.assert_equals('two sessions exist, not six', 2, l_n);

  PKG_TEST.start_suite('race C: contention for one slot');

  SELECT COUNT(*) INTO l_n FROM RACE_LOG
   WHERE PHASE='C' AND RESULT='OK';
  PKG_TEST.assert_equals('exactly one booking won the slot', 1, l_n);

  SELECT COUNT(*) INTO l_n FROM RACE_LOG
   WHERE PHASE='C' AND RESULT='ERR_DOUBLE_BOOKED';
  PKG_TEST.assert_equals('the rest saw a double booking', $RACERS - 1, l_n);

  PKG_TEST.start_suite('global invariants after all three races');
  PKG_TEST.assert_ledger_consistent('post-race');

  PKG_TEST.summary;
END;
/
exit
SQL

echo
echo "Concurrency suite passed."
