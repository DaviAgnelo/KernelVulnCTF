#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"

assert_project_root "$PROJECT_ROOT"
require_non_root
require_linux_x86_64
load_lab_config "$PROJECT_ROOT/config/lab.conf"
validate_lab_values

MODE=${1:-all}
case "$MODE" in
    all|kernel|module|initramfs|handout) ;;
    *) die "uso: $0 [all|kernel|module|initramfs|handout]" ;;
esac

bash "$PROJECT_ROOT/scripts/check-deps.sh" build

KERNEL_VERSION=$(config_get KERNEL_VERSION)
KERNEL_SHA256=$(config_get KERNEL_SHA256)
DOWNLOAD_DIR=$PROJECT_ROOT/downloads
BUILD_DIR=$PROJECT_ROOT/build
DIST_DIR=$PROJECT_ROOT/dist
KERNEL_ARCHIVE=$DOWNLOAD_DIR/linux-$KERNEL_VERSION.tar.xz
KERNEL_SOURCE=$BUILD_DIR/linux-$KERNEL_VERSION
KERNEL_OUTPUT=$BUILD_DIR/kernel-output
MODULE_BUILD=$BUILD_DIR/module-source
HANDOUT_BUILD=$BUILD_DIR/player-handout
KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz
JOBS=$(nproc)

mkdir -p "$DOWNLOAD_DIR" "$BUILD_DIR"
install -d -m 0700 "$DIST_DIR"

verify_kernel_archive()
{
    local actual_checksum
    actual_checksum=$(sha256sum "$KERNEL_ARCHIVE" | awk '{print $1}')
    [[ $actual_checksum == "$KERNEL_SHA256" ]] || \
        die "checksum inválido para $KERNEL_ARCHIVE (esperado $KERNEL_SHA256; obtido $actual_checksum)"
}

download_kernel()
{
    if [[ -f $KERNEL_ARCHIVE ]]; then
        log_info "validando tarball em cache"
        verify_kernel_archive
        return
    fi

    log_info "baixando Linux $KERNEL_VERSION de kernel.org"
    wget --https-only --secure-protocol=TLSv1_2 --output-document "$KERNEL_ARCHIVE.tmp" "$KERNEL_URL" || {
        rm -f -- "$KERNEL_ARCHIVE.tmp"
        die "download do kernel falhou: $KERNEL_URL"
    }
    mv -f -- "$KERNEL_ARCHIVE.tmp" "$KERNEL_ARCHIVE"
    verify_kernel_archive
}

prepare_kernel_source()
{
    download_kernel
    if [[ ! -d $KERNEL_SOURCE ]]; then
        log_info "extraindo fonte verificada do kernel"
        tar -C "$BUILD_DIR" -xf "$KERNEL_ARCHIVE"
    fi
    [[ -x $KERNEL_SOURCE/scripts/config ]] || die "árvore do kernel incompleta: $KERNEL_SOURCE"
}

