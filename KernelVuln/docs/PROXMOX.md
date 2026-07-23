# Implantação no Proxmox

## Topologia recomendada

Use uma VM Proxmox exclusivamente para o laboratório:

- Debian 12 Bookworm amd64, instalação mínima;
- 4 vCPU, 4–8 GiB de RAM e 40 GiB de disco para compilar;
- controladora de disco VirtIO/SCSI normal; esse disco pertence somente ao host
  Debian, nunca é anexado ao QEMU do aluno;
- uma interface/VLAN de gerência para SSH administrativo e um endpoint de aluno
  separado por rede ou, no mínimo, por porta e regras de firewall;
- nenhum mount de backup, credencial, storage de produção ou secret da
  infraestrutura dentro dessa VM.

Não use um container LXC para este caso. A VM externa é uma camada importante
contra bugs no QEMU e contra erros operacionais no host Debian.

## Aceleração aninhada

No hardware/VM do Proxmox, configure CPU type `host` e habilite nested
virtualization no nó se a política permitir. Dentro do Debian, valide:

```sh
test -r /dev/kvm && test -w /dev/kvm && echo KVM_OK
```

Com `ACCELERATION=kvm`, o instalador exige que a conta consiga ler e escrever
`/dev/kvm`. Em `auto`, ele concede o grupo somente quando KVM está realmente
acessível; caso contrário, remove grupos suplementares e o launcher usa TCG.
TCG funciona no Debian 12, porém é mais lento.

## Rede, manutenção e snapshot

No firewall Proxmox, permita a porta SSH dos alunos somente a partir das redes
da turma. Restrinja a rede/porta administrativa aos IPs da equipe e não dependa
do mesmo caminho de acesso oferecido aos jogadores. Bloqueie egress não
administrativo quando possível. Essas regras protegem o host Debian; o QEMU
interno já recebe `-nic none`.

Antes de atualizar o host ou os artefatos, bloqueie novas conexões de alunos,
aguarde as QEMUs ativas terminarem e faça a manutenção pela rota administrativa.
Atualize Debian, QEMU e OpenSSH, aplique o reboot necessário, rode novamente
`make test` (estático, initramfs, níveis 0–4 e launcher) e só então reabra o
acesso.

Depois de instalar e testar:

1. desligue ou congele o acesso dos alunos e confirme o `drain` das sessões;
2. crie um snapshot limpo no Proxmox;
3. abra o acesso da turma;
4. ao final, reverta ou destrua a VM externa.

O `reset.sh` reconstrói os artefatos do desafio, mas não substitui o snapshot da
VM externa como mecanismo de recuperação do host.
