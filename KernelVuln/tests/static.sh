#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"
assert_project_root "$PROJECT_ROOT"

failures=0

check_contains()
{
    local file=$1 pattern=$2 description=$3
    if ! grep -Eq -- "$pattern" "$file"; then
        printf '[FALHA] %s\n' "$description" >&2
        ((failures += 1))
    fi
}

check_absent()
{
    local file=$1 pattern=$2 description=$3
    if grep -Eq -- "$pattern" "$file"; then
        printf '[FALHA] %s\n' "$description" >&2
        ((failures += 1))
    fi
}

check_minimum_count()
{
    local file=$1 pattern=$2 minimum=$3 description=$4 count
    count=$(grep -Ec -- "$pattern" "$file" || true)
    if ((count < minimum)); then
        printf '[FALHA] %s (esperado >= %s; obtido %s)\n' \
            "$description" "$minimum" "$count" >&2
        ((failures += 1))
    fi
}

# Verifica que o modo foi aplicado por chmod ao caminho exato. Antes da busca,
# linhas continuadas com barra invertida sao reunidas para aceitar formatacao
# em uma ou varias linhas sem confundir uma simples ocorrencia em mkdir/install.
check_explicit_chmod()
{
    local file=$1 expected_mode=$2 target=$3 description=$4
    local normalized_line token normalized_mode found=0

    normalized_mode=${expected_mode#0}
    while IFS= read -r normalized_line; do
        if [[ ! $normalized_line =~ ^[[:space:]]*chmod[[:space:]]+(--[[:space:]]+)?0?${normalized_mode}([[:space:]]|$) ]]; then
            continue
        fi

        for token in $normalized_line; do
            token=${token#\"}
            token=${token%\"}
            token=${token#\'}
            token=${token%\'}
            token=${token%;}
            if [[ $token == "$target" ]]; then
                found=1
                break 2
            fi
        done
    done < <(
        sed ':join
            /\\[[:space:]]*$/ {
                N
                s/\\[[:space:]]*\n[[:space:]]*/ /
                b join
            }' "$file"
    )

    if ((found == 0)); then
        printf '[FALHA] %s\n' "$description" >&2
        ((failures += 1))
    fi
}

while IFS= read -r -d '' shell_file; do
    "$BASH" -n "$shell_file" || ((failures += 1))
done < <(find "$PROJECT_ROOT" -path "$PROJECT_ROOT/build" -prune -o \
    -path "$PROJECT_ROOT/downloads" -prune -o -path "$PROJECT_ROOT/dist" -prune -o \
    -type f -name '*.sh' -print0)

for critical_shell in bin/kernel-ctf-session rootfs/init rootfs/home/ctf/.profile \
    rootfs/home/ctf/upload; do
    "$BASH" -n "$PROJECT_ROOT/$critical_shell" || ((failures += 1))
done
if command -v busybox >/dev/null 2>&1; then
    for guest_shell in rootfs/init rootfs/home/ctf/.profile rootfs/home/ctf/upload; do
        busybox sh -n "$PROJECT_ROOT/$guest_shell" || ((failures += 1))
    done
fi

load_lab_config "$PROJECT_ROOT/config/lab.conf"
validate_lab_values

check_contains "$PROJECT_ROOT/rootfs/ctf-login.c" 'setresuid\(CTF_UID, CTF_UID, CTF_UID\)' \
    "ctf-login nao fixa os tres UIDs em 1000"
check_contains "$PROJECT_ROOT/rootfs/ctf-login.c" 'setresgid\(CTF_GID, CTF_GID, CTF_GID\)' \
    "ctf-login nao fixa os tres GIDs em 1000"
check_contains "$PROJECT_ROOT/rootfs/ctf-login.c" 'setgroups\(0, NULL\)' \
    "ctf-login nao limpa grupos suplementares"
check_contains "$PROJECT_ROOT/rootfs/ctf-login.c" 'errno != EACCES' \
    "ctf-login nao verifica negacao de leitura da flag"
check_contains "$PROJECT_ROOT/rootfs/ctf-login.c" 'SELFTEST: KVULN_OVERSIZED_READ=PASS' \
    "autoteste nao publica o marcador da leitura oversized"
check_contains "$PROJECT_ROOT/challenge/kvuln.c" 'copy_to_user[[:space:]]*\(' \
    "leitura didatica nao usa copy_to_user"
check_contains "$PROJECT_ROOT/challenge/kvuln.c" 'copy_from_user[[:space:]]*\(' \
    "escrita didatica nao usa copy_from_user"
check_absent "$PROJECT_ROOT/challenge/kvuln.c" 'raw_copy_(to|from)_user[[:space:]]*\(' \
    "modulo usa primitivas raw fora do escopo defensivo desta revisao"
check_contains "$PROJECT_ROOT/challenge/kvuln.c" 'kvuln_hide_pointer' \
    "modulo nao oculta object_size para preservar o bug intencional"

for protection in CONFIG_X86_SMEP CONFIG_X86_SMAP CONFIG_UNWINDER_ORC CONFIG_STACKPROTECTOR \
    CONFIG_STACKPROTECTOR_STRONG CONFIG_FORTIFY_SOURCE CONFIG_HARDENED_USERCOPY; do
    check_contains "$PROJECT_ROOT/build.sh" \
        "(^|[[:space:]])(-e|--enable)[[:space:]]+$protection([[:space:]]|$)" \
        "protecao global do kernel nao esta habilitada: $protection"
    check_absent "$PROJECT_ROOT/build.sh" \
        "(^|[[:space:]])(-d|--disable)[[:space:]]+$protection([[:space:]]|$)" \
        "protecao global do kernel foi desabilitada: $protection"
done
for boot_requirement in CONFIG_BINFMT_ELF CONFIG_BINFMT_SCRIPT CONFIG_SYSCTL \
    CONFIG_PRINTK CONFIG_TTY; do
    check_contains "$PROJECT_ROOT/build.sh" \
        "(^|[[:space:]])(-e|--enable)[[:space:]]+$boot_requirement([[:space:]]|$)" \
        "requisito funcional do boot nao esta habilitado: $boot_requirement"
done
check_contains "$PROJECT_ROOT/build.sh" \
    '(^|[[:space:]])(-d|--disable)[[:space:]]+CONFIG_FRAME_POINTER([[:space:]]|$)' \
    "CONFIG_FRAME_POINTER precisa permanecer desabilitado para esta compilacao fixada"

for level in 0 1 2 3 4; do
    case "$level" in
        0) expected_cpu='qemu64,-smep,-smap'; expected_args='nokaslr pti=off' ;;
        1) expected_cpu='qemu64,+smep,-smap'; expected_args='nokaslr pti=off' ;;
        2) expected_cpu='qemu64,+smep,-smap'; expected_args='pti=off' ;;
        3) expected_cpu='qemu64,+smep,+smap'; expected_args='pti=off' ;;
        4) expected_cpu='qemu64,+smep,+smap'; expected_args='pti=on' ;;
    esac
    set_level_profile "$level"
    if [[ $LEVEL_CPU_MODEL != "$expected_cpu" ||
          $LEVEL_KERNEL_ARGS != "$expected_args" ]]; then
        printf '[FALHA] perfil do nivel %s divergiu (CPU=%s; args=%s)\n' \
            "$level" "$LEVEL_CPU_MODEL" "$LEVEL_KERNEL_ARGS" >&2
        ((failures += 1))
    fi
