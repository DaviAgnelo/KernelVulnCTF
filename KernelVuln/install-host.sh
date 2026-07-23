#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"

HOST_USER=kernelctf
INSTALL_ROOT=/opt/kernel-ctf
AUTHORIZED_KEYS_SOURCE=''
RELOAD_SSH=1
SSH_TEST_CLIENT_HOST=localhost
SSH_TEST_CLIENT_ADDRESS=127.0.0.1
SSH_TEST_LOCAL_ADDRESS=127.0.0.1
SSH_TEST_LOCAL_PORT=22

usage()
{
    cat <<'EOF'
Uso: sudo bash ./install-host.sh [opções]

  --authorized-keys ARQUIVO   Instala uma ou mais chaves públicas SSH.
  --user NOME                 Conta SSH dedicada (padrão: kernelctf).
  --install-root CAMINHO      Destino seguro abaixo de /opt (padrão: /opt/kernel-ctf).
  --ssh-test-client-host NOME Nome reverso da origem visto pelo sshd (`Match Host`).
  --ssh-test-client-address IP
                              Endereço de origem para validar regras Match.
  --ssh-test-local-address IP Endereço local do endpoint SSH dos alunos.
  --ssh-test-local-port PORTA Porta local do endpoint SSH dos alunos.
  --no-reload-ssh             Valida, mas não recarrega ssh.service.

Na primeira instalação, --authorized-keys é obrigatório. Em atualizações, o
arquivo /etc/ssh/authorized_keys/NOME existente é preservado se a opção faltar.
EOF
}

