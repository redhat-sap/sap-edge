#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/configure_worker_nofile.py" "$@"
