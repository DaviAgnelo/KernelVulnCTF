#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#define CTF_UID ((uid_t)1000)
#define CTF_GID ((gid_t)1000)
#define FLAG_PATH "/root/flag.txt"
#define CONSOLE_PATH "/dev/console"
#define VULN_DEVICE_PATH "/dev/kvuln"
#define KVULN_EXPECTED_PREFIX "stack-gateway: hello from kernel\n"

static void fatal(const char *format, ...)
{
    va_list arguments;

    fputs("[FATAL] ctf-login: ", stderr);
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    va_end(arguments);
    fputc('\n', stderr);
    exit(111);
}

static void configure_console(void)
{
    int console_fd;

    if (setsid() < 0)
        fatal("setsid falhou: %s", strerror(errno));

    console_fd = open(CONSOLE_PATH, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (console_fd < 0)
        fatal("não foi possível abrir %s: %s", CONSOLE_PATH, strerror(errno));

    if (ioctl(console_fd, TIOCSCTTY, 1) < 0)
        fatal("não foi possível assumir o console: %s", strerror(errno));

    if (dup2(console_fd, STDIN_FILENO) < 0 ||
        dup2(console_fd, STDOUT_FILENO) < 0 ||
        dup2(console_fd, STDERR_FILENO) < 0)
        fatal("dup2 do console falhou: %s", strerror(errno));

    if (console_fd > STDERR_FILENO)
        close(console_fd);
}

static void validate_flag_before_drop(void)
{
    struct stat details;

    if (lstat(FLAG_PATH, &details) < 0)
        fatal("flag ausente em %s: %s", FLAG_PATH, strerror(errno));

    if (!S_ISREG(details.st_mode) || details.st_nlink != 1)
        fatal("a flag deve ser um arquivo regular sem hard links");

    if (details.st_uid != 0 || details.st_gid != 0)
        fatal("a flag não pertence a root:root");

    if ((details.st_mode & 0777) != 0400)
        fatal("a flag deve ter modo 0400, modo atual=%03o",
              details.st_mode & 0777);
}

static void drop_privileges(void)
{
    uid_t real_uid, effective_uid, saved_uid;
    gid_t real_gid, effective_gid, saved_gid;

    if (setgroups(0, NULL) < 0)
        fatal("setgroups falhou: %s", strerror(errno));

    if (setresgid(CTF_GID, CTF_GID, CTF_GID) < 0)
        fatal("setresgid(1000) falhou: %s", strerror(errno));

    if (setresuid(CTF_UID, CTF_UID, CTF_UID) < 0)
        fatal("setresuid(1000) falhou: %s", strerror(errno));

    if (getresuid(&real_uid, &effective_uid, &saved_uid) < 0 ||
        getresgid(&real_gid, &effective_gid, &saved_gid) < 0)
        fatal("não foi possível verificar os IDs após a troca");

    if (real_uid != CTF_UID || effective_uid != CTF_UID ||
        saved_uid != CTF_UID || real_gid != CTF_GID ||
        effective_gid != CTF_GID || saved_gid != CTF_GID)
        fatal("troca de identidade incompleta: uid=%u/%u/%u gid=%u/%u/%u",
              real_uid, effective_uid, saved_uid,
              real_gid, effective_gid, saved_gid);

    if (getgroups(0, NULL) != 0)
        fatal("grupos suplementares não foram removidos");
}

static void validate_flag_is_denied(void)
{
    int flag_fd;

    errno = 0;
    flag_fd = open(FLAG_PATH, O_RDONLY | O_CLOEXEC);
    if (flag_fd >= 0) {
        close(flag_fd);
        fatal("UID 1000 conseguiu abrir a flag; recusando shell");
    }

    if (errno != EACCES)
        fatal("teste de acesso à flag falhou de modo inesperado: %s",
              strerror(errno));
}

static void prepare_environment(void)
{
    if (clearenv() != 0)
        fatal("clearenv falhou");

    if (setenv("HOME", "/home/ctf", 1) != 0 ||
        setenv("USER", "ctf", 1) != 0 ||
        setenv("LOGNAME", "ctf", 1) != 0 ||
        setenv("SHELL", "/bin/sh", 1) != 0 ||
        setenv("PATH", "/bin", 1) != 0 ||
        setenv("TERM", "linux", 1) != 0)
        fatal("não foi possível criar o ambiente do usuário");

    if (chdir("/home/ctf") < 0)
        fatal("chdir(/home/ctf) falhou: %s", strerror(errno));

    umask(0077);
}

static void validate_training_device(void)
{
    unsigned char leak_buffer[128];
    unsigned char write_probe[65];
    static const unsigned char expected_prefix[] = KVULN_EXPECTED_PREFIX;
    ssize_t bytes_read, bytes_written;
    int device_fd;

    device_fd = open(VULN_DEVICE_PATH, O_RDWR | O_CLOEXEC);
    if (device_fd < 0)
        fatal("UID 1000 não conseguiu abrir %s: %s",
              VULN_DEVICE_PATH, strerror(errno));

    bytes_read = read(device_fd, leak_buffer, sizeof(leak_buffer));
    if (bytes_read != (ssize_t)sizeof(leak_buffer))
        fatal("interface de leitura divergente: esperado=%zu obtido=%zd",
              sizeof(leak_buffer), bytes_read);

    if (memcmp(leak_buffer, expected_prefix, sizeof(expected_prefix) - 1) != 0)
        fatal("prefixo inesperado na resposta de %s", VULN_DEVICE_PATH);

    memset(write_probe, 'A', sizeof(write_probe));
    bytes_written = write(device_fd, write_probe, sizeof(write_probe));
    close(device_fd);
    if (bytes_written != (ssize_t)sizeof(write_probe))
        fatal("interface de escrita divergente: esperado=%zu obtido=%zd",
              sizeof(write_probe), bytes_written);

    puts("SELFTEST: KVULN_OVERSIZED_READ=PASS");
    puts("SELFTEST: KVULN_OVERSIZED_WRITE=PASS");
}

int main(int argc, char **argv)
{
    bool self_test = false;
    char *const shell_argv[] = { (char *)"-sh", NULL };

    if (argc == 2 && strcmp(argv[1], "--self-test") == 0)
        self_test = true;
    else if (argc != 1)
        fatal("argumento inválido");

    if (geteuid() != 0)
        fatal("ctf-login precisa iniciar como root");

    configure_console();
    validate_flag_before_drop();
    prepare_environment();
    drop_privileges();
    validate_flag_is_denied();

    printf("[OK] identidade verificada: uid=%u gid=%u; acesso à flag=negado\n",
           (unsigned)geteuid(), (unsigned)getegid());
    fflush(stdout);

    if (self_test) {
        validate_training_device();
        puts("SELFTEST: PASS");
        return 0;
    }

    execve("/bin/sh", shell_argv, environ);
    fatal("execve(/bin/sh) falhou: %s", strerror(errno));
    return 111;
}
