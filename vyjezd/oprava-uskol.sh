#!/usr/bin/env bash
# Oprava uzlu uskol — Valečovská — stanice spoje na valtoska
# Kabel z notebooku do krabice a spustit pod rootem.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec ./oprava-na-miste.sh nodes/uskol.conf "$@"
