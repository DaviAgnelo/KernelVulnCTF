# Plataformas Linux suportadas por capacidades

## Contrato de compatibilidade

O projeto não depende mais do nome de uma única distribuição. Build e runtime
aceitam um host **Linux x86_64** quando todas as capacidades verificadas estão
presentes. A instalação do endpoint SSH tem requisitos adicionais: `systemd`
deve estar ativo como PID 1 e o OpenSSH Server deve estar instalado.

`scripts/check-deps.sh` é a autoridade. Os nomes de pacotes deste documento são
somente dicas para chegar às capacidades necessárias; versões, repositórios e
divisões de pacotes variam entre distribuições.

O detector lê `ID` e `ID_LIKE` de `/etc/os-release` e classifica o host em um
destes perfis:

| Perfil | Exemplos | Gerenciador sugerido |
|---|---|---|
| Debian/Ubuntu | Debian, Ubuntu, Linux Mint, Pop!_OS, Kali | `apt-get` |
| Fedora/RHEL-like | Fedora, RHEL, CentOS, Rocky, AlmaLinux, Oracle Linux | `dnf` ou `yum` |
| Arch-like | Arch Linux, Manjaro, EndeavourOS | `pacman` |
| openSUSE/SLES | openSUSE Leap/Tumbleweed, SLES | `zypper` |
| genérico | qualquer outro Linux x86_64 | detectado, se possível |

O perfil genérico não é uma recusa automática. Instale equivalentes locais e
deixe o verificador decidir pelas capacidades reais.

## Modos do verificador

Execute o modo mais restrito que corresponde à operação desejada:

```sh
bash scripts/check-deps.sh build
bash scripts/check-deps.sh runtime
bash scripts/check-deps.sh host-install
bash scripts/check-deps.sh all
```

Os atalhos equivalentes são `make deps-build`, `make deps-runtime`,
`make deps-host` e `make deps-all`; `make deps` preserva o caso mais comum e
valida apenas o ambiente de build.

- `build`: toolchain do kernel, GNU `cpio`/`tar`, libelf, OpenSSL, geração de
  binário estático e BusyBox estaticamente ligado;
- `runtime`: Bash 4.4+, QEMU x86_64 e utilitários usados pelo launcher;
- `host-install`: runtime, OpenSSH, ferramentas de contas e `systemd` ativo
  como PID 1;
- `all`: reúne os três contratos.

Configuração e build devem continuar sendo executados como usuário comum. Use
`sudo` somente para `install-host.sh` e para a instalação de pacotes no host.

## Capacidades importantes

O verificador não testa apenas a existência do comando. Entre outras condições,
ele exige:

- arquitetura Linux x86_64 e Bash 4.4 ou mais recente;
- GNU `cpio` com `--reproducible` e `--null`;
- GNU `tar` com `--sort` e `--mtime`;
- `mktemp` com `--tmpdir` e as opções GNU usadas de `sha256sum`, `timeout` e
  `stat`;
- BusyBox sem interpretador ELF dinâmico para compor o initramfs;
- toolchain capaz de ligar libelf, OpenSSL e um executável libc estático;
- QEMU disponível como `qemu-system-x86_64` ou `qemu-kvm`, com `-sandbox`,
  `-nodefaults`, `-no-user-config` e `-nic`;
- para publicação SSH, `sshd`, `systemctl`, `systemd-tmpfiles` e ferramentas de
  gerenciamento de usuários.

KVM é opcional. Com `ACCELERATION=auto`, o launcher usa KVM somente quando
`/dev/kvm` está acessível e recorre a TCG nos demais casos.

## Pacotes sugeridos

As linhas abaixo visam o modo `all`. Em instalações mínimas pode ser necessário
adicionar pacotes básicos como GNU `tar`, conforme a saída do verificador.

### Debian/Ubuntu

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends \
  build-essential bc bison flex cpio gzip xz-utils wget ca-certificates \
  busybox-static binutils libelf-dev libssl-dev openssl dwarves pkg-config \
  perl python3 bash qemu-system-x86 coreutils findutils util-linux grep sed gawk \
  tar openssh-server systemd passwd diffutils
```

### Fedora/RHEL-like

```sh
sudo dnf install \
  gcc make bc bison flex cpio gzip xz wget ca-certificates busybox binutils \
  elfutils-libelf-devel openssl-devel openssl dwarves pkgconf-pkg-config \
  perl python3 glibc-static bash qemu-system-x86-core coreutils findutils \
  util-linux grep sed gawk tar openssh-server systemd shadow-utils diffutils
