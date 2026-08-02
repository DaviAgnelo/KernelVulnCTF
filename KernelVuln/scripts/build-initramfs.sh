#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

assert_project_root "$PROJECT_ROOT"
require_non_root
load_lab_config "$PROJECT_ROOT/config/lab.conf"
validate_lab_values

FLAG_FILE=$PROJECT_ROOT/config/flag.txt
MODULE_FILE=$PROJECT_ROOT/dist/kvuln.ko
OUTPUT_FILE=$PROJECT_ROOT/dist/initramfs.cpio.gz
BUILD_ROOT=$PROJECT_ROOT/build/initramfs-root
LOGIN_BINARY=$PROJECT_ROOT/build/ctf-login
BUSYBOX_PATH=$(command -v busybox || true)

[[ -x $BUSYBOX_PATH ]] || die "BusyBox não encontrado; instale busybox-static"
[[ -f $FLAG_FILE && ! -L $FLAG_FILE && -r $FLAG_FILE ]] || \
    die "flag ausente ou insegura: use configure.sh para criar config/flag.txt"
[[ -r $MODULE_FILE ]] || die "módulo ausente: $MODULE_FILE (execute ./build.sh module)"

flag_owner=$(stat -c '%u' -- "$FLAG_FILE")
flag_mode=$(stat -c '%a' -- "$FLAG_FILE")
[[ $flag_owner == "$(id -u)" ]] || \
    die "config/flag.txt deve pertencer ao usuário que executa o build"
