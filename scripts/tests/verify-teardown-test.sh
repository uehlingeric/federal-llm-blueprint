#!/bin/bash
# Test harness for verify-teardown.sh — verifies three basic scenarios

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-teardown.sh"

PASS=0
FAIL=0

test_clean() {
  echo "=== Scenario: clean (no residues) ==="
  local test_dir
  test_dir=$(mktemp -d)
  trap "rm -rf '$test_dir'" RETURN

  cat > "$test_dir/aws" << 'STUBEOF'
#!/bin/bash
exit 0
STUBEOF
  chmod +x "$test_dir/aws"

  local output exit_code
  if output=$(PATH="$test_dir:$PATH" bash "$VERIFY_SCRIPT" -p test-project -e test-env -r us-east-1 2>&1); then
    exit_code=0
  else
    exit_code=$?
    output=$(PATH="$test_dir:$PATH" bash "$VERIFY_SCRIPT" -p test-project -e test-env -r us-east-1 2>&1 || true)
  fi

  echo "$output"

  if [[ $exit_code -eq 0 ]] && echo "$output" | grep -q "residue=0"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL: expected exit 0 and residue=0"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

test_dirty() {
  echo "=== Scenario: dirty (has residues) ==="
  local test_dir
  test_dir=$(mktemp -d)
  trap "rm -rf '$test_dir'" RETURN

  cat > "$test_dir/aws" << 'STUBEOF'
#!/bin/bash
SERVICE="$1"
OPERATION="$2"

# Return at least one residue per service for testing
[[ "$SERVICE" == "resourcegroupstaggingapi" ]] && [[ "$OPERATION" == "get-resources" ]] && echo "arn:aws:s3:::test-project-test-env-docs"
[[ "$SERVICE" == "rds" ]] && [[ "$OPERATION" == "describe-db-snapshots" ]] && echo "test-project-test-env-snapshot"
[[ "$SERVICE" == "s3api" ]] && [[ "$OPERATION" == "list-buckets" ]] && echo "test-project-test-env-bucket"
exit 0
STUBEOF
  chmod +x "$test_dir/aws"

  local output exit_code
  if output=$(PATH="$test_dir:$PATH" bash "$VERIFY_SCRIPT" -p test-project -e test-env -r us-east-1 2>&1); then
    exit_code=0
  else
    exit_code=$?
    output=$(PATH="$test_dir:$PATH" bash "$VERIFY_SCRIPT" -p test-project -e test-env -r us-east-1 2>&1 || true)
  fi

  echo "$output" | head -5

  if [[ $exit_code -eq 1 ]] && echo "$output" | grep -q "RESIDUE"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL: expected exit 1 and RESIDUE lines"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

test_pending() {
  echo "=== Scenario: pending-deletion (not counted as residue) ==="
  local test_dir
  test_dir=$(mktemp -d)
  trap "rm -rf '$test_dir'" RETURN

  cat > "$test_dir/aws" << 'STUBEOF'
#!/bin/bash
SERVICE="$1"
OPERATION="$2"

if [[ "$SERVICE" == "kms" ]] && [[ "$OPERATION" == "list-aliases" ]]; then
  echo "alias/test-project-test-env-data"
elif [[ "$SERVICE" == "kms" ]] && [[ "$OPERATION" == "describe-key" ]]; then
  [[ "$*" == *"DeletionDate"* ]] && echo "2025-01-20T00:00:00Z" || echo "PendingDeletion"
elif [[ "$SERVICE" == "secretsmanager" ]] && [[ "$OPERATION" == "list-secrets" ]]; then
  echo -e "test-project-test-env-gateway-master-key\t2025-01-20T00:00:00Z"
fi
exit 0
STUBEOF
  chmod +x "$test_dir/aws"

  local output exit_code
  if output=$(PATH="$test_dir:$PATH" bash "$VERIFY_SCRIPT" -p test-project -e test-env -r us-east-1 2>&1); then
    exit_code=0
  else
    exit_code=$?
    output=$(PATH="$test_dir:$PATH" bash "$VERIFY_SCRIPT" -p test-project -e test-env -r us-east-1 2>&1 || true)
  fi

  echo "$output"

  if [[ $exit_code -eq 0 ]] && echo "$output" | grep -q "residue=0" && echo "$output" | grep -q "INFO"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL: expected exit 0, residue=0, and INFO lines"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

test_aws_failure() {
  echo "=== Scenario: aws CLI failing (WARN must not count as residue) ==="
  local test_dir
  test_dir=$(mktemp -d)
  trap "rm -rf '$test_dir'" RETURN

  cat > "$test_dir/aws" << 'STUBEOF'
#!/bin/bash
echo "An error occurred (AccessDenied)" >&2
exit 1
STUBEOF
  chmod +x "$test_dir/aws"

  local output exit_code
  if output=$(PATH="$test_dir:$PATH" bash "$VERIFY_SCRIPT" -p test-project -e test-env -r us-east-1 2>/dev/null); then
    exit_code=0
  else
    exit_code=$?
  fi

  echo "$output"

  if [[ $exit_code -eq 0 ]] && echo "$output" | grep -q "residue=0"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL: expected exit 0 and residue=0 when every aws call fails"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

test_clean
test_dirty
test_pending
test_aws_failure

echo "============================================="
echo "Results: PASS=$PASS FAIL=$FAIL"
echo "============================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