done

check_contains "$PROJECT_ROOT/rootfs/init" 'SELFTEST: LEVEL_POLICY_%s=PASS' \
    "init nao publica o marcador de validacao do perfil do nivel"
check_contains "$PROJECT_ROOT/rootfs/home/ctf/upload" \
    'mktemp /home/ctf/\.ctf-upload\.XXXXXXXX' \
    "upload nao usa arquivo temporario privado para publicacao atomica"
check_contains "$PROJECT_ROOT/rootfs/home/ctf/upload" \
    'mv -f "\$decoded" "\$output"' \
    "upload nao publica o arquivo validado por rename atomico"

check_contains "$PROJECT_ROOT/configure.sh" \
    '\[\[ -f \$FLAG_SOURCE && ! -L \$FLAG_SOURCE && -r \$FLAG_SOURCE \]\]' \
    "configure nao rejeita symlink ou origem nao regular para a flag"
check_contains "$PROJECT_ROOT/configure.sh" \
    'flag_source_owner=.*stat -c.*%u' \
    "configure nao valida o dono do arquivo de flag"
check_contains "$PROJECT_ROOT/configure.sh" \
    '8#\$flag_source_mode & 077' \
    "configure nao rejeita arquivo de flag acessivel por grupo ou outros"
check_contains "$PROJECT_ROOT/configure.sh" \
    "read -r -d '' _.*flag_read_path" \
    "configure nao rejeita byte NUL antes de carregar a flag no Bash"
check_contains "$PROJECT_ROOT/configure.sh" \
    'mktemp.*config/\.flag-input\.' \
    "configure nao preserva a entrada padrao em temporario privado para validacao binaria"
check_contains "$PROJECT_ROOT/.gitignore" '^config/\.flag-input\.\*$' \
    "temporario sensivel da flag nao esta ignorado pelo Git"

check_absent "$PROJECT_ROOT/rootfs/init" 'exec[[:space:]]+/bin/(ba)?sh' \
    "initramfs contem fallback para shell root"

for qemu_guard in '-nic none' '-monitor none' '-nodefaults' '-no-user-config' \
    '-display none' '-no-reboot' '-chardev stdio,id=serial0,signal=off' \
    '-sandbox on' 'obsolete=deny' 'elevateprivileges=deny' 'spawn=deny' \
    'resourcecontrol=deny'; do
    check_contains "$PROJECT_ROOT/bin/kernel-ctf-session" "$qemu_guard" \
        "launcher QEMU nao contem a protecao: $qemu_guard"
