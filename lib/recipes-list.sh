#!/usr/bin/env bash
# DEPRECATED forwarding stub (concept-vocabulary rename U8): recipes-list → workflows-list.
# Kept one minor version for agents/scripts with the memorized lib/recipes-list.sh
# path (older skill prose named it as the picker's data layer / preview surface);
# removed next minor. Execs lib/workflows-list.sh verbatim; exit code passes through.
echo "lib/recipes-list.sh is deprecated; use lib/workflows-list.sh (recipe→workflow rename)" >&2
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workflows-list.sh" "$@"
