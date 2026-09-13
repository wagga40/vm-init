#!/usr/bin/env bash
# Compatibility entry point. The recovery implementation also ships in bundles.
set -euo pipefail
_self=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
RECOVERY_DIR=$(cd "$(dirname "$_self")" && pwd)
# shellcheck source=modules/_common.sh
source "$RECOVERY_DIR/_common.sh"
# shellcheck source=modules/_safety.sh
source "$RECOVERY_DIR/_safety.sh"
# shellcheck source=modules/_recovery.sh
source "$RECOVERY_DIR/_recovery.sh"
recover_dns_main "$@"
