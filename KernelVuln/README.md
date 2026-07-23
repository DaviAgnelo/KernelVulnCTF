# Kernel CTF Lab para Debian 12 + Proxmox

Laboratório descartável de exploração de kernel Linux. O aluno conecta por SSH
ao host Debian 12 e o `sshd` executa, obrigatoriamente, uma instância QEMU nova.
O console serial da VM vira a própria sessão SSH. Ao sair, desconectar ou atingir
o tempo limite, o processo QEMU e seu grupo são encerrados e todo o estado some.

O projeto inclui um desafio inicial, `stack-gateway`, com um módulo
deliberadamente vulnerável a leak/overflow de pilha e níveis de mitigação 0–4.
Ele foi inspirado na organização curricular do
[0xCD4/kernel-ctf-lab](https://github.com/0xCD4/kernel-ctf-lab), mas o boot, a
troca de usuário e o launcher foram reescritos para falhar de forma fechada no
Debian 12.

> **Use somente em uma VM Debian 12 dedicada.** Um kernel guest hostil ainda
> ataca a superfície do emulador QEMU. Não instale este laboratório em um host
> que contenha dados ou credenciais importantes.

## Controles implementados e limites

- Debian 12 Bookworm é detectado por `/etc/os-release`; o instalador recusa outro
  sistema, sem caminhos ou pacotes específicos do Ubuntu.
- `qemu-system-x86_64`, `cpio`, `gzip`, BusyBox estático, toolchain, headers e
  utilitários de sessão são validados com mensagens e pacotes Debian sugeridos.
- Os links de applets BusyBox necessários ao sistema são comparados com
  `busybox --list` antes de o initramfs ser empacotado. O próprio
  `/bin/busybox`, porém, é um multiplexer e também permite chamar outros applets
  compilados nele. Esses applets herdam o UID/GID 1000 do aluno e não concedem
  privilégios por si só; a lista de comandos não é uma fronteira de segurança.
- `/etc/passwd` contém `ctf:x:1000:1000`; um binário estático próprio aplica e
  verifica UID/GID real, efetivo e salvo, remove grupos suplementares e testa
  que `/root/flag.txt` retorna `EACCES` antes de abrir o shell.
- Nenhum fluxo normal ou de erro expõe um shell root interativo. Falha de mount,
  módulo, permissão, console ou identidade desliga a VM.
- A flag é `root:root 0400`. O init reaplica e valida isso dentro de todo boot;
  o launcher valida antes o manifesto dos artefatos que inclui o initramfs.
- QEMU roda sem root, sem NIC, disco, 9p, GDB ou monitor, com sandbox seccomp,
  limites de recursos, checksum dos artefatos e limite de sessões concorrentes.
- O SSH usa somente o arquivo de chaves gerenciado, `ForceCommand`, ambiente
  limpo, `StrictModes` e todos os tipos de forwarding desabilitados. O
  instalador recusa `PermitUserEnvironment=yes` e `AcceptEnv` fora de `LANG` e
  `LC_*`, além de recusar `SetEnv`, na política efetiva.

## Fluxo

```text
SSH do aluno
    └─ sshd: ForceCommand + ambiente vazio
       └─ kernel-ctf-session (UID sem privilégio no host)
          └─ QEMU em primeiro plano, sem rede/disco/monitor
             └─ /init (root apenas para preparar a VM)
                └─ ctf-login: UID/GID 1000 + teste EACCES
                   └─ /bin/sh como ctf

logout / queda do SSH / timeout → trap → mata grupo do QEMU → remove runtime
```

## 1. Preparar a VM Debian 12

Crie uma **VM**, não um LXC, no Proxmox. Recomenda-se 4 vCPU, 4–8 GiB de RAM e
40 GiB de disco durante a compilação. Use CPU type `host` se quiser KVM aninhado;
sem `/dev/kvm`, o launcher usa TCG automaticamente. Veja
[docs/PROXMOX.md](docs/PROXMOX.md).

Dentro do Debian 12:

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends \
  build-essential binutils bc bison flex cpio gzip xz-utils wget ca-certificates \
  busybox-static libelf-dev libssl-dev openssl dwarves pkg-config perl python3 \
  qemu-system-x86 util-linux coreutils openssh-server systemd passwd

bash scripts/check-deps.sh all
```

Execute configuração, build e testes como usuário comum; esses scripts recusam
UID 0. Somente `install-host.sh` deve ser chamado com `sudo`.

## 2. Definir flag e nível

Não passe a flag como argumento nem a escreva literalmente em um comando: isso
pode gravá-la no histórico e na lista de processos. Prefira o prompt sem eco:

```sh
bash configure.sh --level 0 --flag-prompt
```

Para automação, crie fora do repositório um arquivo de uma única linha, de
propriedade do usuário atual e sem acesso para grupo/outros. O modo `0600` é a
recomendação usual:

```sh
umask 077
${EDITOR:-vi} /caminho/seguro/flag.txt
chmod 0600 /caminho/seguro/flag.txt
bash configure.sh --level 0 --flag-file /caminho/seguro/flag.txt
```

`config/flag.txt` recebe modo `0600` e é ignorado pelo Git. Os níveis são:

| Nível | SMEP | KASLR | SMAP | KPTI | `kptr_restrict` | `dmesg_restrict` | `perf_event_paranoid` |
|---:|:---:|:---:|:---:|:---:|---:|---:|---:|
| 0 | não | não | não | não | 0 | 0 | 1 |
| 1 | sim | não | não | não | 0 | 0 | 1 |
| 2 | sim | sim | não | não | 1 | 1 | 3 |
| 3 | sim | sim | sim | não | 1 | 1 | 3 |
| 4 | sim | sim | sim | sim | 1 | 1 | 3 |

“Nível 0” significa **sem as quatro mitigações graduadas** da tabela, não um
kernel sem qualquer proteção. `CONFIG_STACKPROTECTOR_STRONG` permanece ativo
globalmente e é desabilitado somente no módulo didático. `CONFIG_FORTIFY_SOURCE`
e `CONFIG_HARDENED_USERCOPY` também permanecem ativos no restante do kernel; o
autoteste confirma que o contrato didático do módulo continua disponível com
essas proteções globais habilitadas.
O `kernel.config` entregue aos jogadores é a referência exata da configuração.

Outros limites ficam em [config/lab.conf](config/lab.conf), num formato
restrito `KEY=VALUE` que não é executado como shell.

## 3. Construir e testar

O build baixa o Linux 6.1.75 de kernel.org e exige o SHA-256 fixado na
configuração. Depois compila o kernel, o módulo, o helper estático de identidade
e o initramfs:

```sh
bash reset.sh
bash tests/static.sh
bash tests/initramfs.sh
bash tests/integration.sh
bash tests/launcher.sh
```

O teste de integração inicia QEMU com `lab.selftest=1` em **todos os níveis de 0
a 4**. Em cada boot o próprio guest confere as flags SMEP/SMAP da CPU virtual,
os parâmetros KASLR/KPTI, os três sysctls da tabela, UID/GID 1000, grupos
suplementares vazios, flag inacessível e poweroff. O build pode levar vários
minutos e ocupar alguns GiB.

`tests/launcher.sh` executa ainda o launcher de produção em modo de autoteste no
nível padrão. Isso cobre a validação do manifesto, a seleção de aceleração, o
diretório privado de runtime, o slot de concorrência, os limites e o descarte da
sessão sem abrir um shell interativo.

O build também produz `dist/player-handout.tar.xz` e seu arquivo `.sha256`; esse
é o único pacote que deve ser entregue aos jogadores. Ele contém `bzImage`, `vmlinux`, `System.map`,
`kernel.config`, `kvuln.ko` e o fonte do desafio. **Nunca distribua o diretório
`dist/` inteiro nem `dist/initramfs.cpio.gz`**: o initramfs contém a flag da
turma e componentes internos do ambiente.

Para testar interativamente antes da instalação:

```sh
bash run-local.sh
```

## 4. Instalar o acesso SSH automático

Coloque todas as chaves públicas autorizadas em um arquivo, uma por linha, e
execute:

```sh
sudo bash install-host.sh --authorized-keys ./alunos_authorized_keys
```

Se o host tiver regras SSH condicionais por origem, endereço local ou porta,
informe também um contexto representativo do endpoint dos alunos. Por exemplo:

```sh
sudo bash install-host.sh --authorized-keys ./alunos_authorized_keys \
  --ssh-test-client-host aluno.exemplo \
  --ssh-test-client-address 198.51.100.10 \
  --ssh-test-local-address 10.0.20.5 \
  --ssh-test-local-port 2222
```

Sem essas opções, a validação efetiva usa o contexto de loopback na porta 22.
`--ssh-test-client-host` representa o nome reverso da origem visto pelo servidor,
não o hostname do próprio laboratório.

O instalador:

1. cria a conta de host bloqueada `kernelctf` (ela não é o `ctf` do guest);
2. instala artefatos `root:kernelctf 0440` em `/opt/kernel-ctf`;
3. cria `/run/kernel-ctf` como diretório privado via `systemd-tmpfiles`;
4. instala chaves root-owned em `/etc/ssh/authorized_keys/kernelctf`;
5. acrescenta um bloco `Match User` gerenciado no fim de `sshd_config`;
6. valida a sintaxe com `sshd -t` e a política efetiva com `sshd -T -C`, usando
   o contexto configurado, antes de trocar o arquivo e recarregar `ssh.service`.

Teste a partir de outra conexão, mantendo a sessão administrativa aberta:

```sh
ssh -tt kernelctf@IP_DO_LAB
```

`-tt` é necessário para uma experiência de terminal previsível. `exit` dentro
do guest desliga QEMU. Fechar abruptamente o SSH ativa o trap do host e mata o
grupo de processos.

Publique o SSH dos alunos em uma interface/rede ou porta dedicada, filtrada para
as origens da turma. Preserve uma rota administrativa separada — idealmente uma
VLAN de gerência e, no mínimo, outra porta restrita por firewall — para que um
erro no endpoint dos alunos não bloqueie a manutenção. O instalador configura a
conta e o `Match User`, mas a separação de rede e portas continua sendo tarefa
do administrador.

## Atualizar uma aula

Faça a troca em uma janela de manutenção. Primeiro feche a porta/rede dos
alunos para novas conexões, aguarde as sessões QEMU existentes terminarem
(`drain`) e confirme que não há instâncias ativas. Atualize Debian, QEMU e
OpenSSH no host dedicado, reinicie o host se necessário e só então troque
flag/nível, reconstrua e reinstale os artefatos:

```sh
bash configure.sh --level 3 --flag-prompt
bash reset.sh
make test
sudo bash install-host.sh
```

Teste pela rede/porta dos alunos antes de reabrir o ingresso. Em atualizações,
`install-host.sh` preserva o arquivo de chaves existente. Para forçar novo
download e nova extração do kernel:

```sh
bash reset.sh --purge-downloads
```

## Enviar um binário do exercício ao guest

O guest não tem rede nem compartilhamento com o host por projeto. Compile o
programa de treinamento estaticamente na estação do aluno e calcule seu digest:

```sh
sha256sum programa-ctf
base64 -w 76 programa-ctf
```

Na VM, rode `upload NOME [SHA256]`; por exemplo, `upload programa-ctf` ou
`upload programa-ctf DIGEST_DE_64_HEXADECIMAIS`. Cole o base64 em linhas curtas e
termine com uma linha contendo apenas `.`. Se informado, o SHA-256 é validado
antes de o arquivo receber permissão de execução. O arquivo ficará em
`/home/ctf/programa-ctf` somente naquela sessão.

## Estrutura principal

- `challenge/`: módulo vulnerável de exemplo.
- `rootfs/`: PID 1, helper de identidade, passwd/group e utilitários do aluno.
- `scripts/check-deps.sh`: auditoria de dependências por perfil.
- `build.sh`: kernel, módulo, initramfs, manifesto SHA-256 e handout público.
- `reset.sh`: remove somente `build/` e `dist/` e reconstrói do zero.
- `bin/kernel-ctf-session`: lifecycle e isolamento QEMU.
- `install-host.sh`: conta, arquivos, tmpfiles e `sshd` no Debian 12.
- `tests/`: revisão estática e boot real automatizado.

O modelo de ameaça e os limites da expressão “isolado” estão documentados em
[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md).
