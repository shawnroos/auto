#!/usr/bin/env bash
# DEPRECATED forwarding stub (concept-vocabulary rename U5): tick → pulse.
# Kept one minor version for agents/scripts with the memorized lib/tick.sh path
# (and for in-flight runs whose ScheduleWakeup prompt still names the old
# surface); removed next minor. Execs lib/pulse.sh verbatim; exit code passes through.
echo "lib/tick.sh is deprecated; use lib/pulse.sh (tick→pulse rename)" >&2
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pulse.sh" "$@"
