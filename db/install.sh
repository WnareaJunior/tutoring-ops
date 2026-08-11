#!/usr/bin/env bash
# Builds the schema and every package from scratch.
#
#   cd db && docker compose up -d && ./install.sh
#
# Re-runnable: 01_schema.sql drops what it owns first, so this wipes data.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

db_wait_for_ready

MIGRATIONS=(
  migrations/01_schema.sql
  migrations/02_pkg_validation.sql
  migrations/03_pkg_events.sql
  migrations/04_pkg_billing.sql
  migrations/05_pkg_scheduling.sql
  migrations/06_pkg_students.sql
  migrations/07_pkg_outbox.sql
)

for m in "${MIGRATIONS[@]}"; do
  echo "--- $m"
  db_script "$m"
done

# A package that compiled with errors still "exists", so ask the dictionary
# rather than trusting that no script printed a warning.
echo "--- verifying"
db_exec <<'SQL'
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET PAGESIZE 100
WHENEVER SQLERROR EXIT FAILURE

COLUMN object_name FORMAT A30
SELECT object_type, object_name, status
  FROM user_objects
 WHERE object_type IN ('PACKAGE','PACKAGE BODY')
 ORDER BY object_name, object_type;

DECLARE
  l_invalid PLS_INTEGER;
BEGIN
  -- A package that failed to compile still exists, so "the script printed no
  -- error" proves nothing. Ask the dictionary instead.
  SELECT COUNT(*)
    INTO l_invalid
    FROM user_objects
   WHERE object_type IN ('PACKAGE','PACKAGE BODY')
     AND status <> 'VALID';

  IF l_invalid > 0 THEN
    FOR e IN (SELECT name, type, line, position, text
                FROM user_errors
               ORDER BY name, type, sequence) LOOP
      DBMS_OUTPUT.PUT_LINE(e.type || ' ' || e.name || ' line ' || e.line ||
                           ', col ' || e.position || ': ' || e.text);
    END LOOP;

    RAISE_APPLICATION_ERROR(-20999, l_invalid || ' package object(s) are INVALID');
  END IF;

  DBMS_OUTPUT.PUT_LINE('All packages VALID.');
END;
/
exit
SQL

echo "Schema installed."
