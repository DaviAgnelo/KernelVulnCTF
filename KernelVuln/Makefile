.PHONY: deps deps-build deps-runtime deps-host deps-all source-package build reset \
	reset-purge static-test platform-test source-package-test initramfs-test \
	integration-test launcher-test test
.NOTPARALLEL: test

deps:
	bash scripts/check-deps.sh build

deps-build:
	bash scripts/check-deps.sh build

deps-runtime:
	bash scripts/check-deps.sh runtime

deps-host:
	bash scripts/check-deps.sh host-install

deps-all:
	bash scripts/check-deps.sh all

source-package:
	bash scripts/package-source.sh

build:
	bash build.sh all

reset:
	bash reset.sh

reset-purge:
	bash reset.sh --purge-downloads

static-test:
	bash tests/static.sh

platform-test:
	bash tests/platform.sh

source-package-test:
	bash scripts/package-source.sh --self-test

initramfs-test:
	bash tests/initramfs.sh

integration-test:
	bash tests/integration.sh

launcher-test:
	bash tests/launcher.sh

test: static-test platform-test source-package-test initramfs-test integration-test launcher-test
