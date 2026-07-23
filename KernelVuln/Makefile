.PHONY: deps build reset reset-purge static-test initramfs-test integration-test launcher-test test
.NOTPARALLEL: test

deps:
	bash scripts/check-deps.sh all

build:
	bash build.sh all

reset:
	bash reset.sh

reset-purge:
	bash reset.sh --purge-downloads

static-test:
	bash tests/static.sh

initramfs-test:
	bash tests/initramfs.sh

integration-test:
	bash tests/integration.sh

launcher-test:
	bash tests/launcher.sh

test: static-test initramfs-test integration-test launcher-test
