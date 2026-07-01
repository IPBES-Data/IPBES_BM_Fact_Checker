# ----------------------------------------------------------------------------
# IPBES BM Fact Checker — operator interface.
#
# `make help` prints all targets.
# Override image versions on the command line:
#   make docker-nli-build   VERSION=v0.2.3
#   make docker-nli-push    VERSION=v0.2.3
# ----------------------------------------------------------------------------

# Image registry namespace. Override with REGISTRY=ghcr.io/<other-user> if you fork.
REGISTRY ?= ghcr.io/rkrug

# Default image version. Bump for each new build (see docker/nli-runpod/README.md).
VERSION  ?= v0.2.3

# Docker buildx platform — RunPod nodes are amd64 even from Apple Silicon.
PLATFORM ?= linux/amd64

# Model baked into the NLI image. Empty = use the Dockerfile default
# (deberta-v3-large-zeroshot-v2.0). Override to bake the faster base model:
#   make docker-nli VERSION=v0.2.3-base \
#     NLI_MODEL=MoritzLaurer/deberta-v3-base-zeroshot-v2.0
NLI_MODEL ?=

.PHONY: help \
        tar-make tar-visnetwork tar-outdated tar-invalidate tar-clean \
        docker-nli-build docker-nli-push docker-nli \
        mmd mmd-clean

# Mermaid CLI binary. Install via `npm i -g @mermaid-js/mermaid-cli` or
# `brew install mermaid-cli`. Override on the make line if needed.
MMDC      ?= mmdc

# Source diagrams + rendered outputs.
MMD_SRC   := $(wildcard input/mmd/*.mmd)
MMD_SVG   := $(MMD_SRC:input/mmd/%.mmd=output/figures/%.svg)
MMD_PNG   := $(MMD_SRC:input/mmd/%.mmd=output/figures/%.png)

help: ## Show this help message
	@echo "IPBES BM Fact Checker make targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  %-26s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables (override on the make command line):"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  VERSION=$(VERSION)"
	@echo "  PLATFORM=$(PLATFORM)"

# --- targets pipeline -------------------------------------------------------

tar-make: ## Run the targets pipeline
	Rscript -e "targets::tar_make()"

tar-visnetwork: ## Visualise the targets pipeline as a network
	Rscript -e "targets::tar_visnetwork()"

tar-outdated: ## List outdated targets
	Rscript -e "targets::tar_outdated()"

tar-invalidate: ## Invalidate all targets (force rebuild)
	Rscript -e "targets::tar_invalidate(everything())"

tar-clean: ## Remove all target outputs
	Rscript -e "targets::tar_destroy()"

# --- docker images ----------------------------------------------------------

docker-nli-build: ## Build the NLI RunPod image (NLI_MODEL=... to override the baked model)
	docker buildx build --platform $(PLATFORM) \
	    $(if $(NLI_MODEL),--build-arg NLI_MODEL=$(NLI_MODEL),) \
	    -t $(REGISTRY)/nli-runpod:$(VERSION) \
	    -f docker/nli-runpod/Dockerfile .

docker-nli-push: ## Push the NLI RunPod image to the registry
	docker push $(REGISTRY)/nli-runpod:$(VERSION)

docker-nli: docker-nli-build docker-nli-push ## Build + push the NLI RunPod image

# --- mermaid diagrams -------------------------------------------------------
# Renders every .mmd under input/mmd/ to SVG (vector) and PNG (raster) in
# output/figures/. SVG is the recommended embed format; PNG is a fallback.
#
# Requires the mermaid CLI (mmdc). On macOS: `brew install mermaid-cli`.

output/figures/%.svg: input/mmd/%.mmd
	@mkdir -p $(dir $@)
	$(MMDC) -i $< -o $@ -b transparent

output/figures/%.png: input/mmd/%.mmd
	@mkdir -p $(dir $@)
	$(MMDC) -i $< -o $@ -b white -s 2

mmd: $(MMD_SVG) $(MMD_PNG) ## Render all mermaid diagrams to SVG + PNG

mmd-clean: ## Remove all rendered mermaid output
	rm -f $(MMD_SVG) $(MMD_PNG)
