#!/usr/bin/env bash
# Thin compatibility wrapper (old lab name) → apply.sh
exec "$(cd "$(dirname "$0")" && pwd)/apply.sh" "$@"
