# KernelVulnCTF

KernelVulnCTF é um laboratório educacional de exploração do kernel Linux. Cada conexão SSH inicia uma VM QEMU descartável com o desafio `stack-gateway`: um módulo deliberadamente vulnerável a vazamento e overflow de pilha, dividido em cinco níveis progressivos de mitigação.

O aluno trabalha como UID/GID 1000 dentro do guest, explora somente `/dev/kvuln` e tenta obter acesso à flag protegida em `/root/flag.txt`. Ao sair, perder a conexão ou atingir o tempo limite, a VM é encerrada e todo o estado da sessão é descartado.

## Destaques

- Cinco níveis, do primeiro overflow até SMEP, KASLR, SMAP e KPTI combinados.
- Uma VM QEMU nova e isolada para cada sessão SSH.
- Guest sem rede, disco compartilhado, 9p, monitor ou GDB.
- Build reproduzível do Linux 6.1.75, com SHA-256 fixado.
- Handout próprio para jogadores, sem a flag e sem o initramfs administrativo.
- Upload de exploits estáticos por Base64, com verificação SHA-256 opcional.
- Testes estáticos, de empacotamento, initramfs, perfis 0–4 e launcher.

## Como o laboratório funciona

```text
SSH do aluno
└── sshd com ForceCommand
    └── kernel-ctf-session sem privilégios no host
        └── QEMU descartável
            └── /init
                └── shell BusyBox como usuário ctf (UID/GID 1000)
                    └── /dev/kvuln → exploração → /root/flag.txt
```

| Nível | SMEP | KASLR | SMAP | KPTI | Objetivo didático principal |
|---:|:---:|:---:|:---:|:---:|---|
| 0 | não | não | não | não | Entender o leak, o overflow e a volta segura ao userland |
| 1 | sim | não | não | não | Substituir execução em userspace por ROP no kernel |
| 2 | sim | sim | não | não | Derivar a base do kernel a partir de um vazamento |
| 3 | sim | sim | sim | não | Manter a cadeia e os dados necessários no espaço do kernel |
| 4 | sim | sim | sim | sim | Retornar pelo trampoline compatível com KPTI |

“Nível 0” significa apenas que as quatro mitigações graduadas da tabela estão desativadas. As demais proteções gerais do kernel continuam ativas; o stack protector é removido somente do módulo vulnerável.

## Requisitos

- Uma **VM Linux x86_64 dedicada**; não use LXC nem uma máquina com dados importantes.
- Debian 12 é a baseline recomendada.
- 4 vCPU, 4–8 GiB de RAM e cerca de 40 GiB livres durante a compilação.
- QEMU, BusyBox estático, GNU cpio, toolchain C, headers e OpenSSH.
- KVM é opcional. Sem `/dev/kvm`, o laboratório usa TCG automaticamente.

Outras famílias Linux têm orientações em [PLATFORMS.md](KernelVuln/docs/PLATFORMS.md), mas devem ser validadas no host de destino.

## Instalação

### 1. Clonar o projeto

```bash
git clone https://github.com/DaviAgnelo/KernelVulnCTF.git
cd KernelVulnCTF/KernelVuln
```

### 2. Instalar as dependências no Debian 12

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends \
  build-essential binutils bc bison flex cpio gzip xz-utils wget ca-certificates \
  busybox-static libelf-dev libssl-dev openssl dwarves pkg-config perl python3 \
  qemu-system-x86 util-linux coreutils findutils grep sed gawk tar diffutils \
  openssh-server systemd passwd

