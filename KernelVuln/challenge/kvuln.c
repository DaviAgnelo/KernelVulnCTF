// SPDX-License-Identifier: GPL-2.0
/*
 * stack-gateway: módulo deliberadamente vulnerável para um laboratório CTF.
 * Nunca carregue este módulo fora da VM descartável do projeto.
 */

#include <linux/fs.h>
#include <linux/init.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/uaccess.h>

#define KVULN_NAME "kvuln"
#define KVULN_STACK_BUFFER 64
#define KVULN_MAX_TRANSFER 512

/*
 * Impede que __builtin_object_size recupere o tamanho do array através do
 * chamador. CONFIG_HARDENED_USERCOPY e CONFIG_FORTIFY_SOURCE permanecem ativos
 * globalmente; o teste de boot confirma que o contrato didático deste módulo
 * continua disponível na compilação fixada do laboratório.
 */
static noinline void *kvuln_hide_pointer(void *pointer)
{
    asm volatile("" : "+r"(pointer) : : "memory");
    return pointer;
}

static noinline ssize_t kvuln_read(struct file *file, char __user *user_buf,
                                   size_t count, loff_t *ppos)
{
    char stack_buf[KVULN_STACK_BUFFER] = "stack-gateway: hello from kernel\n";
    void *opaque_stack_buf;
    size_t requested;

    (void)file;

    if (*ppos != 0)
        return 0;

    requested = min_t(size_t, count, KVULN_MAX_TRANSFER);
    opaque_stack_buf = kvuln_hide_pointer(stack_buf);

    /* VULNERABILIDADE INTENCIONAL: leitura além do fim da variável local. */
    if (copy_to_user(user_buf, opaque_stack_buf, requested) != 0)
        return -EFAULT;

    *ppos += requested;
    return requested;
}

static noinline ssize_t kvuln_write(struct file *file,
                                    const char __user *user_buf,
                                    size_t count, loff_t *ppos)
{
    char stack_buf[KVULN_STACK_BUFFER];
    void *opaque_stack_buf;

    (void)file;
    (void)ppos;

    if (count == 0 || count > KVULN_MAX_TRANSFER)
        return -EINVAL;

    opaque_stack_buf = kvuln_hide_pointer(stack_buf);

    /* VULNERABILIDADE INTENCIONAL: count pode ser maior que stack_buf. */
    if (copy_from_user(opaque_stack_buf, user_buf, count) != 0)
        return -EFAULT;

    return count;
}

static const struct file_operations kvuln_fops = {
    .owner = THIS_MODULE,
    .read = kvuln_read,
    .write = kvuln_write,
    .llseek = no_llseek,
};

static struct miscdevice kvuln_device = {
    .minor = MISC_DYNAMIC_MINOR,
    .name = KVULN_NAME,
    .fops = &kvuln_fops,
    .mode = 0660,
};

static int __init kvuln_init(void)
{
    int error = misc_register(&kvuln_device);

    if (error != 0)
        return error;

    pr_info("stack-gateway: /dev/%s registered (deliberately vulnerable)\n",
            KVULN_NAME);
    return 0;
}

static void __exit kvuln_exit(void)
{
    misc_deregister(&kvuln_device);
}

module_init(kvuln_init);
module_exit(kvuln_exit);

MODULE_DESCRIPTION("Deliberately vulnerable kernel CTF module");
MODULE_AUTHOR("Kernel CTF Lab");
MODULE_LICENSE("GPL");
