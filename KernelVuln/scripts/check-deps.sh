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
(($# <= 1)) || die "argumentos em excesso"

export LC_ALL=C
require_linux_x86_64
assert_project_root "$PROJECT_ROOT"

declare -a commands=()
declare -a packages=()
declare -a temporary_paths=()

cleanup_dependency_check()
{
    if ((${#temporary_paths[@]} > 0)); then
        rm -f -- "${temporary_paths[@]}"
    fi
}
trap cleanup_dependency_check EXIT

add_build_package_hints()
{
    case "$PLATFORM_FAMILY" in
        debian)
            packages+=(build-essential bc bison flex cpio gzip xz-utils wget
                ca-certificates busybox-static binutils libelf-dev libssl-dev
                openssl dwarves pkg-config perl python3 tar coreutils findutils
                grep sed gawk)
            ;;
        fedora-rhel)
            packages+=(gcc make bc bison flex cpio gzip xz wget ca-certificates
                busybox binutils elfutils-libelf-devel openssl-devel openssl
                dwarves pkgconf-pkg-config perl python3 glibc-static tar
                coreutils findutils grep sed gawk)
            ;;
        arch)
            packages+=(base-devel bc bison flex cpio gzip xz wget ca-certificates
                busybox binutils libelf openssl pahole pkgconf perl python glibc)
            packages+=(tar coreutils findutils grep sed gawk)
            ;;
        suse)
            packages+=(gcc make bc bison flex cpio gzip xz wget ca-certificates
                busybox-static binutils libelf-devel libopenssl-devel openssl
                dwarves pkg-config perl python3 glibc-devel-static tar
                coreutils findutils grep sed gawk)
            ;;
        generic)
            packages+=(gcc make bc bison flex cpio gzip xz wget ca-certificates
                busybox-static binutils libelf-devel openssl-devel openssl
                pahole pkg-config perl python3 libc-static-devel tar coreutils
                findutils grep sed gawk)
            ;;
    esac
}

add_runtime_package_hints()
{
    case "$PLATFORM_FAMILY" in
        debian)
            packages+=(bash qemu-system-x86 cpio gzip coreutils util-linux grep)
            ;;
        fedora-rhel)
            if platform_has_token fedora; then
                packages+=(bash qemu-system-x86-core cpio gzip coreutils util-linux grep)
            else
                packages+=(bash qemu-kvm cpio gzip coreutils util-linux grep)
            fi
            ;;
        arch)
            packages+=(bash qemu-system-x86 cpio gzip coreutils util-linux grep)
            ;;
        suse)
            packages+=(bash qemu-x86 cpio gzip coreutils util-linux grep)
            ;;
        generic)
            packages+=(bash qemu-system-x86 cpio gzip coreutils util-linux grep)
            ;;
    esac
}

add_host_install_package_hints()
{
    case "$PLATFORM_FAMILY" in
        debian)
            packages+=(openssh-server systemd passwd diffutils)
            ;;
        fedora-rhel)
            packages+=(openssh-server systemd shadow-utils diffutils)
            ;;
        arch)
            packages+=(openssh systemd shadow diffutils)
            ;;
        suse)
            packages+=(openssh-server systemd shadow diffutils)
            ;;
        generic)
            packages+=(openssh-server systemd shadow diffutils)
            ;;
    esac
}

add_build_dependencies()
{
    commands+=(gcc make bc bison flex cpio gzip tar xz wget sha256sum nproc
        find sort install awk sed grep readelf mktemp stat touch id perl python3
        pkg-config pahole openssl ld ar nm objcopy objdump cat chmod cp dirname
        basename mkdir mv pwd readlink rm)
    add_build_package_hints
}

add_runtime_dependencies()
{
    commands+=(bash qemu-system-x86_64 cpio gzip sha256sum setsid flock timeout
        readlink stat mktemp basename dirname env id kill sleep rm grep cat mkdir)
    add_runtime_package_hints
}

add_host_install_dependencies()
{
    commands+=(sshd ssh-keygen systemctl systemd-tmpfiles useradd groupadd usermod
        runuser getent install awk chmod chown cp grep mv rm stat findmnt cmp)
    add_host_install_package_hints
}

case "$MODE" in
    build) add_build_dependencies ;;
    runtime) add_runtime_dependencies ;;
    host-install)
        add_runtime_dependencies
        add_host_install_dependencies
        ;;
    all)
        add_build_dependencies
        add_runtime_dependencies
        add_host_install_dependencies
        ;;
esac

