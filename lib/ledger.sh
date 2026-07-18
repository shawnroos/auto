#!/usr/bin/env bash
# DEPRECATED forwarding stub (concept-vocabulary rename U9): ledger → run_record.
# Kept one minor version for agents/scripts with the memorized lib/ledger.sh path;
# removed next minor. Execs lib/run_record.sh verbatim; exit code passes through.
# The notice goes to stderr ONLY — `bash lib/ledger.sh read <repo> <run> | jq` must
# keep a byte-clean stdout.
echo "lib/ledger.sh is deprecated; use lib/run_record.sh (ledger→run-record rename)" >&2
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_record.sh" "$@"
