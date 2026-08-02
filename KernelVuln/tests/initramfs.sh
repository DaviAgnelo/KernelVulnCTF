#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"
assert_project_root "$PROJECT_ROOT"
require_linux_x86_64
require_non_root

for required_command in cpio gzip sha256sum stat tar; do
    command -v "$required_command" >/dev/null 2>&1 || \
        die "dependencia do teste ausente: $required_command"
done

archive=$PROJECT_ROOT/dist/initramfs.cpio.gz
[[ -r $archive ]] || die "artefato ausente: dist/initramfs.cpio.gz"
[[ $(stat -c '%a' -- "$PROJECT_ROOT/dist") == 700 ]] || \
    die "dist/ deve ter modo 0700 por conter o initramfs com a flag"
[[ $(stat -c '%a' -- "$archive") == 600 ]] || \
    die "dist/initramfs.cpio.gz deve ter modo 0600"
gzip -t -- "$archive" || die "dist/initramfs.cpio.gz nao e um gzip valido"

work_dir=$(mktemp -d -t kernel-ctf-initramfs-test.XXXXXXXX)
[[ -d $work_dir && ! -L $work_dir ]] || die "mktemp nao criou um diretorio seguro"
[[ $(stat -c '%a' -- "$work_dir") == 700 ]] || \
    die "diretorio temporario do teste nao tem modo 0700"
listing_file=$work_dir/initramfs.list
verbose_listing_file=$work_dir/initramfs.verbose.list

cleanup()
{
    trap - EXIT HUP INT TERM
    if [[ -n ${work_dir:-} && -d $work_dir && ! -L $work_dir && \
          $(basename -- "$work_dir") == kernel-ctf-initramfs-test.* ]]; then
        rm -rf -- "$work_dir"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

gzip -dc -- "$archive" | cpio --list --quiet > "$listing_file"
gzip -dc -- "$archive" | \
    cpio --list --verbose --numeric-uid-gid --quiet > "$verbose_listing_file"

if grep -Eq '(^/|(^|/)\.\.(/|$))' "$listing_file"; then
    die "initramfs contem caminho absoluto ou travessia por .."
fi
if awk '$1 ~ /^[bcps]/ { found = 1 } END { exit(found ? 0 : 1) }' \
    "$verbose_listing_file"; then
    die "initramfs contem device, socket ou FIFO persistente inesperado"
fi

assert_present()
{
    local relative_path=$1
    grep -Fqx -- "$relative_path" "$listing_file" ||
        grep -Fqx -- "./$relative_path" "$listing_file" ||
        die "arquivo obrigatorio ausente do initramfs: /$relative_path"
}

archive_owner()
{
    local relative_path=$1
    awk -v plain="$relative_path" -v dotted="./$relative_path" '
        $NF == plain || $NF == dotted { print $3 ":" $4; found = 1; exit }
        END { if (!found) exit 1 }
    ' "$verbose_listing_file"
}

archive_permissions()
{
    local relative_path=$1
    awk -v plain="$relative_path" -v dotted="./$relative_path" '
        $NF == plain || $NF == dotted { print $1; found = 1; exit }
        END { if (!found) exit 1 }
    ' "$verbose_listing_file"
}

assert_mode_in_archive()
{
    local relative_path=$1 expected=$2 actual
    actual=$(archive_permissions "$relative_path") || \
        die "nao foi possivel obter o modo de /$relative_path no initramfs"
    [[ $actual == "$expected" ]] || \
        die "/$relative_path tem modo $actual no initramfs; esperado $expected"
}

assert_root_owned_in_archive()
{
    local relative_path=$1 owner
    owner=$(archive_owner "$relative_path") || \
        die "nao foi possivel obter UID/GID de /$relative_path no initramfs"
    [[ $owner == 0:0 ]] || \
        die "/$relative_path deve pertencer a root:root no initramfs (atual: $owner)"
}

assert_ctf_executable_not_writable()
{
    local relative_path=$1
    assert_present "$relative_path"
    assert_root_owned_in_archive "$relative_path"
    assert_mode_in_archive "$relative_path" -rwxr-xr-x
}

for required_path in init bin/busybox sbin/ctf-login etc/passwd etc/group \
    etc/challenge-name home/ctf/.profile bin/upload lib/modules/kvuln.ko \
    root/flag.txt; do
    assert_present "$required_path"
done

assert_mode_in_archive . drwxr-xr-x
for public_directory in bin sbin etc lib; do
    assert_mode_in_archive "$public_directory" drwxr-xr-x
done
assert_mode_in_archive home/ctf drwx------
assert_mode_in_archive root drwx------
assert_mode_in_archive root/flag.txt -r--------
assert_root_owned_in_archive root/flag.txt
assert_ctf_executable_not_writable init
assert_ctf_executable_not_writable bin/busybox
assert_ctf_executable_not_writable bin/upload
assert_ctf_executable_not_writable sbin/ctf-login

handout=$PROJECT_ROOT/dist/player-handout.tar.xz
if [[ -e $handout ]]; then
    [[ -f $handout && ! -L $handout ]] || \
        die "dist/player-handout.tar.xz deve ser um arquivo regular"
    handout_checksum=$PROJECT_ROOT/dist/player-handout.tar.xz.sha256
    [[ -f $handout_checksum && ! -L $handout_checksum ]] || \
        die "checksum do handout ausente ou inseguro"
    (
        cd "$PROJECT_ROOT/dist"
        sha256sum --check --strict player-handout.tar.xz.sha256
    ) || die "checksum do handout divergiu"
    handout_listing=$work_dir/player-handout.list
    tar -tf "$handout" > "$handout_listing" || die "handout nao e um tar.xz valido"
    if grep -Eiq '(^|/)[^/]*(initramfs|flag)[^/]*($|/)' "$handout_listing"; then
        die "handout contem initramfs ou arquivo de flag"
    fi
    if grep -Eiq '(^|/)[^/]*(solution|solucao|instructor)[^/]*($|/)' "$handout_listing"; then
        die "handout contem material reservado de instrutor ou solucao"
    fi

    # Se a flag local ainda estiver disponivel, garante tambem que seu valor nao
    # foi copiado para dentro de nenhum membro regular do handout.
    if [[ -r $PROJECT_ROOT/config/flag.txt ]]; then
        IFS= read -r flag_value < "$PROJECT_ROOT/config/flag.txt" || true
        if [[ -n ${flag_value:-} ]] && \
            tar -xOf "$handout" 2>/dev/null | grep -aF -- "$flag_value" >/dev/null; then
            die "handout contem o valor da flag configurada"
        fi
    fi
fi

log_ok "initramfs inspecionado com arvore, modos e isolamento do handout validados"
