#!/usr/bin/env bash
# Oprava uzlu bohus488tojab420 — Bohušovická 488 — stanice spoje na jab420
# Kabel z notebooku do krabice a spustit pod rootem.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec ./oprava-na-miste.sh nodes/bohus488.conf "$@"