print_package_hint()
{
    local package_name
    local -A package_seen=()
    local -a unique_packages=()

    for package_name in "${packages[@]}"; do
        [[ -v "package_seen[$package_name]" ]] && continue
        package_seen[$package_name]=1
        unique_packages+=("$package_name")
    done

    printf '       Plataforma detectada: ID=%s VERSION_ID=%s família=%s.\n' \
        "$PLATFORM_ID" "${PLATFORM_VERSION_ID:-desconhecida}" "$PLATFORM_FAMILY" >&2
    case "$PLATFORM_FAMILY" in
        debian)
            printf '       Sugestão de instalação (Debian/Ubuntu):\n' >&2
            printf '       sudo apt-get update\n       sudo apt-get install --no-install-recommends' >&2
            ;;
        fedora-rhel)
            printf '       Sugestão de instalação (Fedora/RHEL-like):\n' >&2
            printf '       sudo %s install' "$PLATFORM_PACKAGE_MANAGER" >&2
            ;;
        arch)
            printf '       Sugestão de instalação (Arch-like):\n' >&2
            printf '       sudo pacman -S --needed' >&2
            ;;
        suse)
            printf '       Sugestão de instalação (openSUSE/SLES):\n' >&2
            printf '       sudo zypper --non-interactive install' >&2
            ;;
        generic)
            printf '       Distribuição sem perfil conhecido; instale pacotes equivalentes a:' >&2
            ;;
    esac
    for package_name in "${unique_packages[@]}"; do
        printf ' %s' "$package_name" >&2
    done
    printf '\n' >&2

    if [[ $MODE == build || $MODE == all ]]; then
        case "$PLATFORM_FAMILY" in
            fedora-rhel)
                printf '       Em variantes RHEL, busybox pode exigir EPEL e o nome do pacote QEMU pode ser qemu-kvm.\n' >&2
                ;;
            suse)
                printf '       A disponibilidade de busybox-static varia por versão; um BusyBox estático confiável no PATH também atende ao contrato.\n' >&2
                ;;
            generic)
                printf '       O nome dos pacotes é apenas orientativo; a validação abaixo é feita por capacidades reais.\n' >&2
                ;;
        esac
    fi
}

dependency_failure()
{
    printf '[ERRO] %s\n' "$1" >&2
    print_package_hint
    exit 1
}

declare -A seen_commands=()
declare -a missing=()
QEMU_X86_64_BIN=''
for command_name in "${commands[@]}"; do
    [[ -v "seen_commands[$command_name]" ]] && continue
    seen_commands[$command_name]=1
    if [[ $command_name == qemu-system-x86_64 ]]; then
        QEMU_X86_64_BIN=$(resolve_qemu_x86_64 || true)
        [[ -n $QEMU_X86_64_BIN ]] || missing+=(qemu-system-x86_64/qemu-kvm)
    else
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    fi
done

if [[ $MODE == build || $MODE == all ]]; then
    command -v busybox >/dev/null 2>&1 || missing+=(busybox)
fi

if ((${#missing[@]} > 0)); then
    dependency_failure "dependências ausentes ($MODE): ${missing[*]}"
fi

require_help_option()
{
    local command_name=$1 required_option=$2 help_output=''

    help_output=$("$command_name" --help 2>&1) || true
    grep -Fq -- "$required_option" <<<"$help_output" || \
        dependency_failure "$command_name incompatível: opção obrigatória ausente: $required_option"
}

if [[ $MODE == build || $MODE == all ]]; then
    require_help_option cpio --reproducible
    require_help_option cpio --null
    require_help_option tar --sort
    require_help_option tar --mtime
    require_help_option mktemp --tmpdir
fi

if [[ $MODE == runtime || $MODE == host-install || $MODE == all ]]; then
    require_help_option sha256sum --strict
    require_help_option timeout --foreground
    require_help_option timeout --kill-after
    require_help_option stat --format
fi

if [[ $MODE == host-install || $MODE == all ]]; then
    require_help_option cp --preserve
    require_help_option findmnt --target
    require_help_option systemctl --property
fi

if [[ $MODE == runtime || $MODE == host-install || $MODE == all ]]; then
    qemu_help=$("$QEMU_X86_64_BIN" -help 2>&1) || \
        dependency_failure "$QEMU_X86_64_BIN não conseguiu exibir suas capacidades"
    for required_qemu_option in -sandbox -nodefaults -no-user-config -nic; do
        grep -Fq -- "$required_qemu_option" <<<"$qemu_help" || \
            dependency_failure "QEMU incompatível: opção obrigatória ausente: $required_qemu_option"
    done
fi

compile_probe()
{
    local source_text=$1
    shift
    local probe_source probe_binary

    probe_source=$(mktemp --suffix=.c) || return 1
    probe_binary=${probe_source%.c}
    temporary_paths+=("$probe_source" "$probe_binary")
    printf '%b\n' "$source_text" > "$probe_source"
    gcc -Werror -o "$probe_binary" "$probe_source" "$@" >/dev/null 2>&1
}

if [[ $MODE == build || $MODE == all ]]; then
    busybox_path=$(command -v busybox)
    busybox_program_headers=$(readelf -l "$busybox_path") || \
        dependency_failure "não foi possível inspecionar $busybox_path com readelf"
    if grep -q 'INTERP' <<<"$busybox_program_headers"; then
        dependency_failure "$busybox_path é dinâmico; o initramfs exige um BusyBox estaticamente ligado"
    fi

    compile_probe '#include <libelf.h>\nint main(void) { return elf_version(EV_CURRENT) == EV_NONE; }' \
        -lelf || dependency_failure "a toolchain não conseguiu compilar e ligar um programa com libelf"
    compile_probe '#include <openssl/ssl.h>\nint main(void) { return OPENSSL_init_ssl(0, 0) == 1 ? 0 : 1; }' \
        -lssl -lcrypto || dependency_failure "a toolchain não conseguiu compilar e ligar um programa com OpenSSL"
    compile_probe 'int main(void) { return 0; }' -static || \
        dependency_failure "gcc não conseguiu criar um binário estático"
fi

if [[ $MODE == host-install || $MODE == all ]]; then
    require_systemd_host
fi

cleanup_dependency_check
temporary_paths=()
trap - EXIT

log_ok "dependências '$MODE' validadas em Linux x86_64 (ID=$PLATFORM_ID; família=$PLATFORM_FAMILY)"
