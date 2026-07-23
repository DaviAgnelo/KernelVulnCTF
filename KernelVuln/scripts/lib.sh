#!/usr/bin/env bash

# Biblioteca comum. Os chamadores devem habilitar: set -Eeuo pipefail.

log_info()
{
    printf '[*] %s\n' "$*"
}

log_ok()
{
    printf '[+] %s\n' "$*"
}

log_warn()
{
    printf '[!] %s\n' "$*" >&2
}

die()
{
    printf '[ERRO] %s\n' "$*" >&2
    exit 1
}

require_root()
{
    [[ $(id -u) -eq 0 ]] || die "execute este script como root (use sudo)"
}

require_non_root()
{
    [[ $(id -u) -ne 0 ]] || die "recusando executar esta operação como root"
}

declare -Ag LAB_CONFIG=()

load_lab_config()
{
    local config_file=$1
    local line key value line_number=0

    [[ -r $config_file ]] || die "configuração não legível: $config_file"
    LAB_CONFIG=()

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        line=${line%$'\r'}
        [[ -z $line || $line == \#* ]] && continue

        if [[ ! $line =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9._:/+-]+)$ ]]; then
            die "linha inválida em $config_file:$line_number (use KEY=VALUE simples)"
        fi

        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        [[ ! -v "LAB_CONFIG[$key]" ]] || die "chave duplicada em $config_file: $key"
        LAB_CONFIG[$key]=$value
    done < "$config_file"
}

config_get()
{
    local key=$1
    local default_value=${2-}

    if [[ -v "LAB_CONFIG[$key]" ]]; then
        printf '%s' "${LAB_CONFIG[$key]}"
    else
        printf '%s' "$default_value"
    fi
}

require_config_keys()
{
    local key
    for key in "$@"; do
        [[ -v "LAB_CONFIG[$key]" ]] || die "chave obrigatória ausente na configuração: $key"
    done
}

require_uint_range()
{
    local label=$1 value=$2 minimum=$3 maximum=$4
    [[ $value =~ ^[0-9]+$ ]] || die "$label deve ser um número inteiro"
    ((10#$value >= minimum && 10#$value <= maximum)) || \
        die "$label deve estar entre $minimum e $maximum"
}

require_debian_bookworm()
{
    local os_id='' codename='' key value

    [[ -r /etc/os-release ]] || die "/etc/os-release não existe; Debian 12 é obrigatório"
    while IFS='=' read -r key value; do
        value=${value#\"}
        value=${value%\"}
        case "$key" in
            ID) os_id=$value ;;
            VERSION_CODENAME) codename=$value ;;
        esac
    done < /etc/os-release

    [[ $os_id == debian && $codename == bookworm ]] || \
        die "host não suportado: esperado Debian 12 Bookworm; detectado ID=$os_id CODENAME=$codename"
}

assert_project_root()
{
    local project_root=$1
    [[ -f $project_root/.kernel-ctf-project ]] || \
        die "marcador .kernel-ctf-project ausente em $project_root"
    [[ $(<"$project_root/.kernel-ctf-project") == kernel-ctf-lab-debian12 ]] || \
        die "marcador de projeto inválido em $project_root"
}

validate_lab_values()
{
    local level memory vcpus sessions timeout_seconds vmem minimum_vmem
    local acceleration kernel_version checksum

    require_config_keys CHALLENGE_NAME DEFAULT_LEVEL MEMORY_MIB VCPUS MAX_SESSIONS \
        SESSION_TIMEOUT_SECONDS HOST_VMEM_KIB ACCELERATION KERNEL_VERSION KERNEL_SHA256

    level=$(config_get DEFAULT_LEVEL)
    memory=$(config_get MEMORY_MIB)
    vcpus=$(config_get VCPUS)
    sessions=$(config_get MAX_SESSIONS)
    timeout_seconds=$(config_get SESSION_TIMEOUT_SECONDS)
    vmem=$(config_get HOST_VMEM_KIB)
    acceleration=$(config_get ACCELERATION)
    kernel_version=$(config_get KERNEL_VERSION)
    checksum=$(config_get KERNEL_SHA256)

    require_uint_range DEFAULT_LEVEL "$level" 0 4
    require_uint_range MEMORY_MIB "$memory" 128 2048
    require_uint_range VCPUS "$vcpus" 1 8
    require_uint_range MAX_SESSIONS "$sessions" 1 64
    require_uint_range SESSION_TIMEOUT_SECONDS "$timeout_seconds" 60 86400
    require_uint_range HOST_VMEM_KIB "$vmem" 524288 16777216
    minimum_vmem=$((10#$memory * 1024 + 524288))
    ((10#$vmem >= minimum_vmem)) || \
        die "HOST_VMEM_KIB deve comportar MEMORY_MIB mais 512 MiB de margem (mínimo: $minimum_vmem)"
    [[ $acceleration == auto || $acceleration == kvm || $acceleration == tcg ]] || \
        die "ACCELERATION deve ser auto, kvm ou tcg"
    [[ $kernel_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "KERNEL_VERSION inválido: $kernel_version"
    [[ $checksum =~ ^[0-9a-f]{64}$ ]] || die "KERNEL_SHA256 deve ter 64 dígitos hexadecimais"
    [[ $(config_get CHALLENGE_NAME) =~ ^[A-Za-z0-9._-]+$ ]] || \
        die "CHALLENGE_NAME contém caracteres inválidos"
}

# Fonte única da matriz de níveis. Tanto o launcher quanto o teste de boot usam
# estes valores para não divergirem silenciosamente.
set_level_profile()
{
    local level=$1

    case "$level" in
        0)
            LEVEL_CPU_MODEL='qemu64,-smep,-smap'
            LEVEL_KERNEL_ARGS='nokaslr pti=off'
            ;;
        1)
            LEVEL_CPU_MODEL='qemu64,+smep,-smap'
            LEVEL_KERNEL_ARGS='nokaslr pti=off'
            ;;
        2)
            LEVEL_CPU_MODEL='qemu64,+smep,-smap'
            LEVEL_KERNEL_ARGS='pti=off'
            ;;
        3)
            LEVEL_CPU_MODEL='qemu64,+smep,+smap'
            LEVEL_KERNEL_ARGS='pti=off'
            ;;
        4)
            LEVEL_CPU_MODEL='qemu64,+smep,+smap'
            LEVEL_KERNEL_ARGS='pti=on'
            ;;
        *) die "nível inválido para o perfil QEMU: $level" ;;
    esac
}
