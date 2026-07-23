#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"

assert_project_root "$PROJECT_ROOT"
require_non_root
require_debian_bookworm

PURGE_DOWNLOADS=0
case "${1-}" in
    '') ;;
    --purge-downloads) PURGE_DOWNLOADS=1 ;;
    -h|--help)
        printf 'Uso: %s [--purge-downloads]\n' "$0"
        exit 0
        ;;
    *) die "opção desconhecida: $1" ;;
esac
(($# <= 1)) || die "argumentos em excesso"

bash "$PROJECT_ROOT/scripts/check-deps.sh" build

BUILD_TARGET=$PROJECT_ROOT/build
DIST_TARGET=$PROJECT_ROOT/dist
DOWNLOAD_TARGET=$PROJECT_ROOT/downloads
[[ $BUILD_TARGET == "$PROJECT_ROOT/build" && $DIST_TARGET == "$PROJECT_ROOT/dist" ]] || \
    die "alvos de reset inesperados"

log_warn "removendo artefatos gerados em build/ e dist/"
rm -rf -- "$BUILD_TARGET" "$DIST_TARGET"
if [[ $PURGE_DOWNLOADS -eq 1 ]]; then
    [[ $DOWNLOAD_TARGET == "$PROJECT_ROOT/downloads" ]] || die "alvo de download inesperado"
    log_warn "removendo também downloads/; o kernel será baixado novamente"
    rm -rf -- "$DOWNLOAD_TARGET"
fi

exec bash "$PROJECT_ROOT/build.sh" all
