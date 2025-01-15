################################################################################
# Example Makefile for the "h100-features" project, where we compile all .cu
# files in dense/, examples/, and sparse/ subdirectories, run Nsight Compute 
# profiling, and then call profile.sh to produce CSV metrics. 
################################################################################

# --------------------- Basic Paths / Flags ---------------------
sm_version       = 90a   # Adjust to your GPU's SM version as needed (e.g. 90a for H100).
NVCC             = /usr/local/cuda-12.6/bin/nvcc
INCLUDES         = -I./headers/device/ -I./headers/host/
OPTIMIZATION     = -O3
LINKS            = -lcudart -lcuda
BIN_DIR          = bin

# Detect GPU name for reporting folder.
GPUNAME   = $(shell nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 | sed 's/ /_/g')
REPORTS_DIR = $(GPUNAME)/ncu_reports

# Nsight Compute path; if you do not need sudo, remove it.
NCU_PATH    := $(shell which ncu)
NCU_COMMAND = sudo $(NCU_PATH) --set full --import-source yes

# Compilation rule:
define COMPILE_TEMPLATE
$(NVCC) -arch=sm_$(sm_version) $(OPTIMIZATION) $(INCLUDES) $(LINKS) -o $@ $<
endef

# We create a list of all .cu files in these subdirectories:
DENSE_SOURCES   := $(wildcard dense/*.cu)
# EXAMPLES_SOURCES:= $(wildcard examples/*.cu)
SPARSE_SOURCES  := $(wildcard sparse/*.cu)
ALL_SOURCES     := $(DENSE_SOURCES) $(SPARSE_SOURCES)

# Convert each .cu file into an executable name by substituting .cu → no extension
# and prefixing bin/ as the final location.
ALL_EXECUTABLES := $(patsubst %.cu,$(BIN_DIR)/%,$(ALL_SOURCES))

# ------------------- Primary Rules -------------------

# "all" compiles, profiles, and optionally runs the analysis script 
all: compile_all profile_all analyze

# 1) compile_all: just compiles all source files
compile_all: $(ALL_EXECUTABLES)
	@echo "All CUDA files compiled successfully."

# Build rule for each .cu → bin/file
$(BIN_DIR)/%: %.cu
	mkdir -p $(BIN_DIR)
	$(COMPILE_TEMPLATE)

# 2) profile_all: runs Nsight Compute profiling on each built executable
profile_all: $(patsubst $(BIN_DIR)/%,$(REPORTS_DIR)/%.ncu-rep,$(ALL_EXECUTABLES))
	@echo "All Nsight Compute reports generated in $(REPORTS_DIR)."

# Build the .ncu-rep from each executable
$(REPORTS_DIR)/%.ncu-rep: $(BIN_DIR)/%
	mkdir -p $(REPORTS_DIR)
	$(NCU_COMMAND) -o $@ -f $<

# 3) analyze: uses profile.sh to parse .ncu-rep files into CSVs
analyze:
	@echo "Running profile.sh to analyze Nsight Compute reports..."
	@bash profile.sh

# If you want the old "run" target:
run:
	@echo "Example run of a single binary, e.g.: ./bin/dense/1_m64_n8_k32"

# 4) clean: remove binaries and .ncu-rep files
clean:
	rm -f $(BIN_DIR)/*
	rm -rf $(GPUNAME)
	@echo "Cleaned all binaries and profiling data."