bash scripts/check-deps.sh all
```

Execute a configuração, o build e os testes como usuário comum. Somente `install-host.sh` deve ser executado com `sudo`.

### 3. Escolher o nível e definir a flag

Use o prompt sem eco para evitar que a flag apareça no histórico ou na lista de processos:

```bash
bash configure.sh --level 0 --flag-prompt
```

Troque `0` por um nível entre `0` e `4`.

### 4. Construir e validar

```bash
bash reset.sh
make test
```

O primeiro build baixa e compila o kernel, pode levar vários minutos e ocupar alguns GiB. Antes de abrir uma turma, confirme no próprio host Linux que os cinco boots, o launcher e o acesso à flag por um exploit de aluno funcionam ponta a ponta.

### 5. Testar localmente

```bash
bash run-local.sh
```

### 6. Publicar o acesso SSH para os alunos

Coloque uma chave pública por linha em `alunos_authorized_keys` e execute:

```bash
sudo bash install-host.sh --authorized-keys ./alunos_authorized_keys
```

Mantenha a sessão administrativa aberta e teste por outra conexão:

```bash
ssh -tt kernelctf@IP_DO_LAB
```

Para Proxmox, separação de rede e opções avançadas do SSH, consulte [PROXMOX.md](KernelVuln/docs/PROXMOX.md) e a [documentação completa do laboratório](KernelVuln/README.md).

## Como jogar

O instrutor entrega somente `player-handout.tar.xz` e seu arquivo `.sha256`. O pacote contém `bzImage`, `vmlinux`, `System.map`, `kernel.config`, `kvuln.ko` e o fonte do módulo.

Como o guest não possui rede nem compartilhamento de arquivos, compile o exploit estaticamente na sua máquina e envie-o durante a sessão:

```bash
gcc -O2 -static -o solve solve.c
sha256sum solve
base64 -w 76 solve
```

No guest, execute `upload solve SHA256`, cole o Base64 e finalize com uma linha contendo apenas `.`. Depois rode `./solve`.

## Tutorial de resolução

<details>
<summary><strong>⚠️ Spoilers: mostrar o roteiro técnico dos níveis 0–4</strong></summary>

> Este roteiro explica a estratégia completa, mas não fornece offsets prontos. Eles dependem exatamente dos binários do handout e devem ser medidos em `kvuln.ko` e `vmlinux`.

### 1. Reconhecimento comum a todos os níveis

Leia `kvuln.c`. O módulo oferece duas primitivas em `/dev/kvuln`:

- `read`: copia até 512 bytes a partir de um buffer de pilha de 64 bytes e, portanto, vaza a pilha do kernel;
- `write`: aceita até 512 bytes no mesmo tipo de buffer e, portanto, sobrescreve o frame e o endereço de retorno.

Abra um descritor separado para cada leak: depois da primeira leitura, `*ppos` impede outra leitura no mesmo descritor. Mapeie o frame com:

```bash
objdump -dr -M intel kvuln.ko > kvuln.asm
nm -n vmlinux > symbols.txt
```

No exploit, salve `CS`, `SS`, `RSP` e `RFLAGS` antes de acionar a vulnerabilidade. Localize no leak o frame salvo e um endereço de retorno reconhecível; confirme o offset até o `RIP` com a desmontagem do `kvuln_write`.

A meta usual é executar no ring 0 uma cadeia equivalente a `commit_creds(prepare_kernel_cred(NULL))` e voltar corretamente ao userland. Depois da volta, valide com `id` e leia `/root/flag.txt`.

### 2. Nível 0 — sem SMEP, KASLR, SMAP ou KPTI

Com endereços estáveis e SMEP desativado, a introdução mais direta é um ret2usr: sobrescreva o retorno com o endereço de uma função executável mapeada no processo, eleve as credenciais e finalize com uma sequência segura de `swapgs`/`iretq` para uma função userland que abre um shell.

Se preferir uma base que continue útil nos níveis seguintes, já resolva este nível com ROP do kernel. Use `System.map`/`vmlinux` para localizar as funções e gadgets, monte a cadeia depois do offset do retorno e preserve o frame exigido pela volta.

### 3. Nível 1 — SMEP

SMEP impede o kernel de executar a função ret2usr. Mantenha todo o fluxo de execução em endereços do kernel:

1. carregue `NULL` no primeiro argumento;
2. chame `prepare_kernel_cred`;
3. mova o ponteiro retornado para o primeiro argumento;
4. chame `commit_creds`;
5. use gadgets de `swapgs` e `iretq` para restaurar o estado salvo do usuário.

KASLR ainda está desativado, então os endereços podem ser calculados diretamente a partir dos artefatos entregues.

### 4. Nível 2 — SMEP + KASLR

Agora os offsets continuam estáveis, mas a base muda a cada boot. Use primeiro a leitura fora dos limites e procure um ponteiro canônico do kernel no frame vazado. Identifique a qual símbolo ou ponto de retorno ele corresponde e calcule:

```text
kernel_base = leaked_pointer - known_offset_in_vmlinux
runtime_address = kernel_base + symbol_or_gadget_offset
```

Rebase todos os gadgets e funções da cadeia. Faça o leak e o overflow na mesma sessão, porque uma nova conexão cria outra VM e outra randomização.

### 5. Nível 3 — SMEP + KASLR + SMAP

SMAP bloqueia acessos comuns do kernel a páginas de usuário, mas não remove a vulnerabilidade: `copy_from_user` alterna o estado necessário e ainda copia o payload para a pilha do kernel.

Evite cadeias que depois tentem buscar gadgets, argumentos ou estruturas em um buffer userland. Coloque a cadeia ROP completa e todos os valores necessários diretamente no payload que será copiado para o frame do kernel. O leak e o rebase do nível 2 continuam necessários.

### 6. Nível 4 — SMEP + KASLR + SMAP + KPTI

KPTI separa as tabelas de páginas usadas no kernel e no processo. A escalada de credenciais permanece igual, mas a volta simples usada antes deixa de ser suficiente.

Localize em `vmlinux` o trampoline de retorno do KPTI, normalmente associado a `swapgs_restore_regs_and_return_to_usermode`. Ajuste o endereço pela base vazada, inclua o padding exigido pela desmontagem e termine a cadeia com o trap frame salvo: `RIP`, `CS`, `RFLAGS`, `RSP` e `SS`. O trampoline restaura o contexto e troca a tabela de páginas antes de retornar ao userland.

### 7. Checklist de depuração

- O tamanho enviado está entre 65 e 512 bytes?
- O offset do `RIP` veio do `kvuln.ko` exato do handout?
- O ponteiro vazado pertence ao kernel base ou somente ao módulo?
- Todos os endereços foram rebased no nível atual?
- A pilha está alinhada como os gadgets e as chamadas esperam?
- O frame de retorno contém os valores de usuário salvos antes do overflow?
- No nível 4, a cadeia usa o trampoline do KPTI e o padding correto?

</details>

## Estrutura do projeto

```text
KernelVulnCTF/
├── LICENSE
├── README.md
└── KernelVuln/
    ├── challenge/          # módulo vulnerável stack-gateway
    ├── config/             # nível, limites e manifesto do pacote-fonte
    ├── docs/               # operação, plataformas, Proxmox e threat model
    ├── rootfs/             # initramfs e ambiente do usuário ctf
    ├── scripts/            # dependências, build do initramfs e empacotamento
    ├── tests/              # validações estáticas e boots QEMU
    ├── build.sh
    ├── configure.sh
    ├── install-host.sh
    └── run-local.sh
