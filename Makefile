# ----------------------------------------------------------------------------
# IPBES BM Fact Checker — operator interface.
#
# `make help` prints all targets.
#
# The docker-nli* targets are GONE (2026-10-09). They forwarded to the
# external/runpod submodule, which was removed with the NLI backend it served;
# its final state is on that repo's `untested_fact_checker` branch. Image build
# variables (REGISTRY, VERSION, PLATFORM, NLI_MODEL) went with them — nothing
# here builds an image any more.
# ----------------------------------------------------------------------------

.PHONY: help \
        tar-make tar-visnetwork tar-outdated tar-invalidate tar-clean \
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
