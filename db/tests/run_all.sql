-- =============================================================================
-- run_all.sql -- the Week 1 exit test.
--
--   cd db && ./run_tests.sh
--
-- Exits non-zero if any assertion fails, so CI and a human get the same answer.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 200
WHENEVER SQLERROR EXIT FAILURE

PROMPT
PROMPT ##########################################################
PROMPT #  Tutoring operations -- PL/SQL business rule test suite #
PROMPT ##########################################################

@@00_test_framework.sql

EXECUTE PKG_TEST.reset;

@@10_test_scheduling.sql
@@20_test_billing.sql
@@30_test_transitions.sql
@@40_test_consistency.sql

-- Leave the database empty rather than littered with test students.
EXECUTE PKG_TEST.reset_data;

EXECUTE PKG_TEST.summary;

exit
