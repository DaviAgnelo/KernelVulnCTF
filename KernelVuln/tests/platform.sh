#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"
assert_project_root "$PROJECT_ROOT"

failures=0

assert_family()
{
    local id=$1 id_like=$2 expected=$3

    PLATFORM_ID=$id
    PLATFORM_ID_LIKE=$id_like
    PLATFORM_FAMILY=''
    PLATFORM_PACKAGE_MANAGER=''
    classify_linux_platform
    if [[ $PLATFORM_FAMILY != "$expected" ]]; then
        printf '[FALHA] ID=%s ID_LIKE=%s: família=%s; esperado=%s\n' \
            "$id" "$id_like" "$PLATFORM_FAMILY" "$expected" >&2
        ((failures += 1))
    fi
}

assert_family ubuntu 'debian' debian
assert_family rocky 'rhel centos fedora' fedora-rhel
assert_family manjaro 'arch' arch
assert_family opensuse-tumbleweed 'suse opensuse' suse
assert_family gentoo '' generic

test_root=$(mktemp -d -t kernel-ctf-platform.XXXXXXXX)
[[ -d $test_root && ! -L $test_root && \
   $(basename -- "$test_root") == kernel-ctf-platform.* ]] || \
    die "mktemp não criou um diretório de teste seguro"

cleanup()
{
    trap - EXIT HUP INT TERM
    if [[ -n ${test_root:-} && -d $test_root && ! -L $test_root && \
          $(basename -- "$test_root") == kernel-ctf-platform.* ]]; then
        rm -rf -- "$test_root"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

legacy_root=$test_root/legacy
invalid_root=$test_root/invalid
symlink_root=$test_root/symlink
fake_bin=$test_root/bin
mkdir -m 0700 -- "$legacy_root" "$invalid_root" "$symlink_root" "$fake_bin"
printf 'kernel-ctf-lab-debian12\n' > "$legacy_root/.kernel-ctf-project"
printf 'marcador-invalido\n' > "$invalid_root/.kernel-ctf-project"

legacy_warning=$test_root/legacy.warning
assert_project_root "$legacy_root" 2> "$legacy_warning"
if ! grep -Fq 'marcador legado detectado' "$legacy_warning"; then
    printf '[FALHA] marcador legado foi aceito sem aviso de migração\n' >&2
    ((failures += 1))
fi
if (assert_project_root "$invalid_root") 2>/dev/null; then
    printf '[FALHA] marcador inválido foi aceito\n' >&2
    ((failures += 1))
fi
if command -v ln >/dev/null 2>&1; then
    ln -s -- "$PROJECT_ROOT/.kernel-ctf-project" "$symlink_root/.kernel-ctf-project"
    if (assert_project_root "$symlink_root") 2>/dev/null; then
        printf '[FALHA] marcador simbólico foi aceito\n' >&2
        ((failures += 1))
    fi
else
    log_warn "ln indisponível; caso negativo de marcador simbólico não foi exercitado"
fi

cp -- /bin/sh "$fake_bin/qemu-kvm"
expected_qemu=$(readlink -f -- "$fake_bin/qemu-kvm")
resolved_qemu=$(PATH="$fake_bin:$PATH" resolve_qemu_x86_64) || {
    printf '[FALHA] resolver não encontrou qemu-kvm no PATH controlado\n' >&2
    ((failures += 1))
    resolved_qemu=''
}
if [[ -n $resolved_qemu && $resolved_qemu != "$expected_qemu" ]]; then
    printf '[FALHA] QEMU resolvido=%s; esperado=%s\n' \
        "$resolved_qemu" "$expected_qemu" >&2
    ((failures += 1))
fi

((failures == 0)) || die "$failures teste(s) de plataforma falharam"
log_ok "perfis de plataforma, marcador e resolução de QEMU validados"
