#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"
assert_project_root "$PROJECT_ROOT"
require_non_root

LEVEL=''
FLAG_SOURCE=''
READ_FLAG_STDIN=0
READ_FLAG_PROMPT=0
flag_input_tmp=''
config_tmp=''
flag_tmp=''

cleanup_configure()
{
    local status=$? temporary
    trap - EXIT HUP INT TERM
    for temporary in "${flag_input_tmp:-}" "${config_tmp:-}" "${flag_tmp:-}"; do
        case "$temporary" in
            "$PROJECT_ROOT"/config/.flag-input.*|"$PROJECT_ROOT"/config/lab.conf.*|"$PROJECT_ROOT"/config/flag.txt.*)
                rm -f -- "$temporary" || \
                    log_warn "não foi possível remover o temporário: $temporary"
                ;;
        esac
    done
    exit "$status"
}
trap cleanup_configure EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

usage()
{
    cat <<'EOF'
Uso:
  ./configure.sh --level 0..4
  ./configure.sh --flag-file /caminho/flag.txt
  comando_que_emite_a_flag | ./configure.sh --flag-stdin
  ./configure.sh --flag-prompt

As opções podem ser combinadas. Depois, execute ./reset.sh.
Use --flag-prompt para não gravar a flag no histórico do shell.
EOF
}

while (($# > 0)); do
    case "$1" in
        --level)
            (($# >= 2)) || die "--level exige um valor"
            LEVEL=$2
            shift 2
            ;;
        --flag-file)
            (($# >= 2)) || die "--flag-file exige um caminho"
            FLAG_SOURCE=$2
            shift 2
            ;;
        --flag-stdin)
            READ_FLAG_STDIN=1
            shift
            ;;
        --flag-prompt)
            READ_FLAG_PROMPT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "opção desconhecida: $1" ;;
    esac
done

[[ -n $LEVEL || -n $FLAG_SOURCE || $READ_FLAG_STDIN -eq 1 || $READ_FLAG_PROMPT -eq 1 ]] || {
    usage
    exit 2
}

flag_source_count=0
[[ -z $FLAG_SOURCE ]] || ((flag_source_count += 1))
((READ_FLAG_STDIN == 0)) || ((flag_source_count += 1))
((READ_FLAG_PROMPT == 0)) || ((flag_source_count += 1))
((flag_source_count <= 1)) || die "use apenas uma origem para a flag"

flag_value_ready=0
if ((flag_source_count == 1)); then
    declare -a lines=()
    flag_read_path=''
    if [[ -n $FLAG_SOURCE ]]; then
        [[ -f $FLAG_SOURCE && ! -L $FLAG_SOURCE && -r $FLAG_SOURCE ]] || \
            die "--flag-file exige um arquivo regular, não simbólico e legível: $FLAG_SOURCE"
        flag_source_owner=$(stat -c '%u' -- "$FLAG_SOURCE") || \
            die "não foi possível consultar o dono de $FLAG_SOURCE"
        flag_source_mode=$(stat -c '%a' -- "$FLAG_SOURCE") || \
            die "não foi possível consultar as permissões de $FLAG_SOURCE"
        [[ $flag_source_owner == "$(id -u)" ]] || \
            die "o arquivo informado em --flag-file deve pertencer ao usuário atual"
        (( (8#$flag_source_mode & 077) == 0 )) || \
            die "o arquivo informado em --flag-file não pode conceder acesso a grupo ou outros"
        flag_read_path=$FLAG_SOURCE
    elif ((READ_FLAG_STDIN == 1)); then
        flag_input_tmp=$(mktemp "$PROJECT_ROOT/config/.flag-input.XXXXXXXX")
        chmod 0600 "$flag_input_tmp"
        cat > "$flag_input_tmp" || die "não foi possível receber a flag pela entrada padrão"
        flag_read_path=$flag_input_tmp
    else
        [[ -t 0 ]] || die "--flag-prompt exige um terminal interativo"
        if ! IFS= read -r -s -p 'Digite a flag: ' flag_value; then
            printf '\n' >&2
            die "leitura da flag foi cancelada"
        fi
        printf '\n' >&2
        lines=("$flag_value")
    fi

    if [[ -n $flag_read_path ]]; then
        if IFS= read -r -d '' _ < "$flag_read_path"; then
            die "a flag contém byte NUL inválido"
        fi
        mapfile -t lines < "$flag_read_path"
    fi

    [[ ${#lines[@]} -eq 1 && -n ${lines[0]} ]] || {
        die "a flag deve conter exatamente uma linha não vazia"
    }

    # Arquivos CRLF vindos de Windows são normalizados para LF. Qualquer outro
    # caractere de controle é rejeitado para a flag não mudar silenciosamente.
    flag_value=${lines[0]%$'\r'}
    [[ -n $flag_value ]] || die "a flag não pode ser vazia"
    [[ ! $flag_value =~ [[:cntrl:]] ]] || \
        die "a flag contém caractere de controle inválido"
    (( ${#flag_value} <= 512 )) || die "a flag não pode exceder 512 caracteres"
    flag_value_ready=1
fi

if [[ -n $LEVEL ]]; then
    require_uint_range level "$LEVEL" 0 4
    config_tmp=$(mktemp "$PROJECT_ROOT/config/lab.conf.XXXXXXXX")
    awk -v level="$LEVEL" '
        BEGIN { found = 0 }
        /^DEFAULT_LEVEL=/ { print "DEFAULT_LEVEL=" level; found = 1; next }
        { print }
        END { if (!found) exit 42 }
    ' "$PROJECT_ROOT/config/lab.conf" > "$config_tmp" || {
        rm -f -- "$config_tmp"
        die "não foi possível atualizar DEFAULT_LEVEL"
    }
    chmod 0644 "$config_tmp"
    mv -f -- "$config_tmp" "$PROJECT_ROOT/config/lab.conf"
    config_tmp=''
    log_ok "nível padrão alterado para $LEVEL"
fi

if ((flag_value_ready == 1)); then
    flag_tmp=$(mktemp "$PROJECT_ROOT/config/flag.txt.XXXXXXXX")
    printf '%s\n' "$flag_value" > "$flag_tmp"
    chmod 0600 "$flag_tmp"
    mv -f -- "$flag_tmp" "$PROJECT_ROOT/config/flag.txt"
    flag_tmp=''
    log_ok "flag instalada em config/flag.txt (conteúdo não exibido)"
fi

log_info "execute ./reset.sh para reconstruir todos os artefatos"
