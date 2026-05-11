#!/usr/bin/env bash
# Run all test suites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OVERALL=0
for t in "$SCRIPT_DIR"/test-*.sh; do
  echo
  echo "########################################"
  echo "# $(basename "$t")"
  echo "########################################"
  bash "$t" || OVERALL=1
done

echo
if [[ "$OVERALL" == "0" ]]; then
  echo "✅ All test suites passed."
else
  echo "❌ Some test suites failed."
fi
exit "$OVERALL"
