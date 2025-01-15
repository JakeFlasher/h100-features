#!/usr/bin/env bash
# -----------------------------------------------------------------
# Script: profiling.sh
# Description: Collects Nsight Compute metrics from *.ncu-rep files.
#              Adds a manual flag for (--server or --pc):
#                --pc     : Use system 'ncu' from $PATH as-is.
#                --server : Prompt for ncu path, run commands with sudo.
# Author: [Your Name]
# Date: [Date]
# -----------------------------------------------------------------

# ---------------- Colorful output functions ----------------
function echo_info {
    echo -e "\e[34m[INFO]\e[0m $1"
}

function echo_success {
    echo -e "\e[32m[SUCCESS]\e[0m $1"
}

function echo_error {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# -------------- Parse arguments --------------
MODE="pc"
NCU_CMD="ncu"  # default if pc
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --server)
            MODE="server"
            shift
            ;;
        --pc)
            MODE="pc"
            shift
            ;;
        *)
            # If there's an extra parameter, treat it as a path to ncu
            NCU_CMD="$1"
            shift
            ;;
    esac
done

# -------------------------------------------------------------------
# Create subdirectories
# ------------------------------------------------------------------- 

# Detect GPU name again

gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 | xargs)"
GPUNAME=${gpu// /_}
if [ -z "$GPUNAME" ]; then
    GPUNAME="UnknownGPU"
    echo_error "Could not detect GPU name. Using 'UnknownGPU'."
fi 


# If mode is server, ask for ncu path if not already set
if [ "$MODE" == "server" ]; then
    if [ "$NCU_CMD" == "ncu" ]; then
        echo_info "Please input the full path to Nsight Compute (ncu) executable:"
        read -r NCU_CMD
    fi
    echo_info "Using sudo to run '$NCU_CMD'"
fi

# -------------- Decide how to run ncu commands --------------
function run_ncu {
    local in_file="$1"
    local metric="$2"
    local extra_flags="$3"

    if [ "$MODE" == "server" ]; then
        sudo "$NCU_CMD" -i "$in_file" --page raw --metrics "$metric" --csv $extra_flags
    else
        "$NCU_CMD" -i "$in_file" --page raw --metrics "$metric" --csv $extra_flags
    fi
}

# -------------- Define the list of metrics --------------
metrics=(
    "gpu__time_duration.sum"
    "dram__bytes_read.sum"
    "dram__bytes_write.sum"
    "lts__t_sectors_srcunit_tex_op_read.sum"
    "lts__t_sectors_srcunit_tex_op_write.sum"
    "lts__t_sector_hit_rate.pct"
    "sm__pipe_tensor_op_hmma_cycles_active.avg.pct_of_peak_sustained_active"
    "smsp__inst_executed.sum"
)

# -------------- Iterate over each .ncu-rep file --------------
shopt -s nullglob
REP_FILES=( $GPUNAME/ncu_reports/*/*.ncu-rep )

if [ ${#REP_FILES[@]} -eq 0 ]; then
    echo_error "No .ncu-rep files found in the current directory."
    exit 0
fi

for repfile in "${REP_FILES[@]}"; do

    csvfile="${repfile%.ncu-rep}_metrics.csv"
    # Remove the CSV file if it already exists
    if [ -f "$csvfile" ]; then
        rm -f "$csvfile"
    fi

    # Write a single header row to the CSV file
    echo "Kernel Name,Block Size,Grid Size,metric,Value" >> "$csvfile"

    # For each metric, collect data and parse/append to the CSV
    for metric in "${metrics[@]}"; do
        # Run Nsight Compute in CSV mode and store its output
        out="$(run_ncu "$repfile" "$metric")"

        # Parse the CSV data. We skip:
        #   - line 1 (the CSV header)
        #   - line 2 (the CSV units)
        # Then for each subsequent line, we extract columns:
        #   $5  -> Kernel Name
        #   $8  -> Block Size
        #   $9  -> Grid Size
        #   $NF -> The last column's value (the metric value for this row).
        # We place "metric" (the metric’s name) into a new column.
        awk -v metricName="$metric" '
            BEGIN {
                FS="\",\""
                OFS=","
            }
            NR==1 { next }  # Skip the header line
            NR==2 { next }  # Skip the units line
            {
                sub(/^"/,"",$5);  sub(/"$/,"",$5)
                sub(/^"/,"",$8);  sub(/"$/,"",$8)
                sub(/^"/,"",$9);  sub(/"$/,"",$9)
                sub(/^"/,"",$NF); sub(/"$/,"",$NF)

                kernelName=$5
                blockSize=$8
                gridSize=$9
                value=$NF

                print kernelName, blockSize, gridSize, metricName, value
            }
        ' <<< "$out" >> "$csvfile"
    done

    echo_success "Metrics for $repfile appended to $csvfile."
done

echo_success "All metric CSV files have been generated successfully."

