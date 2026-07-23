# Modelo de ameaça

## Ativos e fronteiras

O aluno controla totalmente o guest: pode explorar o módulo, obter UID 0 no
kernel vulnerável, causar panic e modificar o initramfs já expandido em RAM. Isso
é o objetivo do exercício. As fronteiras que devem sobreviver são:

1. o processo QEMU sem privilégios no Debian;
2. a VM Debian 12 dedicada no Proxmox;
3. o nó Proxmox e o restante da infraestrutura.

Não existe isolamento “matematicamente completo” para código hostil. Bugs de
device emulation/QEMU ainda são uma classe de VM escape. Por isso o projeto usa
pouquíssimos devices, sandbox seccomp e uma VM externa descartável, mas não deve
conviver com segredos reais.

## Controles do guest

- somente kernel e initramfs; nenhum drive persistente;
- `-nodefaults`, `-nic none`, `-monitor none`, sem GDB, 9p, USB ou passthrough;
- serial ligado diretamente ao descritor SSH;
- memória, vCPU, tempo e memória virtual do host limitados;
- `-no-reboot` e `panic=1` fazem panic/reboot encerrar a instância;
- o PID 1 valida em cada boot as flags SMEP/SMAP da CPU virtual, os parâmetros
  KASLR/KPTI e os sysctls esperados para o nível 0–4 selecionado;
- todo estado gravável reside na RAM da instância.

## Controles da identidade

O PID 1 é um script não interativo interpretado pelo shell do initramfs; ele
prepara mounts e carrega o módulo como root, mas nunca expõe um shell root
interativo. O helper `/sbin/ctf-login`:

1. exige EUID 0 apenas na entrada;
2. valida proprietário e modo da flag;
3. cria sessão/controlador de terminal;
4. limpa o ambiente e grupos suplementares;
5. fixa UID/GID real, efetivo e salvo em 1000;
6. relê todos os IDs;
7. tenta abrir a flag e exige falha `EACCES`;
8. só então executa `/bin/sh`.

Se qualquer passo falhar, o helper retorna 111 e PID 1 chama `poweroff`. Caso o
poweroff falhe, PID 1 dorme indefinidamente; nenhum shell root interativo é
exposto.

O `/bin/busybox` continua disponível como multiplexer. Por isso o aluno pode
invocar applets compilados no binário mesmo quando não existe um link com o nome
do applet no rootfs. O BusyBox não tem bit setuid e os applets herdam as
credenciais UID/GID 1000 já fixadas; oferecer comandos adicionais aumenta a
superfície dentro do guest, mas não concede privilégios nem substitui os
controles de identidade e permissões.

## Controles do host SSH

- conta de sistema com senha bloqueada e home root-owned;
- chaves root-owned e artefatos `root:kernelctf`, não legíveis por outros
  usuários locais;
- `ForceCommand` sob `/usr/bin/env -i`;
- `PermitUserEnvironment` e `SetEnv` recusados, com `AcceptEnv` limitado a
  `LANG`/`LC_*` (`TERM` continua sendo a exceção exigida pelo protocolo) antes
  de o ambiente ser limpo;
- forwarding TCP, agent, X11, túnel e `~/.ssh/rc` desabilitados;
- QEMU nunca roda como root;
- artefatos verificados contra `SHA256SUMS` em todo login;
- locks limitam instâncias simultâneas;
- trap em HUP/TERM/INT/EXIT encerra o grupo de processos do QEMU.

## Riscos residuais

- vulnerabilidade no QEMU ou KVM usada pelo guest;
- DoS do host dentro dos limites ainda possíveis (CPU e I/O de console);
- vazamento da flag por um instrutor/administrador do host, que naturalmente
  consegue extrair o initramfs;
- vazamento da flag pela distribuição acidental de `dist/` ou do
  `initramfs.cpio.gz`; somente `player-handout.tar.xz` é público;
- erro de firewall/Proxmox fora do escopo dos scripts;
- compartilhamento de uma chave SSH entre alunos, se o instrutor optar por isso.

Mitigue mantendo o Debian dedicado, atualizado antes de congelar a turma,
separando redes, usando chaves individuais e restaurando o snapshot externo ao
fim da atividade.