build_kernel()
{
    prepare_kernel_source
    log_info "configurando Linux $KERNEL_VERSION para o laboratório"
    make -C "$KERNEL_SOURCE" O="$KERNEL_OUTPUT" ARCH=x86_64 defconfig

    "$KERNEL_SOURCE/scripts/config" --file "$KERNEL_OUTPUT/.config" \
        -e CONFIG_64BIT \
        -e CONFIG_BLK_DEV_INITRD \
        -e CONFIG_RD_GZIP \
        -e CONFIG_BINFMT_ELF \
        -e CONFIG_BINFMT_SCRIPT \
        -e CONFIG_SYSCTL \
        -e CONFIG_PRINTK \
        -e CONFIG_TTY \
        -e CONFIG_MODULES \
        -e CONFIG_MODULE_UNLOAD \
        -e CONFIG_DEVTMPFS \
        -d CONFIG_DEVTMPFS_MOUNT \
        -e CONFIG_PROC_FS \
        -e CONFIG_SYSFS \
        -e CONFIG_TMPFS \
        -e CONFIG_UNIX98_PTYS \
        -e CONFIG_SERIAL_8250 \
        -e CONFIG_SERIAL_8250_CONSOLE \
        -e CONFIG_KALLSYMS \
        -e CONFIG_KALLSYMS_ALL \
        -e CONFIG_PERF_EVENTS \
        -e CONFIG_RANDOMIZE_BASE \
        -e CONFIG_PAGE_TABLE_ISOLATION \
        -e CONFIG_X86_SMEP \
        -e CONFIG_X86_SMAP \
        -e CONFIG_UNWINDER_ORC \
        -d CONFIG_FRAME_POINTER \
        -d CONFIG_MODULE_SIG_FORCE \
        -e CONFIG_STACKPROTECTOR \
        -e CONFIG_STACKPROTECTOR_STRONG \
        -e CONFIG_FORTIFY_SOURCE \
        -e CONFIG_HARDENED_USERCOPY \
        -e CONFIG_HARDENED_USERCOPY_DEFAULT_ON

    make -C "$KERNEL_SOURCE" O="$KERNEL_OUTPUT" ARCH=x86_64 olddefconfig
    for required_config in CONFIG_64BIT CONFIG_BLK_DEV_INITRD CONFIG_RD_GZIP \
        CONFIG_BINFMT_ELF CONFIG_BINFMT_SCRIPT CONFIG_SYSCTL CONFIG_PRINTK CONFIG_TTY \
        CONFIG_MODULES CONFIG_DEVTMPFS CONFIG_PROC_FS CONFIG_SYSFS CONFIG_TMPFS \
        CONFIG_SERIAL_8250_CONSOLE CONFIG_KALLSYMS CONFIG_KALLSYMS_ALL \
        CONFIG_PERF_EVENTS CONFIG_RANDOMIZE_BASE CONFIG_PAGE_TABLE_ISOLATION \
        CONFIG_X86_SMEP CONFIG_X86_SMAP CONFIG_UNWINDER_ORC CONFIG_STACKPROTECTOR \
        CONFIG_STACKPROTECTOR_STRONG CONFIG_FORTIFY_SOURCE \
        CONFIG_HARDENED_USERCOPY CONFIG_HARDENED_USERCOPY_DEFAULT_ON; do
        grep -Fqx "$required_config=y" "$KERNEL_OUTPUT/.config" || \
            die "olddefconfig não preservou a opção obrigatória: $required_config=y"
    done
    if grep -Fqx 'CONFIG_FRAME_POINTER=y' "$KERNEL_OUTPUT/.config"; then
        die "olddefconfig habilitou CONFIG_FRAME_POINTER e alterou o contrato do módulo didático"
    fi
    log_ok "configuração final validada; hardening global permanece ativo no kernel"
    log_info "compilando kernel com $JOBS jobs"
    make -C "$KERNEL_SOURCE" O="$KERNEL_OUTPUT" ARCH=x86_64 -j"$JOBS" bzImage modules_prepare
    install -m 0644 "$KERNEL_OUTPUT/arch/x86/boot/bzImage" "$DIST_DIR/bzImage"
    log_ok "kernel criado: $DIST_DIR/bzImage"
}

build_module()
{
    local module_symbols

    prepare_kernel_source
    [[ -f $KERNEL_OUTPUT/include/config/auto.conf ]] || \
        die "kernel ainda não preparado; execute ./build.sh kernel"

    rm -rf -- "$MODULE_BUILD"
    mkdir -p "$MODULE_BUILD"
    install -m 0644 "$PROJECT_ROOT/challenge/Makefile" "$MODULE_BUILD/Makefile"
    install -m 0644 "$PROJECT_ROOT/challenge/kvuln.c" "$MODULE_BUILD/kvuln.c"

    log_info "compilando módulo vulnerável isoladamente"
    make -C "$KERNEL_SOURCE" O="$KERNEL_OUTPUT" ARCH=x86_64 \
        M="$MODULE_BUILD" -j"$JOBS" modules
    module_symbols=$(readelf -Ws "$MODULE_BUILD/kvuln.ko") || \
        die "não foi possível inspecionar os símbolos de kvuln.ko"
    if grep -Fq '__stack_chk_fail' <<<"$module_symbols"; then
        die "kvuln.ko recebeu stack protector; o overflow didático seria bloqueado"
    fi
    install -m 0644 "$MODULE_BUILD/kvuln.ko" "$DIST_DIR/kvuln.ko"
    log_ok "módulo criado: $DIST_DIR/kvuln.ko"
}