done
check_absent "$PROJECT_ROOT/bin/kernel-ctf-session" \
    '-virtfs|-fsdev|-drive|-blockdev|-hda|-hdb|-hdc|-hdd|-cdrom|-netdev|-gdb|-qmp|-daemonize|-pidfile|-incoming|-s([^[:alnum:]]|$)' \
    "launcher expoe disco, compartilhamento, rede, controle externo ou GDB"
check_absent "$PROJECT_ROOT/bin/kernel-ctf-session" '(^|[[:space:]])eval([[:space:]]|$)' \
    "launcher usa eval desnecessariamente"
check_contains "$PROJECT_ROOT/bin/kernel-ctf-session" 'lab\.selftest=1' \
    "launcher nao oferece o autoteste defensivo nao interativo"
check_contains "$PROJECT_ROOT/tests/launcher.sh" \
    'KERNEL_CTF_RUNTIME_DIR="\$runtime_dir"' \
    "teste do launcher nao usa runtime privado e descartavel"
check_contains "$PROJECT_ROOT/Makefile" '^\.NOTPARALLEL:[[:space:]]+test$' \
    "make -j test pode iniciar os testes QEMU pesados em paralelo"
check_absent "$PROJECT_ROOT/tests/initramfs.sh" \
    'cpio.*(--extract|[[:space:]]-i([[:space:]]|$))' \
    "teste do initramfs extrai o arquivo analisado sem necessidade"

check_contains "$PROJECT_ROOT/rootfs/etc/passwd" '^ctf:x:1000:1000:' \
    "entrada ctf UID/GID 1000 ausente"
for required_applet in base64 insmod mktemp poweroff sha256sum; do
    check_contains "$PROJECT_ROOT/scripts/build-initramfs.sh" \
        "(^|[[:space:]])$required_applet([[:space:]]|\\))" \
        "applet BusyBox obrigatorio nao aparece na lista validada: $required_applet"
done
check_contains "$PROJECT_ROOT/scripts/check-deps.sh" 'qemu-system-x86_64.*cpio' \
    "checagem de qemu-system-x86_64/cpio ausente"
check_contains "$PROJECT_ROOT/install-host.sh" \
    'INSTALL_ROOT =~ \^/opt' \
    "install-host nao restringe o destino a /opt"
check_contains "$PROJECT_ROOT/install-host.sh" 'sshd -T -f' \
    "install-host nao valida a politica SSH efetiva"
check_contains "$PROJECT_ROOT/install-host.sh" \
    'addr=\$SSH_TEST_CLIENT_ADDRESS,laddr=\$SSH_TEST_LOCAL_ADDRESS,lport=\$SSH_TEST_LOCAL_PORT' \
    "install-host nao valida a politica SSH no contexto real configurado"
for ssh_guard in 'permituserenvironment no' 'strictmodes yes' \
    'authorizedkeyscommand none' 'trustedusercakeys none' \
    'allowstreamlocalforwarding no' 'permitopen none' 'permitlisten none'; do
    check_contains "$PROJECT_ROOT/install-host.sh" "$ssh_guard" \
        "install-host nao exige a protecao SSH efetiva: $ssh_guard"
done
check_contains "$PROJECT_ROOT/install-host.sh" \
    "'acceptenv LANG'\|'acceptenv LC_\*'" \
    "install-host nao limita AcceptEnv às variaveis de locale esperadas"
check_contains "$PROJECT_ROOT/install-host.sh" "grep -q '\^setenv '" \
    "install-host nao rejeita SetEnv na politica SSH efetiva"
check_contains "$PROJECT_ROOT/install-host.sh" 'rollback_ssh_on_exit' \
    "install-host nao possui rollback SSH para falhas inesperadas"
check_contains "$PROJECT_ROOT/install-host.sh" \
    'novas chaves autorizadas publicadas após a validação do SSH' \
    "install-host publica authorized_keys antes de validar e recarregar o SSH"

for public_directory in '' bin sbin etc lib; do
    if [[ -n $public_directory ]]; then
        chmod_target="\$BUILD_ROOT/$public_directory"
        chmod_label="/$public_directory"
    else
        chmod_target='$BUILD_ROOT'
        chmod_label='/ (raiz do initramfs)'
    fi
    check_explicit_chmod "$PROJECT_ROOT/scripts/build-initramfs.sh" 0755 \
        "$chmod_target" \
        "build-initramfs nao aplica chmod 0755 explicitamente em $chmod_label"
done
for private_directory in root home/ctf; do
    check_explicit_chmod "$PROJECT_ROOT/scripts/build-initramfs.sh" 0700 \
        "\$BUILD_ROOT/$private_directory" \
        "build-initramfs nao aplica chmod 0700 explicitamente em /$private_directory"
done
check_explicit_chmod "$PROJECT_ROOT/scripts/build-initramfs.sh" 0400 \
    '$BUILD_ROOT/root/flag.txt' \
    "build-initramfs nao reaplica chmod 0400 explicitamente na flag"

if ((failures > 0)); then
    die "$failures verificacao(oes) estatica(s) falharam"
fi
log_ok "verificacoes estaticas concluidas"
