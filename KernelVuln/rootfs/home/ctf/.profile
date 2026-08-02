export HOME=/home/ctf
export USER=ctf
export LOGNAME=ctf
export SHELL=/bin/sh
export PATH=/bin
export PS1='ctf@kernel-lab:\w\$ '

if ! /bin/busybox test "$(id -u)" = 1000 || \
   ! /bin/busybox test "$(id -g)" = 1000; then
    echo '[FATAL] identidade inesperada; encerrando a sessão.' >&2
    exit 111
fi

echo '[OK] shell ctf confirmado (UID/GID 1000).'
echo 'Use "upload NOME [SHA256]" para colar Base64; finalize com uma linha ".".'
cd /home/ctf || exit 111
