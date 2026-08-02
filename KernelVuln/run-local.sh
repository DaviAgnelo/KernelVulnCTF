#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"

assert_project_root "$PROJECT_ROOT"
require_non_root
require_linux_x86_64
bash "$PROJECT_ROOT/scripts/check-deps.sh" runtime
LOCAL_RUNTIME=$PROJECT_ROOT/build/local-runtime
mkdir -p "$LOCAL_RUNTIME"
chmod 0700 "$LOCAL_RUNTIME"

KERNEL_CTF_RUNTIME_DIR=$LOCAL_RUNTIME exec bash "$PROJECT_ROOT/bin/kernel-ctf-session"