while (($# > 0)); do
    case "$1" in
        --authorized-keys)
            (($# >= 2)) || die "--authorized-keys exige um arquivo"
            AUTHORIZED_KEYS_SOURCE=$2
            shift 2
            ;;
        --user)
            (($# >= 2)) || die "--user exige um nome"
            HOST_USER=$2
            shift 2
            ;;
        --install-root)
            (($# >= 2)) || die "--install-root exige um caminho"
            INSTALL_ROOT=$2
            shift 2
            ;;
        --ssh-test-client-host)
            (($# >= 2)) || die "--ssh-test-client-host exige um nome"
            SSH_TEST_CLIENT_HOST=$2
            shift 2
            ;;
        --ssh-test-client-address)
            (($# >= 2)) || die "--ssh-test-client-address exige um endereço"
            SSH_TEST_CLIENT_ADDRESS=$2
            shift 2
            ;;
        --ssh-test-local-address)
            (($# >= 2)) || die "--ssh-test-local-address exige um endereço"
            SSH_TEST_LOCAL_ADDRESS=$2
            shift 2
            ;;
        --ssh-test-local-port)
            (($# >= 2)) || die "--ssh-test-local-port exige uma porta"
            SSH_TEST_LOCAL_PORT=$2
            shift 2
            ;;
        --no-reload-ssh)
            RELOAD_SSH=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "opção desconhecida: $1" ;;
    esac
done

require_root
require_debian_bookworm
assert_project_root "$PROJECT_ROOT"
bash "$PROJECT_ROOT/scripts/check-deps.sh" host-install

[[ $HOST_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "nome de usuário inválido: $HOST_USER"
[[ $INSTALL_ROOT =~ ^/opt(/[A-Za-z0-9._-]+)+$ && $INSTALL_ROOT != *'..'* ]] || \
    die "--install-root deve ficar abaixo de /opt e usar componentes simples, sem '..'"
for ssh_context_value in "$SSH_TEST_CLIENT_HOST" "$SSH_TEST_CLIENT_ADDRESS" \
    "$SSH_TEST_LOCAL_ADDRESS"; do
    [[ $ssh_context_value =~ ^[A-Za-z0-9._:-]+$ ]] || \
        die "contexto SSH inválido: $ssh_context_value"
done
require_uint_range SSH_TEST_LOCAL_PORT "$SSH_TEST_LOCAL_PORT" 1 65535

validate_secure_install_path()
{
    local relative=${INSTALL_ROOT#/opt/}
    local current=/opt component owner mode child

    while :; do
        if [[ -e $current || -L $current ]]; then
            [[ -d $current && ! -L $current ]] || \
                die "componente do destino não é diretório real: $current"
            owner=$(stat -c '%u' -- "$current")
            mode=$(stat -c '%a' -- "$current")
            [[ $owner == 0 ]] || die "componente do destino não pertence a root: $current"
            (( (8#$mode & 0022) == 0 )) || \
                die "componente do destino permite escrita por grupo/outros: $current (modo $mode)"
        fi

        [[ $current != /opt || -n $relative ]] || break
        component=${relative%%/*}
        current=$current/$component
        if [[ $relative == "$component" ]]; then
            relative=''
        else
            relative=${relative#*/}
        fi
        [[ -n $relative ]] || {
            if [[ -e $current || -L $current ]]; then
                [[ -d $current && ! -L $current ]] || \
                    die "destino não é diretório real: $current"
                owner=$(stat -c '%u' -- "$current")
                mode=$(stat -c '%a' -- "$current")
                [[ $owner == 0 ]] || die "destino existente não pertence a root: $current"
                (( (8#$mode & 0022) == 0 )) || \
                    die "destino existente permite escrita por grupo/outros: $current (modo $mode)"
            fi
            break
        }
    done

    for child in bin scripts dist; do
        current=$INSTALL_ROOT/$child
        if [[ -e $current || -L $current ]]; then
            [[ -d $current && ! -L $current ]] || \
                die "subdiretório de instalação inseguro: $current"
            owner=$(stat -c '%u' -- "$current")
            mode=$(stat -c '%a' -- "$current")
            [[ $owner == 0 ]] || die "subdiretório não pertence a root: $current"
            (( (8#$mode & 0022) == 0 )) || \
                die "subdiretório permite escrita por grupo/outros: $current (modo $mode)"
        fi
    done
}

validate_secure_install_path

for artifact in bzImage kvuln.ko initramfs.cpio.gz runtime.conf SHA256SUMS; do
    [[ -r $PROJECT_ROOT/dist/$artifact ]] || \
        die "artefato ausente: dist/$artifact (execute bash ./build.sh all)"
done
(
    cd "$PROJECT_ROOT/dist"
    sha256sum --check --strict SHA256SUMS
) || die "artefatos de dist/ falharam na verificação SHA-256"

load_lab_config "$PROJECT_ROOT/dist/runtime.conf"
validate_lab_values
RUNTIME_ACCELERATION=$(config_get ACCELERATION)

ACCOUNT_HOME=/var/lib/kernel-ctf
ACCOUNT_MARKER=$ACCOUNT_HOME/.managed-account

[[ ! -L $ACCOUNT_HOME ]] || die "$ACCOUNT_HOME não pode ser link simbólico"
if [[ -e $ACCOUNT_HOME ]]; then
    [[ -d $ACCOUNT_HOME ]] || die "$ACCOUNT_HOME existe e não é um diretório"
    [[ $(stat -c '%u' -- "$ACCOUNT_HOME") == 0 ]] || \
        die "$ACCOUNT_HOME existente não pertence a root"
    account_home_mode=$(stat -c '%a' -- "$ACCOUNT_HOME")
    (( (8#$account_home_mode & 0022) == 0 )) || \
        die "$ACCOUNT_HOME existente permite escrita por grupo/outros"
fi
managed_user=''
if [[ -e $ACCOUNT_MARKER || -L $ACCOUNT_MARKER ]]; then
    [[ -f $ACCOUNT_MARKER && ! -L $ACCOUNT_MARKER ]] || \
        die "marcador de conta inseguro: $ACCOUNT_MARKER"
    [[ $(stat -c '%u' -- "$ACCOUNT_MARKER") == 0 ]] || \
        die "marcador de conta não pertence a root"
    [[ $(stat -c '%a' -- "$ACCOUNT_MARKER") == 444 ]] || \
        die "marcador de conta deve ter modo 0444"
    managed_user=$(<"$ACCOUNT_MARKER")
    [[ $managed_user == "$HOST_USER" ]] || \
        die "esta instalação já gerencia a conta '$managed_user'; recusei trocar para '$HOST_USER'"
else
    ! getent group "$HOST_USER" >/dev/null || \
        die "o grupo $HOST_USER já existe e não foi criado por este projeto"
    ! id "$HOST_USER" >/dev/null 2>&1 || \
        die "a conta $HOST_USER já existe e não foi criada por este projeto; escolha --user diferente"

    install -d -o root -g root -m 0755 "$ACCOUNT_HOME"
    marker_candidate=$(mktemp "$ACCOUNT_HOME/.managed-account.XXXXXXXX")
    printf '%s\n' "$HOST_USER" > "$marker_candidate"
    chown root:root "$marker_candidate"
    chmod 0444 "$marker_candidate"
    mv -f -- "$marker_candidate" "$ACCOUNT_MARKER"
    managed_user=$HOST_USER
fi

if ! getent group "$HOST_USER" >/dev/null; then
    groupadd --system "$HOST_USER"
fi

if id "$HOST_USER" >/dev/null 2>&1; then
    [[ $managed_user == "$HOST_USER" ]] || die "a conta $HOST_USER não é gerenciada por este projeto"
    [[ $(id -u "$HOST_USER") -ne 0 ]] || die "a conta $HOST_USER resolve para UID 0"
    usermod --gid "$HOST_USER" --home "$ACCOUNT_HOME" --shell /bin/sh --lock "$HOST_USER"
else
    useradd --system --gid "$HOST_USER" --home-dir "$ACCOUNT_HOME" \
        --shell /bin/sh --comment 'Kernel CTF forced-command account' "$HOST_USER"
fi

host_group_entry=$(getent group "$HOST_USER")
IFS=: read -r _ _ host_group_gid host_group_members <<<"$host_group_entry"
[[ $host_group_gid != 0 && $(id -g "$HOST_USER") == "$host_group_gid" ]] || \
    die "grupo primário inseguro para $HOST_USER"
if [[ -n $host_group_members ]]; then
    IFS=, read -r -a listed_members <<<"$host_group_members"
    for listed_member in "${listed_members[@]}"; do
        [[ $listed_member == "$HOST_USER" ]] || \
            die "o grupo $HOST_USER contém outro membro: $listed_member"
    done
fi
while IFS=: read -r account_name password_field account_uid account_gid account_details; do
    : "$password_field" "$account_uid" "$account_details"
    [[ $account_gid != "$host_group_gid" || $account_name == "$HOST_USER" ]] || \
        die "a conta $account_name também usa o grupo privado $HOST_USER"
done < <(getent passwd)

case "$RUNTIME_ACCELERATION" in
    tcg)
        usermod --groups '' "$HOST_USER"
        ;;
    auto)
        if getent group kvm >/dev/null && [[ -c /dev/kvm ]]; then
            usermod --groups kvm "$HOST_USER"
            if ! runuser -u "$HOST_USER" -- test -r /dev/kvm ||
               ! runuser -u "$HOST_USER" -- test -w /dev/kvm; then
                usermod --groups '' "$HOST_USER"
                log_warn "/dev/kvm não ficou acessível; ACCELERATION=auto usará TCG"
            fi
        else
            usermod --groups '' "$HOST_USER"
            log_warn "KVM indisponível; ACCELERATION=auto usará TCG"
        fi
        ;;
    kvm)
        getent group kvm >/dev/null || die "ACCELERATION=kvm exige o grupo kvm"
        [[ -c /dev/kvm ]] || die "ACCELERATION=kvm exige /dev/kvm"
        usermod --groups kvm "$HOST_USER"
        runuser -u "$HOST_USER" -- test -r /dev/kvm &&
            runuser -u "$HOST_USER" -- test -w /dev/kvm || \
            die "a conta $HOST_USER não consegue acessar /dev/kvm"
        ;;
esac

install -d -o root -g root -m 0755 "$ACCOUNT_HOME"

[[ ! -L $INSTALL_ROOT ]] || die "$INSTALL_ROOT não pode ser link simbólico"
install -d -o root -g "$HOST_USER" -m 0750 "$INSTALL_ROOT" "$INSTALL_ROOT/bin" \
    "$INSTALL_ROOT/scripts" "$INSTALL_ROOT/dist"
install -o root -g "$HOST_USER" -m 0440 "$PROJECT_ROOT/.kernel-ctf-project" \
    "$INSTALL_ROOT/.kernel-ctf-project"
install -o root -g "$HOST_USER" -m 0550 "$PROJECT_ROOT/bin/kernel-ctf-session" \
    "$INSTALL_ROOT/bin/kernel-ctf-session"
install -o root -g "$HOST_USER" -m 0550 "$PROJECT_ROOT/scripts/check-deps.sh" \
    "$INSTALL_ROOT/scripts/check-deps.sh"
install -o root -g "$HOST_USER" -m 0440 "$PROJECT_ROOT/scripts/lib.sh" \
    "$INSTALL_ROOT/scripts/lib.sh"
for artifact in bzImage kvuln.ko initramfs.cpio.gz runtime.conf SHA256SUMS; do
    install -o root -g "$HOST_USER" -m 0440 "$PROJECT_ROOT/dist/$artifact" "$INSTALL_ROOT/dist/$artifact"
done

AUTHORIZED_KEYS_DIR=/etc/ssh/authorized_keys
if [[ -e $AUTHORIZED_KEYS_DIR || -L $AUTHORIZED_KEYS_DIR ]]; then
    [[ -d $AUTHORIZED_KEYS_DIR && ! -L $AUTHORIZED_KEYS_DIR ]] || \
        die "$AUTHORIZED_KEYS_DIR deve ser um diretório real"
    [[ $(stat -c '%u' -- "$AUTHORIZED_KEYS_DIR") == 0 ]] || \
        die "$AUTHORIZED_KEYS_DIR deve pertencer a root"
    authorized_keys_dir_mode=$(stat -c '%a' -- "$AUTHORIZED_KEYS_DIR")
    (( (8#$authorized_keys_dir_mode & 0022) == 0 )) || \
        die "$AUTHORIZED_KEYS_DIR permite escrita por grupo/outros"
else
    install -d -o root -g root -m 0755 "$AUTHORIZED_KEYS_DIR"
fi
AUTHORIZED_KEYS_DEST=$AUTHORIZED_KEYS_DIR/$HOST_USER
if [[ -e $AUTHORIZED_KEYS_DEST || -L $AUTHORIZED_KEYS_DEST ]]; then
    [[ -f $AUTHORIZED_KEYS_DEST && ! -L $AUTHORIZED_KEYS_DEST ]] || \
        die "arquivo de chaves existente é inseguro: $AUTHORIZED_KEYS_DEST"
    [[ $(stat -c '%u' -- "$AUTHORIZED_KEYS_DEST") == 0 ]] || \
        die "arquivo de chaves existente deve pertencer a root"
    authorized_keys_mode=$(stat -c '%a' -- "$AUTHORIZED_KEYS_DEST")
    (( (8#$authorized_keys_mode & 0022) == 0 )) || \
        die "arquivo de chaves existente permite escrita por grupo/outros"
fi

keys_candidate=''
keys_validation_file=''
keys_published=0
key_probe=''
cleanup_keys_candidate_on_exit()
{
    local status=$?
    trap - EXIT HUP INT TERM
    [[ -z ${keys_candidate:-} ]] || rm -f -- "$keys_candidate"
    [[ -z ${key_probe:-} ]] || rm -f -- "$key_probe"
    exit "$status"
}
trap cleanup_keys_candidate_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n $AUTHORIZED_KEYS_SOURCE ]]; then
    [[ -s $AUTHORIZED_KEYS_SOURCE && -r $AUTHORIZED_KEYS_SOURCE ]] || \
        die "arquivo de chaves vazio ou ilegível: $AUTHORIZED_KEYS_SOURCE"
    keys_candidate=$(mktemp /etc/ssh/authorized_keys/$HOST_USER.candidate.XXXXXXXX)
    key_probe=$(mktemp /etc/ssh/authorized_keys/$HOST_USER.probe.XXXXXXXX)
    valid_keys=0
    key_line_number=0
    while IFS= read -r key_line || [[ -n $key_line ]]; do
        ((key_line_number += 1))
        key_line=${key_line%$'\r'}
        printf '%s\n' "$key_line" >> "$keys_candidate"
        [[ -z $key_line || $key_line == \#* ]] && continue
        if [[ $key_line == *'PRIVATE KEY'* ]]; then
            rm -f -- "$keys_candidate" "$key_probe"
            die "linha $key_line_number parece conter uma chave privada"
        fi
        printf '%s\n' "$key_line" > "$key_probe"
        if ! ssh-keygen -l -f "$key_probe" >/dev/null 2>&1; then
            rm -f -- "$keys_candidate" "$key_probe"
            die "chave pública inválida na linha $key_line_number"
        fi
        ((valid_keys += 1))
    done < "$AUTHORIZED_KEYS_SOURCE"
    rm -f -- "$key_probe"
    ((valid_keys > 0)) || {
        rm -f -- "$keys_candidate"
        die "nenhuma chave pública válida foi encontrada"
    }
    chown root:root "$keys_candidate"
    chmod 0600 "$keys_candidate"
    keys_validation_file=$keys_candidate
elif [[ ! -s $AUTHORIZED_KEYS_DEST ]]; then
    die "primeira instalação exige --authorized-keys ARQUIVO"
else
    [[ -f $AUTHORIZED_KEYS_DEST && ! -L $AUTHORIZED_KEYS_DEST ]] || \
        die "arquivo de chaves existente é inseguro: $AUTHORIZED_KEYS_DEST"
    chown root:root "$AUTHORIZED_KEYS_DEST"
    chmod 0600 "$AUTHORIZED_KEYS_DEST"
    keys_validation_file=$AUTHORIZED_KEYS_DEST
    log_info "preservando chaves existentes em $AUTHORIZED_KEYS_DEST"
fi

# A atualização sem --authorized-keys também valida o conteúdo preservado, para
# não publicar uma conta que só falhará quando a turma tentar conectar.
key_probe=$(mktemp "$AUTHORIZED_KEYS_DIR/$HOST_USER.verify.XXXXXXXX")
valid_keys=0
key_line_number=0
while IFS= read -r key_line || [[ -n $key_line ]]; do
    ((key_line_number += 1))
    if [[ $key_line == *$'\r'* ]]; then
        rm -f -- "$key_probe"
        die "caractere CR inválido no arquivo instalado de chaves (linha $key_line_number)"
    fi
    [[ -z $key_line || $key_line == \#* ]] && continue
    [[ $key_line != *'PRIVATE KEY'* ]] || {
        rm -f -- "$key_probe"
        die "linha $key_line_number do arquivo instalado parece conter uma chave privada"
    }
    printf '%s\n' "$key_line" > "$key_probe"
    ssh-keygen -l -f "$key_probe" >/dev/null 2>&1 || {
        rm -f -- "$key_probe"
        die "chave pública instalada inválida na linha $key_line_number"
    }
    ((valid_keys += 1))
done < "$keys_validation_file"
rm -f -- "$key_probe"
((valid_keys > 0)) || die "arquivo de chaves validado não contém nenhuma chave pública válida"

TMPFILES_CONFIG=/etc/tmpfiles.d/kernel-ctf.conf
if [[ -e $TMPFILES_CONFIG || -L $TMPFILES_CONFIG ]]; then
    [[ -f $TMPFILES_CONFIG && ! -L $TMPFILES_CONFIG ]] || \
        die "$TMPFILES_CONFIG deve ser um arquivo regular, não um link simbólico"
fi
[[ -d /etc/tmpfiles.d && ! -L /etc/tmpfiles.d ]] || \
    die "/etc/tmpfiles.d deve ser um diretório real"
tmpfiles_candidate=$(mktemp /etc/tmpfiles.d/kernel-ctf.candidate.XXXXXXXX)
printf 'd /run/kernel-ctf 0700 %s %s -\n' "$HOST_USER" "$HOST_USER" > "$tmpfiles_candidate"
chown root:root "$tmpfiles_candidate"
chmod 0644 "$tmpfiles_candidate"
mv -f -- "$tmpfiles_candidate" "$TMPFILES_CONFIG"
systemd-tmpfiles --create "$TMPFILES_CONFIG"

SSHD_MAIN=/etc/ssh/sshd_config
MANAGED_BEGIN='# BEGIN KERNEL-CTF-LAB MANAGED BLOCK'
MANAGED_END='# END KERNEL-CTF-LAB MANAGED BLOCK'
LEGACY_SNIPPET=/etc/ssh/sshd_config.d/90-kernel-ctf.conf

[[ -f $SSHD_MAIN && ! -L $SSHD_MAIN ]] || \
    die "$SSHD_MAIN deve ser um arquivo regular, não um link simbólico"
[[ $(stat -c '%u' -- "$SSHD_MAIN") == 0 ]] || die "$SSHD_MAIN deve pertencer a root"
sshd_main_mode=$(stat -c '%a' -- "$SSHD_MAIN")
(( (8#$sshd_main_mode & 0022) == 0 )) || \
    die "$SSHD_MAIN permite escrita por grupo/outros"

validate_effective_sshd_config()
{
    local candidate=$1 effective expected acceptenv_line
    local expected_force="/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin $INSTALL_ROOT/bin/kernel-ctf-session"
    local -a required_effective=(
        "authorizedkeysfile /etc/ssh/authorized_keys/%u"
        "authorizedkeyscommand none"
        "trustedusercakeys none"
        "authenticationmethods publickey"
        "pubkeyauthentication yes"
        "passwordauthentication no"
        "kbdinteractiveauthentication no"
        "hostbasedauthentication no"
        "gssapiauthentication no"
        "kerberosauthentication no"
        "permitemptypasswords no"
        "permituserenvironment no"
        "strictmodes yes"
        "permittty yes"
        "disableforwarding yes"
        "allowagentforwarding no"
        "allowtcpforwarding no"
        "allowstreamlocalforwarding no"
        "x11forwarding no"
        "permittunnel no"
        "permituserrc no"
        "permitopen none"
        "permitlisten none"
        "gatewayports no"
        "maxsessions 1"
        "forcecommand $expected_force"
    )

    effective=$(sshd -T -f "$candidate" \
        -C "user=$HOST_USER,host=$SSH_TEST_CLIENT_HOST,addr=$SSH_TEST_CLIENT_ADDRESS,laddr=$SSH_TEST_LOCAL_ADDRESS,lport=$SSH_TEST_LOCAL_PORT") || return 1
    for expected in "${required_effective[@]}"; do
        grep -Fqx -- "$expected" <<<"$effective" || {
            log_warn "sshd efetivo não aplicou: $expected"
            return 1
        }
    done
    while IFS= read -r acceptenv_line; do
        case "$acceptenv_line" in
            'acceptenv LANG'|'acceptenv LC_*') ;;
            *)
                log_warn "sshd aceita variável de ambiente fora da lista segura: ${acceptenv_line#acceptenv }"
                return 1
                ;;
        esac
    done < <(grep '^acceptenv ' <<<"$effective" || true)
    if grep -q '^setenv ' <<<"$effective"; then
        log_warn "sshd aplica SetEnv à conta restrita; remova essa diretiva do contexto"
        return 1
    fi
}

# Drop-ins são incluídos no início da configuração padrão do Debian 12. Um bloco
# Match dentro deles contaminaria diretivas globais posteriores; por isso o bloco
# gerenciado fica deliberadamente no fim do arquivo principal.
legacy_backup=''
main_backup=''
main_candidate=''
legacy_removed=0
main_replaced=0

rollback_ssh_on_exit()
{
    local status=$?
    local restored_main=0
    trap - EXIT HUP INT TERM

    if ((status != 0)); then
        set +e
        [[ -z ${keys_candidate:-} ]] || rm -f -- "$keys_candidate"
        [[ -z ${key_probe:-} ]] || rm -f -- "$key_probe"
        [[ -z $main_candidate ]] || rm -f -- "$main_candidate"
        if ((main_replaced == 1)) && [[ -n $main_backup && -e $main_backup ]]; then
            mv -f -- "$main_backup" "$SSHD_MAIN"
            restored_main=1
        elif [[ -n $main_backup && -e $main_backup ]]; then
            rm -f -- "$main_backup"
        fi
        if ((legacy_removed == 1)) && [[ -n $legacy_backup && -e $legacy_backup ]]; then
            mv -f -- "$legacy_backup" "$LEGACY_SNIPPET"
        fi
        if ((restored_main == 1)) && [[ $RELOAD_SSH -eq 1 ]] && \
           sshd -t -f "$SSHD_MAIN"; then
            systemctl reload ssh.service || \
                log_warn "configuração SSH anterior restaurada, mas o reload de recuperação falhou"
        fi
    fi
    exit "$status"
}
trap rollback_ssh_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e $LEGACY_SNIPPET || -L $LEGACY_SNIPPET ]]; then
    [[ -f $LEGACY_SNIPPET && ! -L $LEGACY_SNIPPET ]] || \
        die "$LEGACY_SNIPPET existente é inseguro"
    [[ $(stat -c '%u' -- "$LEGACY_SNIPPET") == 0 ]] || \
        die "$LEGACY_SNIPPET deve pertencer a root"
    if ! grep -Fq 'Gerado por kernel-ctf-lab' "$LEGACY_SNIPPET"; then
        die "$LEGACY_SNIPPET já existe e não pertence a este projeto"
    fi
    legacy_backup=$(mktemp /etc/ssh/sshd_config.d/90-kernel-ctf.backup.XXXXXXXX)
    cp --preserve=mode,ownership,timestamps -- "$LEGACY_SNIPPET" "$legacy_backup"
    rm -f -- "$LEGACY_SNIPPET"
    legacy_removed=1
fi

install -d -o root -g root -m 0755 /run/sshd
main_candidate=$(mktemp /etc/ssh/sshd_config.kernel-ctf.XXXXXXXX)
if ! awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
    $0 == begin { if (inside) exit 42; inside = 1; found_begin = 1; next }
    $0 == end   { if (!inside) exit 43; inside = 0; found_end = 1; next }
    !inside { print }
    END {
        if (inside || (found_begin && !found_end) || (!found_begin && found_end))
            exit 44
    }
' "$SSHD_MAIN" > "$main_candidate"; then
    [[ -z $legacy_backup ]] || mv -f -- "$legacy_backup" "$LEGACY_SNIPPET"
    rm -f -- "$main_candidate"
    die "bloco gerenciado anterior em $SSHD_MAIN está malformado"
fi

cat >> "$main_candidate" <<EOF

$MANAGED_BEGIN
# Esta conta nunca recebe um shell no host.
Match User $HOST_USER
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    AuthorizedKeysCommand none
    TrustedUserCAKeys none
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    HostbasedAuthentication no
    GSSAPIAuthentication no
    KerberosAuthentication no
    PermitEmptyPasswords no
    PermitTTY yes
    DisableForwarding yes
    AllowAgentForwarding no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitUserRC no
    PermitOpen none
    PermitListen none
    GatewayPorts no
    MaxSessions 1
    ForceCommand /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin $INSTALL_ROOT/bin/kernel-ctf-session
$MANAGED_END
EOF
chmod 0600 "$main_candidate"

if ! sshd -t -f "$main_candidate"; then
    [[ -z $legacy_backup ]] || mv -f -- "$legacy_backup" "$LEGACY_SNIPPET"
    rm -f -- "$main_candidate"
    die "sshd rejeitou a configuração candidata; arquivo principal não foi alterado"
fi
if ! validate_effective_sshd_config "$main_candidate"; then
    [[ -z $legacy_backup ]] || mv -f -- "$legacy_backup" "$LEGACY_SNIPPET"
    rm -f -- "$main_candidate"
    die "outra regra Match prevalece sobre as restrições da conta $HOST_USER"
fi

main_backup=$(mktemp /etc/ssh/sshd_config.backup.XXXXXXXX)
cp --preserve=mode,ownership,timestamps -- "$SSHD_MAIN" "$main_backup"
main_replaced=1
chown root:root "$main_candidate"
chmod 0600 "$main_candidate"
mv -f -- "$main_candidate" "$SSHD_MAIN"
main_candidate=''

if ! sshd -t -f "$SSHD_MAIN"; then
    mv -f -- "$main_backup" "$SSHD_MAIN"
    [[ -z $legacy_backup ]] || mv -f -- "$legacy_backup" "$LEGACY_SNIPPET"
    die "sshd rejeitou a configuração instalada; alteração revertida"
fi
if ! validate_effective_sshd_config "$SSHD_MAIN"; then
    mv -f -- "$main_backup" "$SSHD_MAIN"
    [[ -z $legacy_backup ]] || mv -f -- "$legacy_backup" "$LEGACY_SNIPPET"
    die "configuração SSH efetiva divergente; alteração revertida"
fi
if [[ $RELOAD_SSH -eq 1 ]]; then
    if ! systemctl reload ssh.service; then
        mv -f -- "$main_backup" "$SSHD_MAIN"
        [[ -z $legacy_backup ]] || mv -f -- "$legacy_backup" "$LEGACY_SNIPPET"
        if sshd -t -f "$SSHD_MAIN"; then
            systemctl reload ssh.service || \
                log_warn "a configuração anterior foi restaurada, mas o segundo reload também falhou"
        fi
        die "reload de ssh.service falhou; configuração anterior restaurada"
    fi
else
    log_warn "sshd não foi recarregado (--no-reload-ssh)"
fi

log_info "política SSH validada no contexto: cliente=$SSH_TEST_CLIENT_ADDRESS ($SSH_TEST_CLIENT_HOST), endpoint=$SSH_TEST_LOCAL_ADDRESS:$SSH_TEST_LOCAL_PORT"
trap '' HUP INT TERM
if [[ -n $keys_candidate ]]; then
    mv -f -- "$keys_candidate" "$AUTHORIZED_KEYS_DEST"
    keys_candidate=''
    keys_published=1
fi
main_replaced=0
legacy_removed=0
trap - EXIT
trap - HUP INT TERM
if ((keys_published == 1)); then
    log_info "novas chaves autorizadas publicadas após a validação do SSH"
fi
rm -f -- "$main_backup"
[[ -z $legacy_backup ]] || rm -f -- "$legacy_backup"

log_ok "laboratório instalado em $INSTALL_ROOT"
log_ok "conta SSH: $HOST_USER (senha bloqueada, somente chave, ForceCommand ativo)"
log_info "teste a partir de outra sessão: ssh -tt $HOST_USER@ENDERECO_DO_LAB"