```

Em Fedora, o pacote QEMU costuma expor `qemu-system-x86_64`. Em RHEL e
derivados, use o pacote `qemu-kvm` quando `qemu-system-x86-core` não existir.
BusyBox, `glibc-static`, libelf ou ferramentas de build podem depender de EPEL,
CRB/CodeReady Builder ou outro repositório complementar habilitado pelo
administrador. Não habilite um repositório às cegas: siga a documentação da
versão usada e rode novamente `check-deps.sh`.

### Arch-like

```sh
sudo pacman -S --needed \
  base-devel bc bison flex cpio gzip xz wget ca-certificates busybox binutils \
  libelf openssl pahole pkgconf perl python glibc bash qemu-system-x86 \
  coreutils findutils util-linux grep sed gawk tar openssh systemd shadow diffutils
```

### openSUSE/SLES

```sh
sudo zypper --non-interactive install \
  gcc make bc bison flex cpio gzip xz wget ca-certificates busybox-static \
  binutils libelf-devel libopenssl-devel openssl dwarves pkg-config perl \
  python3 glibc-devel-static bash qemu-x86 coreutils findutils util-linux grep \
  sed gawk tar openssh-server systemd shadow diffutils
```

A disponibilidade de `busybox-static` varia entre versões de openSUSE e SLES.
Um BusyBox estático confiável no `PATH` satisfaz o contrato; um BusyBox dinâmico
não satisfaz. Os nomes dos pacotes de desenvolvimento estático também podem
variar.

### Perfil genérico

Não há um comando universal. Instale equivalentes para:

```text
gcc make bc bison flex cpio gzip xz wget ca-certificates busybox-static
binutils libelf-devel openssl-devel openssl pahole pkg-config perl python3
libc-static-devel bash qemu-system-x86 coreutils findutils util-linux grep sed
gawk tar openssh-server systemd shadow diffutils
```

Depois execute `bash scripts/check-deps.sh all` e corrija cada capacidade
indicada, em vez de presumir compatibilidade pelo nome da distribuição.

## Systemd e OpenSSH

Build e execução local não exigem systemd. `install-host.sh`, porém, cria conta,
diretório de runtime via `systemd-tmpfiles` e configuração SSH transacional;
por isso recusa hosts sem `systemd` como PID 1. O instalador reconhece serviços
`ssh.service`/`sshd.service` e ativação por `ssh.socket`/`sshd.socket`.

Um container, WSL ou sistema com outro init pode eventualmente satisfazer o
modo `build`, mas não é um host de publicação aceito se falhar no modo
`host-install`. Em produção, use a VM dedicada recomendada em
[PROXMOX.md](PROXMOX.md).

O destino padrão `/opt/kernel-ctf` precisa estar em uma montagem executável; o
instalador recusa `noexec`. Quando `restorecon` existe, os caminhos publicados e
a configuração SSH recebem novamente o contexto conhecido pela política local.
Isso não substitui um teste real com SELinux/AppArmor ativos: não desabilite o
MAC para fazer o laboratório funcionar; corrija o contexto ou uma política
revisada e repita o login completo pela rota dos alunos.

## Validação antes da turma

Compatibilidade por capacidades não é sinônimo de validação E2E em todas as
distribuições. Debian 12 + QEMU é a baseline de referência a testar e confirmar;
os demais perfis são alvos de portabilidade, não uma alegação de certificação de
toda versão.

No host exato que será publicado, execute:

```sh
bash scripts/check-deps.sh all
bash reset.sh
bash tests/static.sh
bash tests/initramfs.sh
bash tests/integration.sh
bash tests/launcher.sh
```

Os dois últimos testes precisam iniciar QEMU; a integração deve concluir os
boots de todos os níveis 0–4. Uma validação estática local, especialmente fora
de Linux, não prova boot, funcionamento do KVM/TCG, isolamento do launcher nem
solucionabilidade do desafio.

Registre para cada turma a distribuição e versão, versão do QEMU, aceleração
usada e resultado de cada teste. Se qualquer etapa falhar, aquela combinação
deve ser tratada como não validada até a causa ser corrigida e a matriz completa
ser repetida.
