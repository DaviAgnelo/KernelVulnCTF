# Implantação no Proxmox

## Topologia recomendada

Use uma VM Proxmox exclusivamente para o laboratório:

- Linux x86_64 com os requisitos de [PLATFORMS.md](PLATFORMS.md); Debian 12
  Bookworm amd64 mínimo é a baseline de validação recomendada;
- 4 vCPU, 4–8 GiB de RAM e 40 GiB de disco para compilar;
- controladora de disco VirtIO/SCSI normal; esse disco pertence somente ao host
  Linux externo, nunca é anexado ao QEMU do aluno;
- uma interface/VLAN de gerência para SSH administrativo e um endpoint de aluno
  separado por rede ou, no mínimo, por porta e regras de firewall;
- nenhum mount de backup, credencial, storage de produção ou secret da
  infraestrutura dentro dessa VM.

Não use um container LXC para este caso. A VM externa é uma camada importante
contra bugs no QEMU e contra erros operacionais no host do laboratório. Para
instalar o endpoint SSH, a distribuição escolhida precisa executar `systemd`
como PID 1 e fornecer OpenSSH; build e runtime não dependem de systemd.

## Aceleração aninhada

No hardware/VM do Proxmox, configure CPU type `host` e habilite nested
virtualization no nó se a política permitir. Dentro do host Linux, valide:

```sh
test -r /dev/kvm && test -w /dev/kvm && echo KVM_OK
```

Com `ACCELERATION=kvm`, o instalador exige que a conta consiga ler e escrever
`/dev/kvm`. Em `auto`, ele concede o grupo somente quando KVM está realmente
acessível; caso contrário, remove grupos suplementares e o launcher usa TCG.
TCG dispensa `/dev/kvm`, porém é mais lento. O verificador e o launcher aceitam
um binário compatível exposto como `qemu-system-x86_64` ou `qemu-kvm`.

## Rede, manutenção e snapshot

No firewall Proxmox, permita a porta SSH dos alunos somente a partir das redes
da turma. Restrinja a rede/porta administrativa aos IPs da equipe e não dependa
do mesmo caminho de acesso oferecido aos jogadores. Bloqueie egress não
administrativo quando possível. Essas regras protegem o host Linux externo; o
QEMU interno já recebe `-nic none`.

Antes de atualizar o host ou os artefatos, bloqueie novas conexões de alunos,
aguarde as QEMUs ativas terminarem e faça a manutenção pela rota administrativa.
Atualize a distribuição, QEMU e OpenSSH, aplique o reboot necessário, rode
novamente `make test` (estático, initramfs, níveis 0–4 e launcher) e só então
reabra o acesso.

O perfil por capacidades não certifica automaticamente toda versão de toda
distribuição. Nesta documentação, Debian 12 + QEMU é a baseline a confirmar com
boot real. Execute a matriz completa no host escolhido; uma verificação estática
local, sozinha, não demonstra boot, isolamento nem solucionabilidade E2E.

Depois de instalar e testar:

1. desligue ou congele o acesso dos alunos e confirme o `drain` das sessões;
2. crie um snapshot limpo no Proxmox;
3. abra o acesso da turma;
4. ao final, reverta ou destrua a VM externa.

O `reset.sh` reconstrói os artefatos do desafio, mas não substitui o snapshot da
VM externa como mecanismo de recuperação do host.
