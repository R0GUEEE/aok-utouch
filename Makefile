# Thin orchestrator. The scripts hold the logic; this is for muscle memory.
SHELL := /bin/bash
.PHONY: all fetch deps qemu image app clean distclean check

all: qemu app

fetch:
	./scripts/00-fetch.sh

deps: fetch
	./scripts/05-build-deps.sh

qemu: deps
	./scripts/10-build-qemu-ios.sh

image:
	sudo ./scripts/20-make-ut-image.sh

app: qemu
	./scripts/30-build-app.sh

# Precompiled artefacts, the same two tarballs CI publishes.
prebuilt: deps-pack engine-pack

deps-pack: deps
	PACK=1 ./scripts/05-build-deps.sh

engine-pack: qemu
	PACK=1 ./scripts/10-build-qemu-ios.sh

# Restore instead of compiling: make restore DEPS_URL=... ENGINE_URL=...
restore:
	@test -n "$(ENGINE_URL)" || (echo "set ENGINE_URL=<release asset url>"; exit 1)
	@test -n "$(DEPS_URL)" || (echo "set DEPS_URL=<release asset url>"; exit 1)
	AOK_PREBUILT_DEPS="$(DEPS_URL)" ./scripts/05-build-deps.sh
	./scripts/09-restore-engine.sh "$(ENGINE_URL)"

# Read-only checks that do not need Xcode or root.
check:
	@for s in scripts/*.sh; do bash -n "$$s" && echo "$$s ok"; done
	@test -d src/qemu || echo "note: sources not fetched yet"
	@command -v xcodegen >/dev/null && (cd app && xcodegen dump --spec project.yml >/dev/null && echo "project.yml ok") || true
	@python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/pipeline.yml')); print('pipeline.yml ok')"
	@echo "deps hash:   $$(bash scripts/hash.sh deps)"
	@echo "engine hash: $$(bash scripts/hash.sh qemu)"

clean:
	rm -rf build/app build/ipa-stage dist

distclean: clean
	rm -rf build src
