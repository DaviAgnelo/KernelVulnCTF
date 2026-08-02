# Operação do instrutor

## Trocar configuração

`config/lab.conf` aceita apenas valores simples, sem espaços ou expansão de
shell. Os campos mais usados são:

- `DEFAULT_LEVEL`: 0–4;
- `MEMORY_MIB` e `VCPUS`: recursos por aluno;
- `MAX_SESSIONS`: concorrência do mesmo host;
- `SESSION_TIMEOUT_SECONDS`: encerramento forçado;
- `ACCELERATION`: `auto`, `kvm` ou `tcg`.

Use `configure.sh --flag-prompt` para informar a flag sem eco. Em automação,
aceite somente `--flag-file` apontando para um arquivo de uma linha, pertencente
ao usuário atual e sem acesso para grupo/outros (`0600` recomendado); nunca
coloque a flag literal em argumentos ou comandos do histórico.
Depois execute `reset.sh`, o teste de integração e `install-host.sh`. Mudar
apenas o arquivo fonte não altera uma instalação já publicada.

O teste de integração percorre os níveis 0–4. A matriz completa de SMEP, KASLR,
SMAP, KPTI, `kptr_restrict`, `dmesg_restrict` e `perf_event_paranoid` está no
README; não publique um nível que não tenha passado pelo boot automatizado.

## Plataforma do host

Build e runtime seguem um contrato de capacidades em Linux x86_64. Os perfis
Debian/Ubuntu, Fedora/RHEL-like, Arch-like e openSUSE/SLES fornecem dicas de
pacotes; uma distribuição desconhecida usa o perfil genérico. O endpoint SSH
instalado por `install-host.sh` exige também `systemd` ativo como PID 1 e
OpenSSH. Consulte [PLATFORMS.md](PLATFORMS.md) e trate a saída de
`scripts/check-deps.sh` como autoridade — o nome do pacote nunca substitui a
prova da capacidade.

O QEMU pode estar instalado como `qemu-system-x86_64` ou `qemu-kvm`. Em
variantes RHEL, BusyBox e bibliotecas estáticas podem depender de EPEL, CRB ou
outro repositório complementar; em SUSE, `busybox-static` não está disponível
em todas as versões. Não improvise um BusyBox dinâmico: o initramfs exige um
binário estaticamente ligado.

Compatibilidade declarada não significa que todas as versões dessas famílias
tenham sido certificadas E2E. Debian 12 + QEMU é a baseline a confirmar; execute
no host de publicação o build, os boots 0–4 e o launcher. Validação estática em
outra plataforma não comprova esse fluxo.

## Chaves dos alunos

Mantenha um arquivo com uma chave pública por linha. O instalador o copia para
`/etc/ssh/authorized_keys/kernelctf`, propriedade de root. Para revogar alguém,
gere o arquivo sem aquela chave e reinstale com `--authorized-keys`.

Todos entram na mesma conta restrita do host, mas recebem QEMUs independentes.
Não há diretório persistente compartilhado entre as instâncias.

## Material dos jogadores

Entregue somente `dist/player-handout.tar.xz` e o respectivo arquivo `.sha256`.
O pacote público contém
`bzImage`, `vmlinux`, `System.map`, `kernel.config`, `kvuln.ko` e o fonte do
desafio. Confira o conteúdo do arquivo antes da publicação.

Nunca publique o diretório `dist/`, `dist/initramfs.cpio.gz`, `config/flag.txt`
ou uma cópia descompactada do initramfs. Esses materiais administrativos podem
revelar diretamente a flag, além de detalhes que não fazem parte do handout.

O passo a passo técnico `INSTRUCTOR-SOLUTIONS.md` é distribuído separadamente,
por canal privado, e ignorado pelo Git. Ele contém estratégias e soluções dos
níveis 0–4: **nunca o copie para o handout, repositório público, ambiente dos
alunos ou material compartilhado da turma**. Faça uma revisão explícita do
pacote final antes de distribuí-lo.

## Rede administrativa e atualização segura

Mantenha o SSH administrativo em uma rede/interface de gerência separada da
rede dos alunos. Se isso não for possível, use ao menos uma porta administrativa
distinta, limitada no firewall aos IPs da equipe, e preserve uma sessão nessa
rota ao alterar SSH. A porta dos alunos deve aceitar somente as redes da turma.
O instalador valida a sintaxe com `sshd -t`, confere a política efetiva da conta
com `sshd -T -C` e restaura a configuração anterior se a validação ou o reload
falhar. Ele recarrega a unidade OpenSSH detectada (`ssh.service` ou
`sshd.service`); em ativação exclusiva por socket, deixa a configuração pronta
para a próxima ativação de `ssh.socket`/`sshd.socket`. Se houver regras
`Match Address`, `Match Host`,
`Match LocalAddress` ou `Match LocalPort`, passe as opções `--ssh-test-client-host`,
`--ssh-test-client-address`, `--ssh-test-local-address` e
`--ssh-test-local-port` com um contexto representativo da rota dos alunos. Sem
elas, o teste usa loopback e porta 22. Uma regra de firewall externa ainda pode
causar lockout.

Antes de alterar kernel, flag, QEMU, OpenSSH ou o launcher:

1. bloqueie novas conexões na porta dos alunos;
2. aguarde as sessões existentes terminarem e confirme o `drain` de todos os
   processos QEMU do usuário `kernelctf`;
3. atualize o host Linux e reinicie-o se a atualização exigir;
4. reconstrua e execute todos os testes;
5. reinstale, valide pela rota dos alunos e só então reabra a porta.

Não substitua artefatos durante sessões ativas. Planeje a atualização do host e
o reboot antes de congelar o snapshot usado na turma.

Ordem recomendada antes de abrir a turma:

```sh
bash scripts/check-deps.sh all
bash reset.sh
bash tests/static.sh
bash tests/initramfs.sh
bash tests/integration.sh
bash tests/launcher.sh
sudo bash install-host.sh --authorized-keys ./alunos_authorized_keys
ssh -tt -p PORTA_DOS_ALUNOS kernelctf@IP_DO_LAB
```

Crie o snapshot Proxmox somente depois desse teste.
