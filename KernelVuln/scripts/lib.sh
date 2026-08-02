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

require_bash_44()
{
    if ((BASH_VERSINFO[0] < 4 ||
         (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
        die "Bash 4.4 ou superior é obrigatório (detectado: $BASH_VERSION)"
    fi
}

# Bash 4.4 é o menor denominador comum dos perfis suportados e já oferece os
# recursos usados aqui (arrays associativos, mapfile e read -d). Falhar ao
# carregar a biblioteca é mais seguro do que prosseguir com outra semântica.
require_bash_44

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

PLATFORM_DETECTED=0
PLATFORM_KERNEL=''
PLATFORM_MACHINE=''
PLATFORM_ARCH=''
PLATFORM_ID='unknown'
PLATFORM_ID_LIKE=''
PLATFORM_VERSION_ID=''
PLATFORM_FAMILY='generic'
PLATFORM_PACKAGE_MANAGER=''

platform_has_token()
{
    local expected=$1 candidate
    local -a platform_tokens=()

    read -r -a platform_tokens <<<"$PLATFORM_ID $PLATFORM_ID_LIKE"
    for candidate in "${platform_tokens[@]}"; do
        [[ $candidate == "$expected" ]] && return 0
    done
    return 1
}

classify_linux_platform()
{
    local package_manager

    PLATFORM_FAMILY=generic
    PLATFORM_PACKAGE_MANAGER=''
    if platform_has_token debian || platform_has_token ubuntu ||
       platform_has_token linuxmint || platform_has_token pop ||
       platform_has_token kali || platform_has_token raspbian; then
        PLATFORM_FAMILY=debian
        PLATFORM_PACKAGE_MANAGER=apt-get
    elif platform_has_token fedora || platform_has_token rhel ||
         platform_has_token centos || platform_has_token rocky ||
         platform_has_token almalinux || platform_has_token ol ||
         platform_has_token amzn; then
        PLATFORM_FAMILY=fedora-rhel
        if command -v dnf >/dev/null 2>&1; then
            PLATFORM_PACKAGE_MANAGER=dnf
        elif command -v yum >/dev/null 2>&1; then
            PLATFORM_PACKAGE_MANAGER=yum
        else
            PLATFORM_PACKAGE_MANAGER=dnf
        fi
    elif platform_has_token arch || platform_has_token manjaro ||
         platform_has_token endeavouros; then
        PLATFORM_FAMILY=arch
        PLATFORM_PACKAGE_MANAGER=pacman
    elif platform_has_token suse || platform_has_token opensuse ||
         platform_has_token sles || platform_has_token sled ||
         platform_has_token opensuse-leap ||
         platform_has_token opensuse-tumbleweed; then
        PLATFORM_FAMILY=suse
        PLATFORM_PACKAGE_MANAGER=zypper
    else
        for package_manager in apt-get dnf yum pacman zypper; do
            if command -v "$package_manager" >/dev/null 2>&1; then
                PLATFORM_PACKAGE_MANAGER=$package_manager
                break
            fi
        done
    fi
}

detect_linux_platform()
{
    local line key value first_character last_character os_release_file=''

    ((PLATFORM_DETECTED == 0)) || return 0
    command -v uname >/dev/null 2>&1 || die "dependência básica ausente: uname"

    PLATFORM_KERNEL=$(uname -s) || die "não foi possível detectar o sistema operacional"
    PLATFORM_MACHINE=$(uname -m) || die "não foi possível detectar a arquitetura"
    case "$PLATFORM_MACHINE" in
        x86_64|amd64) PLATFORM_ARCH=x86_64 ;;
        *) PLATFORM_ARCH=$PLATFORM_MACHINE ;;
    esac

    if [[ -r /etc/os-release ]]; then
        os_release_file=/etc/os-release
    elif [[ -r /usr/lib/os-release ]]; then
        os_release_file=/usr/lib/os-release
    fi
    if [[ -n $os_release_file ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
            key=${BASH_REMATCH[1]}
            value=${BASH_REMATCH[2]}
            if ((${#value} >= 2)); then
                first_character=${value:0:1}
                last_character=${value: -1}
                if [[ ($first_character == '"' && $last_character == '"') ||
                      ($first_character == "'" && $last_character == "'") ]]; then
                    value=${value:1:${#value}-2}
                fi
            fi

            case "$key" in
                ID)
                    value=${value,,}
                    [[ $value =~ ^[a-z0-9._-]+$ ]] && PLATFORM_ID=$value
                    ;;
                ID_LIKE)
                    value=${value,,}
                    value=${value//$'\t'/ }
                    [[ $value =~ ^[a-z0-9._[:space:]-]*$ ]] && PLATFORM_ID_LIKE=$value
                    ;;
                VERSION_ID)
                    [[ $value =~ ^[A-Za-z0-9._+-]+$ ]] && PLATFORM_VERSION_ID=$value
                    ;;
            esac
        done < "$os_release_file"
    fi

    classify_linux_platform
    PLATFORM_DETECTED=1
}

require_linux_x86_64()
{
    require_bash_44
    detect_linux_platform
    [[ $PLATFORM_KERNEL == Linux ]] || \
        die "host não suportado: Linux x86_64 é obrigatório (detectado: $PLATFORM_KERNEL/$PLATFORM_MACHINE)"
    [[ $PLATFORM_ARCH == x86_64 ]] || \
        die "arquitetura não suportada: x86_64 é obrigatória (detectado: $PLATFORM_MACHINE)"
}

resolve_qemu_x86_64()
{
    local candidate resolved
    local -a qemu_candidates=()

    for candidate in qemu-system-x86_64 qemu-kvm; do
        resolved=$(type -P "$candidate" 2>/dev/null || true)
        [[ -n $resolved ]] && qemu_candidates+=("$resolved")
    done
    qemu_candidates+=(/usr/bin/qemu-system-x86_64 /usr/bin/qemu-kvm
        /usr/libexec/qemu-kvm)

    for candidate in "${qemu_candidates[@]}"; do
        [[ -f $candidate && -x $candidate ]] || continue
        resolved=$(readlink -f -- "$candidate" 2>/dev/null) || continue
        [[ -n $resolved && -f $resolved && -x $resolved ]] || continue
        printf '%s\n' "$resolved"
        return 0
    done
    return 1
}

require_systemd_host()
{
    local pid1_comm=''

    require_linux_x86_64
    command -v systemctl >/dev/null 2>&1 || \
        die "a instalação do host exige systemctl"
    command -v systemd-tmpfiles >/dev/null 2>&1 || \
        die "a instalação do host exige systemd-tmpfiles"
    if [[ -r /proc/1/comm ]]; then
        IFS= read -r pid1_comm < /proc/1/comm || \
            die "não foi possível identificar o PID 1"
    fi
    [[ $pid1_comm == systemd && -d /run/systemd/system ]] || \
        die "a instalação do host exige systemd ativo como PID 1; build e runtime não possuem essa exigência"
}

assert_project_root()
{
    local project_root=$1 marker_value
    [[ -f $project_root/.kernel-ctf-project &&
       ! -L $project_root/.kernel-ctf-project &&
       -r $project_root/.kernel-ctf-project ]] || \
        die "marcador .kernel-ctf-project ausente ou inseguro em $project_root; a cópia provavelmente omitiu arquivos ocultos (não transfira KernelVuln/*)"
    marker_value=$(<"$project_root/.kernel-ctf-project")
    case "$marker_value" in
        kernel-ctf-lab-v1) ;;
        kernel-ctf-lab-debian12)
            log_warn "marcador legado detectado; migre .kernel-ctf-project para kernel-ctf-lab-v1"
            ;;
        *) die "marcador de projeto inválido em $project_root" ;;
    esac
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
