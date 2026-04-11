#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED_FILES=0

shopt -s nullglob
for test_file in "$SCRIPT_DIR"/test_*.sh; do
  echo ""
  echo "=== $(basename "$test_file") ==="
  bash "$test_file" || FAILED_FILES=$((FAILED_FILES + 1))
done

echo ""
if [ "$FAILED_FILES" -eq 0 ]; then
  echo "All test files passed."
else
  echo "$FAILED_FILES test file(s) had failures."
  exit 1
fi
