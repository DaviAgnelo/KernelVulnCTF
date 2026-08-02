#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"
assert_project_root "$PROJECT_ROOT"
require_linux_x86_64
require_non_root
bash "$PROJECT_ROOT/scripts/check-deps.sh" runtime
QEMU_X86_64_BIN=$(resolve_qemu_x86_64) || die "QEMU x86_64 não encontrado após a validação"

for artifact in bzImage initramfs.cpio.gz runtime.conf SHA256SUMS; do
    [[ -r $PROJECT_ROOT/dist/$artifact ]] || die "artefato ausente: dist/$artifact"
done
(
    cd "$PROJECT_ROOT/dist"
    sha256sum --check --strict SHA256SUMS
)

load_lab_config "$PROJECT_ROOT/dist/runtime.conf"
validate_lab_values
MEMORY_MIB=$(config_get MEMORY_MIB)
VCPUS=$(config_get VCPUS)

log_dir=$(mktemp -d -t kernel-ctf-integration.XXXXXXXX)
[[ -d $log_dir && ! -L $log_dir ]] || die "mktemp nao criou um diretorio seguro"
[[ $(stat -c '%a' -- "$log_dir") == 700 ]] || \
    die "diretorio temporario de logs nao tem modo 0700"

cleanup()
{
    trap - EXIT HUP INT TERM
    if [[ -n ${log_dir:-} && -d $log_dir && ! -L $log_dir && \
          $(basename -- "$log_dir") == kernel-ctf-integration.* ]]; then
        rm -rf -- "$log_dir"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_level()
{
    local level=$1 cpu_model mitigation_args log_file qemu_status
    log_file=$log_dir/level-$level.log

    set_level_profile "$level"
    cpu_model=$LEVEL_CPU_MODEL
    mitigation_args=$LEVEL_KERNEL_ARGS

    log_info "autoteste real do nivel $level (CPU=$cpu_model; mitigacoes=$mitigation_args)"
    set +e
    timeout --signal=TERM --kill-after=5s 60s \
        "$QEMU_X86_64_BIN" \
            -machine pc \
            -accel tcg,thread=multi \
            -cpu "$cpu_model" \
            -m "${MEMORY_MIB}M" \
            -smp "$VCPUS" \
            -kernel "$PROJECT_ROOT/dist/bzImage" \
            -initrd "$PROJECT_ROOT/dist/initramfs.cpio.gz" \
            -append "rdinit=/init console=ttyS0,115200n8 quiet loglevel=3 oops=panic panic=1 random.trust_cpu=on lab.level=$level lab.selftest=1 $mitigation_args" \
            -nodefaults \
            -no-user-config \
            -display none \
            -chardev "file,id=serial0,path=$log_file" \
            -serial chardev:serial0 \
            -monitor none \
            -nic none \
            -no-reboot \
            -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
            </dev/null
    qemu_status=$?
    set -e

    if [[ $qemu_status -ne 0 ]]; then
        if [[ -f $log_file ]]; then
            cat "$log_file" >&2
        fi
        die "QEMU do nivel $level terminou com status $qemu_status"
    fi

    if ! grep -Fq 'SELFTEST: PASS' "$log_file" ||
       ! grep -Fq 'SELFTEST: KVULN_OVERSIZED_READ=PASS' "$log_file" ||
       ! grep -Fq 'SELFTEST: KVULN_OVERSIZED_WRITE=PASS' "$log_file" ||
       ! grep -Fq "SELFTEST: LEVEL_POLICY_$level=PASS" "$log_file" ||
       ! grep -Fq 'acesso à flag=negado' "$log_file"; then
        [[ -f $log_file ]] && cat "$log_file" >&2
        die "autoteste do nivel $level nao confirmou perfil, identidade e flag negada"
    fi
    if grep -Fq 'Unknown kernel command line parameters' "$log_file"; then
        cat "$log_file" >&2
        die "o nivel $level passou parametros desconhecidos ao kernel"
    fi

    log_ok "nivel $level confirmou perfil, UID/GID 1000 e flag negada"
}

for level in 0 1 2 3 4; do
    run_level "$level"
done

log_ok "boot real validou os perfis completos dos niveis 0..4"
