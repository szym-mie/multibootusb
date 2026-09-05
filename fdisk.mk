.POSIX:
.SUFFIXES:

DEVS += $(DEV)1
DEVS += $(DEV)2
DEVS += $(DEV)3

.PHONY: init
init: $(DEVS)

# add checks for defined($(DEV))
$(DEVS):
	cat fdisk/init.fd | fdisk $(DEV)

.PHONY: clean
clean:
	cat fdisk/clean.fd | fdisk $(DEV)

