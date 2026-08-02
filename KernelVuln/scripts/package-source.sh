#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

assert_project_root "$PROJECT_ROOT"

MANIFEST=$PROJECT_ROOT/config/source-files.list
ARCHIVE=$PROJECT_ROOT/kernel-ctf-source.tar.xz
CHECKSUM=$ARCHIVE.sha256
MODE=${1:-create}

case "$MODE" in
    create|--check|--self-test) ;;
    *) die "uso: $0 [--check|--self-test]" ;;
esac
(($# <= 1)) || die "argumentos em excesso"

[[ -f $MANIFEST && ! -L $MANIFEST && -r $MANIFEST ]] || \
    die "manifesto de fontes ausente ou inseguro: $MANIFEST"

declare -A seen=()
declare -a source_files=()
while IFS= read -r entry || [[ -n $entry ]]; do
    [[ -n $entry && $entry != \#* ]] || continue
    [[ $entry =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $entry != -* ]] || \
        die "entrada inválida no manifesto de fontes: $entry"
    [[ /$entry/ != */../* && /$entry/ != */./* && $entry != */ ]] || \
        die "caminho inseguro no manifesto de fontes: $entry"
    [[ ! -v "seen[$entry]" ]] || die "entrada duplicada no manifesto de fontes: $entry"
    seen[$entry]=1

    case "$entry" in
        config/flag.txt.example) ;;
        config/flag.txt|config/flag.txt.*|config/.flag-input.*|config/lab.conf.*|\
        docs/INSTRUCTOR-SOLUTIONS.md|\
        build/*|dist/*|downloads/*|.git/*|.agents/*|.codex/*|\
        kernel-ctf-source.tar.xz|kernel-ctf-source.tar.xz.sha256|.kernel-ctf-source.*|\
        challenge/*.ko|challenge/*.o|challenge/*.mod|challenge/*.mod.c|\
        challenge/*.order|challenge/*.symvers|challenge/.*.cmd)
            die "entrada privada ou gerada no manifesto de fontes: $entry"
            ;;
    esac

    [[ -f $PROJECT_ROOT/$entry && ! -L $PROJECT_ROOT/$entry && -r $PROJECT_ROOT/$entry ]] || \
        die "fonte ausente, ilegível ou não regular: $entry"
    source_files+=("$entry")
done < "$MANIFEST"

((${#source_files[@]} > 0)) || die "manifesto de fontes vazio"
for required in .gitattributes .gitignore .kernel-ctf-project config/flag.txt.example; do
    [[ -v "seen[$required]" ]] || die "arquivo obrigatório ausente do pacote-fonte: $required"
done

if [[ $MODE == --check ]]; then
    log_ok "manifesto do pacote-fonte validado (${#source_files[@]} arquivos)"
    exit 0
fi

for command_name in tar xz sha256sum mktemp install rm; do
    command -v "$command_name" >/dev/null 2>&1 || \
        die "dependência ausente para o pacote-fonte: $command_name"
done
if [[ $MODE == create ]]; then
    for command_name in mv chmod; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "dependência ausente para o pacote-fonte: $command_name"
    done
fi

if [[ $MODE == create ]]; then
    for output_file in "$ARCHIVE" "$CHECKSUM"; do
        if [[ -e $output_file || -L $output_file ]]; then
            [[ -f $output_file && ! -L $output_file ]] || \
                die "saída do pacote-fonte deve ser arquivo regular: $output_file"
        fi
    done
fi
stage_root=
archive_tmp=
checksum_tmp=
cleanup_source_package()
{
    [[ -z $archive_tmp ]] || rm -f -- "$archive_tmp"
    [[ -z $checksum_tmp ]] || rm -f -- "$checksum_tmp"
    if [[ -n $stage_root ]]; then
        if [[ $stage_root == "$PROJECT_ROOT"/.kernel-ctf-source-stage.* &&
              -d $stage_root && ! -L $stage_root ]]; then
            rm -rf -- "$stage_root"
        else
            log_warn "recusando limpar staging inesperado: $stage_root"
        fi
    fi
}
trap cleanup_source_package EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

stage_root=$(mktemp -d --tmpdir="$PROJECT_ROOT" .kernel-ctf-source-stage.XXXXXX)
[[ $stage_root == "$PROJECT_ROOT"/.kernel-ctf-source-stage.* &&
   -d $stage_root && ! -L $stage_root ]] || die "staging inseguro para o pacote-fonte"
archive_tmp=$(mktemp --tmpdir="$PROJECT_ROOT" .kernel-ctf-source.XXXXXX.tar.xz)

for entry in "${source_files[@]}"; do
    parent=${entry%/*}
    if [[ $parent != "$entry" ]]; then
        install -d -m 0755 "$stage_root/$parent"
    fi
    first_line=
    IFS= read -r first_line < "$PROJECT_ROOT/$entry" || true
    source_mode=0644
    [[ $first_line == '#!'* ]] && source_mode=0755
    install -m "$source_mode" "$PROJECT_ROOT/$entry" "$stage_root/$entry"
done

unset TAR_OPTIONS XZ_OPT XZ_DEFAULTS
export LC_ALL=C
tar --format=gnu --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    --mode='u=rwX,go=rX' --no-recursion \
    -C "$stage_root" -cJf "$archive_tmp" -- "${source_files[@]}"
archive_listing=$(tar -tJf "$archive_tmp") || die "pacote-fonte gerado é inválido"
mapfile -t archived_files <<<"$archive_listing"

((${#archived_files[@]} == ${#source_files[@]})) || \
    die "inventário do pacote-fonte diverge do manifesto"
declare -A archived_seen=()
for entry in "${archived_files[@]}"; do
    [[ -v "seen[$entry]" ]] || die "entrada inesperada no pacote-fonte: $entry"
    [[ ! -v "archived_seen[$entry]" ]] || die "entrada duplicada no pacote-fonte: $entry"
    archived_seen[$entry]=1
done
for entry in "${source_files[@]}"; do
    [[ -v "archived_seen[$entry]" ]] || die "entrada ausente do pacote-fonte: $entry"
done
sha256sum "$archive_tmp" >/dev/null || die "não foi possível calcular o checksum do pacote-fonte"

if [[ $MODE == --self-test ]]; then
    log_ok "pacote-fonte temporário validado (${#archived_files[@]} arquivos)"
    exit 0
fi

checksum_tmp=$(mktemp --tmpdir="$PROJECT_ROOT" .kernel-ctf-source.XXXXXX.sha256)
mv -f -- "$archive_tmp" "$ARCHIVE"
chmod 0644 "$ARCHIVE"
(
    cd "$PROJECT_ROOT"
    sha256sum "${ARCHIVE##*/}" > "$checksum_tmp"
)
mv -f -- "$checksum_tmp" "$CHECKSUM"
chmod 0644 "$CHECKSUM"
cleanup_source_package
stage_root=
archive_tmp=
checksum_tmp=
trap - EXIT HUP INT TERM

log_ok "pacote-fonte criado: $ARCHIVE"
log_ok "checksum criado: $CHECKSUM"