(( (8#$flag_mode & 077) == 0 )) || \
    die "config/flag.txt não pode conceder permissões a grupo/outros (modo atual: $flag_mode)"

mapfile -t flag_lines < "$FLAG_FILE"
[[ ${#flag_lines[@]} -eq 1 && -n ${flag_lines[0]} ]] || \
    die "config/flag.txt deve conter exatamente uma linha não vazia"
[[ ${flag_lines[0]} != 'FLAG{troque_esta_flag_antes_da_aula}' ]] || \
    die "a flag ainda é o valor de exemplo; defina uma flag real antes de construir"
[[ ! ${flag_lines[0]} =~ [[:cntrl:]] ]] || \
    die "config/flag.txt contém caractere de controle inválido"
(( ${#flag_lines[0]} <= 512 )) || die "a flag não pode exceder 512 caracteres"

busybox_program_headers=$(readelf -l "$BUSYBOX_PATH") || \
    die "não foi possível inspecionar o BusyBox com readelf"
if grep -q 'INTERP' <<<"$busybox_program_headers"; then
    die "$BUSYBOX_PATH não é estático; instale ou forneça um BusyBox estaticamente ligado"
fi

declare -a applets=(ash base64 cat chmod chown cp dd dmesg echo false grep head \
    hexdump id insmod kill ln ls mkdir mount mv od poweroff ps pwd rm sed sh sleep \
    sha256sum stat tail test touch true umount uname vi wc whoami mktemp)
mapfile -t available_applets < <("$BUSYBOX_PATH" --list)
declare -A applet_available=()
for applet in "${available_applets[@]}"; do
    applet_available[$applet]=1
done

declare -a missing_applets=()
for applet in "${applets[@]}"; do
    [[ -v "applet_available[$applet]" ]] || missing_applets+=("$applet")
done
if ((${#missing_applets[@]} > 0)); then
    die "o BusyBox instalado não fornece os applets exigidos: ${missing_applets[*]}"
fi
log_ok "applets BusyBox validados explicitamente (${#applets[@]} applets)"

log_info "compilando o helper estático de identidade ctf"
gcc -static -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 \
    -o "$LOGIN_BINARY.tmp" "$PROJECT_ROOT/rootfs/ctf-login.c"
login_program_headers=$(readelf -l "$LOGIN_BINARY.tmp") || {
    rm -f -- "$LOGIN_BINARY.tmp"
    die "não foi possível inspecionar o ctf-login com readelf"
}
if grep -q 'INTERP' <<<"$login_program_headers"; then
    rm -f -- "$LOGIN_BINARY.tmp"
    die "ctf-login foi ligado dinamicamente; um binário estático é obrigatório"
fi
mv -f -- "$LOGIN_BINARY.tmp" "$LOGIN_BINARY"
chmod 0755 "$LOGIN_BINARY"

log_info "criando árvore limpa do initramfs"
rm -rf -- "$BUILD_ROOT"
install -d -m 0755 "$BUILD_ROOT" "$BUILD_ROOT"/{bin,sbin,etc,proc,sys,dev,dev/pts,tmp,run,home,lib,lib/modules}
install -d -m 0700 "$BUILD_ROOT/root" "$BUILD_ROOT/home/ctf"
install -m 0755 "$BUSYBOX_PATH" "$BUILD_ROOT/bin/busybox"
for applet in "${applets[@]}"; do
    ln -s /bin/busybox "$BUILD_ROOT/bin/$applet"
done

install -m 0755 "$PROJECT_ROOT/rootfs/init" "$BUILD_ROOT/init"
install -m 0755 "$LOGIN_BINARY" "$BUILD_ROOT/sbin/ctf-login"
install -m 0644 "$PROJECT_ROOT/rootfs/etc/passwd" "$BUILD_ROOT/etc/passwd"
install -m 0644 "$PROJECT_ROOT/rootfs/etc/group" "$BUILD_ROOT/etc/group"
install -m 0644 "$PROJECT_ROOT/rootfs/home/ctf/.profile" "$BUILD_ROOT/home/ctf/.profile"
install -m 0755 "$PROJECT_ROOT/rootfs/home/ctf/upload" "$BUILD_ROOT/bin/upload"
install -m 0644 "$MODULE_FILE" "$BUILD_ROOT/lib/modules/kvuln.ko"
install -m 0400 "$FLAG_FILE" "$BUILD_ROOT/root/flag.txt"
printf '%s\n' "$(config_get CHALLENGE_NAME)" > "$BUILD_ROOT/etc/challenge-name"
chmod 0644 "$BUILD_ROOT/etc/challenge-name"
chmod 0755 "$BUILD_ROOT" "$BUILD_ROOT/bin" "$BUILD_ROOT/sbin" "$BUILD_ROOT/etc" \
    "$BUILD_ROOT/proc" "$BUILD_ROOT/sys" "$BUILD_ROOT/dev" "$BUILD_ROOT/dev/pts" \
    "$BUILD_ROOT/tmp" "$BUILD_ROOT/run" "$BUILD_ROOT/home" "$BUILD_ROOT/lib" \
    "$BUILD_ROOT/lib/modules"
chmod 0700 "$BUILD_ROOT/root" "$BUILD_ROOT/home/ctf"
chmod 0400 "$BUILD_ROOT/root/flag.txt"

for public_dir in "$BUILD_ROOT" "$BUILD_ROOT/bin" "$BUILD_ROOT/sbin" "$BUILD_ROOT/etc" \
    "$BUILD_ROOT/home" "$BUILD_ROOT/lib" "$BUILD_ROOT/lib/modules"; do
    [[ $(stat -c '%a' -- "$public_dir") == 755 ]] || \
        die "diretório do initramfs com modo inseguro: $public_dir"
done
for private_dir in "$BUILD_ROOT/root" "$BUILD_ROOT/home/ctf"; do
    [[ $(stat -c '%a' -- "$private_dir") == 700 ]] || \
        die "diretório privado do initramfs com modo incorreto: $private_dir"
done

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || \
    die "SOURCE_DATE_EPOCH deve ser um inteiro não negativo"
find "$BUILD_ROOT" -exec touch -h -d "@$SOURCE_DATE_EPOCH" -- {} +

install -d -m 0700 "$PROJECT_ROOT/dist"
archive_tmp=$OUTPUT_FILE.tmp
rm -f -- "$archive_tmp"
log_info "empacotando initramfs newc reproduzível"
(
    umask 0077
    (
        cd "$BUILD_ROOT"
        find . -print0 | LC_ALL=C sort -z | \
            cpio --null --create --format=newc --owner=0:0 --reproducible 2>/dev/null
    ) | gzip -9n > "$archive_tmp"
)
gzip -t "$archive_tmp" || die "o initramfs gerado falhou na validação gzip"
mv -f -- "$archive_tmp" "$OUTPUT_FILE"
chmod 0600 "$OUTPUT_FILE"

archive_listing=$(gzip -dc "$OUTPUT_FILE" | cpio -it 2>/dev/null)
for required_path in init bin/busybox sbin/ctf-login etc/passwd home/ctf/.profile \
    bin/upload lib/modules/kvuln.ko root/flag.txt; do
    grep -Eq "^(\\./)?${required_path//./\\.}$" <<<"$archive_listing" || \
        die "arquivo obrigatório ausente do initramfs: $required_path"
done

log_ok "initramfs criado e validado: $OUTPUT_FILE"
