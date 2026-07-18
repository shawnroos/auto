#!/usr/bin/env bash
# DEPRECATED forwarding stub (concept-vocabulary rename U4): adapter → backend.
# Kept one minor version for agents/scripts with the memorized lib/adapter-native.sh
# path; removed next minor. Execs lib/backend-native.sh verbatim; exit code passes through.
echo "lib/adapter-native.sh is deprecated; use lib/backend-native.sh (adapter→backend rename)" >&2
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backend-native.sh" "$@"
