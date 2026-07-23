#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE=${1:-all}
case "$MODE" in
    build|runtime|host-install|all) ;;
    *) die "uso: $0 [build|runtime|host-install|all]" ;;
esac

require_debian_bookworm
assert_project_root "$PROJECT_ROOT"

declare -a commands=()
declare -a packages=()

add_build_dependencies()
{
    commands+=(gcc make bc bison flex cpio gzip tar xz wget sha256sum nproc \
        find sort install awk sed grep readelf mktemp stat touch id perl python3 \
        pkg-config pahole openssl)
    packages+=(build-essential bc bison flex cpio gzip xz-utils wget ca-certificates \
        busybox-static binutils libelf-dev libssl-dev openssl dwarves pkg-config \
        perl python3)
}

add_runtime_dependencies()
{
    commands+=(bash qemu-system-x86_64 cpio gzip sha256sum setsid flock timeout \
        readlink stat mktemp basename dirname env id kill sleep rm grep cat mkdir)
    packages+=(bash qemu-system-x86 cpio gzip coreutils util-linux grep)
}

add_host_install_dependencies()
{
    commands+=(sshd ssh-keygen systemctl systemd-tmpfiles useradd groupadd usermod \
        runuser getent install awk chmod chown cp grep mv rm stat)
    packages+=(openssh-server systemd passwd)
}

case "$MODE" in
    build) add_build_dependencies ;;
    runtime) add_runtime_dependencies ;;
    host-install) add_runtime_dependencies; add_host_install_dependencies ;;
    all) add_build_dependencies; add_runtime_dependencies; add_host_install_dependencies ;;
esac

declare -A seen=()
declare -a missing=()
for command_name in "${commands[@]}"; do
    [[ -v "seen[$command_name]" ]] && continue
    seen[$command_name]=1
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done

if [[ $MODE == build || $MODE == all ]]; then
    command -v busybox >/dev/null 2>&1 || missing+=(busybox)
fi

if ((${#missing[@]} > 0)); then
    printf '[ERRO] Dependências ausentes (%s): %s\n' "$MODE" "${missing[*]}" >&2
    printf '       No Debian 12, instale com:\n       apt-get update && apt-get install --no-install-recommends' >&2
    seen=()
    for package_name in "${packages[@]}"; do
        [[ -v "seen[$package_name]" ]] && continue
        seen[$package_name]=1
        printf ' %s' "$package_name" >&2
    done
    printf '\n' >&2
    exit 1
fi

if [[ $MODE == build || $MODE == all ]]; then
    busybox_path=$(command -v busybox)
    busybox_program_headers=$(readelf -l "$busybox_path") || \
        die "não foi possível inspecionar $busybox_path com readelf"
    if grep -q 'INTERP' <<<"$busybox_program_headers"; then
        die "$busybox_path é dinâmico; instale o pacote Debian busybox-static"
    fi
    [[ -r /usr/include/libelf.h || -r /usr/include/elfutils/libelf.h ]] || \
        die "headers libelf ausentes; instale libelf-dev"
    [[ -r /usr/include/openssl/ssl.h ]] || die "headers OpenSSL ausentes; instale libssl-dev"

    static_probe_source=$(mktemp --suffix=.c)
    static_probe_binary=${static_probe_source%.c}
    trap 'rm -f -- "$static_probe_source" "$static_probe_binary"' EXIT
    printf 'int main(void) { return 0; }\n' > "$static_probe_source"
    gcc -static -o "$static_probe_binary" "$static_probe_source" >/dev/null 2>&1 || \
        die "gcc não conseguiu criar binário estático; reinstale build-essential/libc6-dev"
    rm -f -- "$static_probe_source" "$static_probe_binary"
    trap - EXIT
fi

log_ok "dependências '$MODE' validadas no Debian 12 Bookworm"
