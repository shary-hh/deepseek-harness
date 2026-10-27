SHELL := /bin/bash
.DEFAULT_GOAL := help

VERSION := $(shell cat VERSION)
DIST := dist

.PHONY: help test lint secrets deb rpm appimage exe all checksums clean install-hooks verify

help: ## Muestra esta ayuda
	@echo "deepseek-harness $(VERSION) - empaquetado"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

test: ## Ejecuta todas las pruebas locales
	./tests/run-tests.sh

test-cli: ## Pruebas de la CLI contra un servidor mock
	node --test tests/cli.test.js

lint: ## bash -n + shellcheck + escaneo de secretos
	@for f in scripts/*.sh scripts/lib/*.sh install.sh uninstall.sh; do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null; then shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh install.sh uninstall.sh; fi
	@./scripts/scan-secrets.sh

secrets: ## Busca credenciales en el árbol de trabajo
	./scripts/scan-secrets.sh

deb: ## Construye el .deb
	./scripts/build-deb.sh

rpm: ## Construye el .rpm (requiere rpmbuild)
	./scripts/build-rpm.sh

appimage: ## Construye el AppImage
	./scripts/build-appimage.sh

exe: ## Construye el ZIP/EXE de Windows
	./scripts/build-exe.sh

all: ## Construye todo lo posible en esta máquina
	./scripts/build-all.sh

checksums: ## Regenera dist/SHA256SUMS
	./scripts/generate-checksums.sh

verify: ## Verifica dist/SHA256SUMS y la firma GPG si existe
	@args="--dir $(DIST)"; [ -f "$(DIST)/SHA256SUMS.asc" ] && args="$$args --signature"; \
	  ./scripts/verify-release.sh $$args

clean: ## Borra build/ y dist/
	rm -rf build dist

install-hooks: ## Activa los hooks de git del repo
	git config core.hooksPath .githooks
	chmod +x .githooks/*
	@echo "hooks activados (.githooks)"
