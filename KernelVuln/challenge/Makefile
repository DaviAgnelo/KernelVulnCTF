obj-m += kvuln.o

# O bug é intencional. Estas opções mantêm a moldura da pilha didática e
# desativam o stack protector apenas neste módulo.
ccflags-y += -O0 -fno-stack-protector -fno-omit-frame-pointer