```

## Avisos de segurança e operação

- Use este projeto somente para estudo, em uma VM Linux x86_64 dedicada e descartável.
- Nunca carregue `kvuln.ko` no kernel do host. O módulo é intencionalmente vulnerável.
- QEMU reduz o contato com o host, mas não é uma fronteira perfeita contra falhas do emulador ou do KVM. Prefira `ACCELERATION=tcg` quando o isolamento for mais importante que o desempenho.
- Nunca publique `config/flag.txt`, `dist/initramfs.cpio.gz`, o diretório `dist/` completo ou materiais administrativos. Entregue aos jogadores somente o `player-handout` e seu checksum.
- Preserve `.kernel-ctf-project` e `.gitignore` ao transferir a origem. Cópias com `KernelVuln/*` omitem arquivos ocultos; use `bash scripts/package-source.sh`.
- A instalação SSH pressupõe `systemd` e OpenSSH configurados corretamente. Mantenha uma rota administrativa separada e teste a política real antes de liberar a turma.
- Os testes estáticos já cobrem o contrato do projeto, mas não substituem build, boot, login SSH e exploração reais em Debian 12 + QEMU.

Consulte também o [modelo de ameaças](KernelVuln/docs/THREAT-MODEL.md) e o [guia do instrutor](KernelVuln/docs/INSTRUCTOR.md).

## Licença

Distribuído sob a [licença MIT](LICENSE).

## Autor

Desenvolvido por Davi Agnelo de Araujo Filho.
