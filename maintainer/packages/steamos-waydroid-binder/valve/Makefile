ccflags-y += -I$(src)
ccflags-y += -DCONFIG_ANDROID_BINDER_DEVICES="\"binder\""
ccflags-y += -DCONFIG_ANDROID_BINDERFS="y"

obj-m := binder_linux.o
binder_linux-y := deps.o binder.o binder_alloc.o binder_netlink.o binderfs.o

KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KERNEL_SRC) V=0 M=$$PWD