build_player_handout()
{
    local archive=$DIST_DIR/player-handout.tar.xz
    local checksum_file=$DIST_DIR/player-handout.tar.xz.sha256
    local required

    for required in "$KERNEL_OUTPUT/vmlinux" "$KERNEL_OUTPUT/System.map" \
        "$KERNEL_OUTPUT/.config" "$DIST_DIR/bzImage" "$DIST_DIR/kvuln.ko"; do
        [[ -r $required ]] || die "artefato ausente para o handout: $required"
    done

    rm -rf -- "$HANDOUT_BUILD"
    install -d -m 0755 "$HANDOUT_BUILD"
    install -m 0644 "$DIST_DIR/bzImage" "$HANDOUT_BUILD/bzImage"
    install -m 0644 "$KERNEL_OUTPUT/vmlinux" "$HANDOUT_BUILD/vmlinux"
    install -m 0644 "$KERNEL_OUTPUT/System.map" "$HANDOUT_BUILD/System.map"
    install -m 0644 "$KERNEL_OUTPUT/.config" "$HANDOUT_BUILD/kernel.config"
    install -m 0644 "$DIST_DIR/kvuln.ko" "$HANDOUT_BUILD/kvuln.ko"
    install -m 0644 "$PROJECT_ROOT/challenge/kvuln.c" "$HANDOUT_BUILD/kvuln.c"
    install -m 0644 "$PROJECT_ROOT/challenge/Makefile" "$HANDOUT_BUILD/kvuln.Makefile"
    cat > "$HANDOUT_BUILD/README.txt" <<'EOF'
Kernel CTF Lab - pacote do jogador

Este pacote contém somente artefatos públicos para análise:
  bzImage, vmlinux, System.map, kernel.config, kvuln.ko e a fonte do módulo.

vmlinux e kvuln.ko são exatamente os binários usados na instância publicada.
Eles permitem reproduzir, depurar e estudar o exercício com a mesma compilação
usada pelo instrutor.

Nunca é necessário receber initramfs.cpio.gz ou o diretório dist/ completo.
O initramfs do instrutor contém a flag real e não pode ser distribuído.
EOF
    chmod 0644 "$HANDOUT_BUILD/README.txt"

    rm -f -- "$archive.tmp" "$checksum_file.tmp"
    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
        -C "$BUILD_DIR" -cJf "$archive.tmp" player-handout
    mv -f -- "$archive.tmp" "$archive"
    chmod 0644 "$archive"
    (
        cd "$DIST_DIR"
        sha256sum player-handout.tar.xz > player-handout.tar.xz.sha256.tmp
        mv -f -- player-handout.tar.xz.sha256.tmp player-handout.tar.xz.sha256
    )
    chmod 0644 "$checksum_file"
    log_ok "handout sem flag criado: $archive"
}

write_runtime_config()
{
    local output=$DIST_DIR/runtime.conf
    {
        printf 'CHALLENGE_NAME=%s\n' "$(config_get CHALLENGE_NAME)"
        printf 'DEFAULT_LEVEL=%s\n' "$(config_get DEFAULT_LEVEL)"
        printf 'MEMORY_MIB=%s\n' "$(config_get MEMORY_MIB)"
        printf 'VCPUS=%s\n' "$(config_get VCPUS)"
        printf 'MAX_SESSIONS=%s\n' "$(config_get MAX_SESSIONS)"
        printf 'SESSION_TIMEOUT_SECONDS=%s\n' "$(config_get SESSION_TIMEOUT_SECONDS)"
        printf 'HOST_VMEM_KIB=%s\n' "$(config_get HOST_VMEM_KIB)"
        printf 'ACCELERATION=%s\n' "$(config_get ACCELERATION)"
        printf 'KERNEL_VERSION=%s\n' "$(config_get KERNEL_VERSION)"
        printf 'KERNEL_SHA256=%s\n' "$(config_get KERNEL_SHA256)"
    } > "$output.tmp"
    mv -f -- "$output.tmp" "$output"
    chmod 0644 "$output"
}

write_manifest()
{
    local required
    for required in bzImage kvuln.ko initramfs.cpio.gz runtime.conf; do
        [[ -r $DIST_DIR/$required ]] || die "artefato ausente para o manifesto: dist/$required"
    done
    (
        cd "$DIST_DIR"
        sha256sum bzImage kvuln.ko initramfs.cpio.gz runtime.conf > SHA256SUMS.tmp
        mv -f -- SHA256SUMS.tmp SHA256SUMS
    )
    chmod 0644 "$DIST_DIR/SHA256SUMS"
    log_ok "manifesto SHA-256 atualizado"
}

case "$MODE" in
    all)
        build_kernel
        build_module
        build_player_handout
        bash "$PROJECT_ROOT/scripts/build-initramfs.sh"
        write_runtime_config
        write_manifest
        ;;
    kernel) build_kernel ;;
    module) build_module ;;
    handout) build_player_handout ;;
    initramfs)
        bash "$PROJECT_ROOT/scripts/build-initramfs.sh"
        write_runtime_config
        write_manifest
        ;;
esac

log_ok "build '$MODE' concluído"
