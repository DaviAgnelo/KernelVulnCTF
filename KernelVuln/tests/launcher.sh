#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"
assert_project_root "$PROJECT_ROOT"
require_debian_bookworm
require_non_root
bash "$PROJECT_ROOT/scripts/check-deps.sh" runtime

for artifact in bzImage initramfs.cpio.gz runtime.conf SHA256SUMS; do
    [[ -r $PROJECT_ROOT/dist/$artifact ]] || die "artefato ausente: dist/$artifact"
done

load_lab_config "$PROJECT_ROOT/dist/runtime.conf"
validate_lab_values
level=$(config_get DEFAULT_LEVEL)

test_root=$(mktemp -d -t kernel-ctf-launcher.XXXXXXXX)
[[ -d $test_root && ! -L $test_root ]] || die "mktemp não criou um diretório seguro"
[[ $(stat -c '%a' -- "$test_root") == 700 ]] || \
    die "diretório temporário do launcher não tem modo 0700"
runtime_dir=$test_root/runtime
log_file=$test_root/launcher.log
mkdir -m 0700 -- "$runtime_dir"

cleanup()
{
    trap - EXIT HUP INT TERM
    if [[ -n ${test_root:-} && -d $test_root && ! -L $test_root && \
          $(basename -- "$test_root") == kernel-ctf-launcher.* ]]; then
        rm -rf -- "$test_root"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log_info "validando o fluxo real do launcher no nível padrão $level"
set +e
timeout --foreground --signal=TERM --kill-after=5s 90s \
    env KERNEL_CTF_RUNTIME_DIR="$runtime_dir" \
    bash "$PROJECT_ROOT/bin/kernel-ctf-session" --self-test \
    </dev/null >"$log_file" 2>&1
launcher_status=$?
set -e

if [[ $launcher_status -ne 0 ]]; then
    cat "$log_file" >&2
    die "autoteste do launcher terminou com status $launcher_status"
fi

if ! grep -Fq 'SELFTEST: PASS' "$log_file" ||
   ! grep -Fq 'SELFTEST: KVULN_OVERSIZED_READ=PASS' "$log_file" ||
   ! grep -Fq "SELFTEST: LEVEL_POLICY_$level=PASS" "$log_file" ||
   ! grep -Fq 'acesso à flag=negado' "$log_file" ||
   ! grep -Fq 'autoteste do launcher encerrado; estado descartado' "$log_file"; then
    cat "$log_file" >&2
    die "launcher não confirmou política, identidade, flag negada e descarte"
fi
if grep -Fq 'Unknown kernel command line parameters' "$log_file"; then
    cat "$log_file" >&2
    die "launcher passou parâmetros desconhecidos ao kernel"
fi
for leftover_session in "$runtime_dir"/session.*; do
    [[ ! -e $leftover_session && ! -L $leftover_session ]] || \
        die "launcher deixou diretório de sessão após o autoteste: $leftover_session"
done
lock_seen=0
for slot_lock in "$runtime_dir"/slot.*.lock; do
    [[ -f $slot_lock && ! -L $slot_lock ]] || continue
    exec {probe_fd}>"$slot_lock"
    flock -n "$probe_fd" || die "launcher deixou o slot bloqueado: $slot_lock"
    exec {probe_fd}>&-
    lock_seen=1
done
((lock_seen == 1)) || die "launcher não criou nenhum lock de slot durante o autoteste"

log_ok "launcher real validado no nível padrão $level"
