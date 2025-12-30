#!/bin/bash

# Video Batch Converter - Fixed Version (No Hanging)
# Usage: ./convert_videos.sh /path/to/input /path/to/output [cpu_percentage] [hw_accel]

# Check if ffmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is not installed. Install with: brew install ffmpeg"
    exit 1
fi

# Check if exiftool is installed
if ! command -v exiftool &> /dev/null; then
    echo "Warning: exiftool not found. Install with: brew install exiftool"
    USE_EXIFTOOL=false
else
    USE_EXIFTOOL=true
fi

# Check arguments
if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    echo "Usage: $0 <input_folder> <output_folder> [cpu_percentage] [hw_accel]"
    echo "Example: $0 ~/Videos/Original ~/Videos/Compressed 75 no"
    echo ""
    echo "cpu_percentage options:"
    echo "  25  = Use 25% of CPU cores"
    echo "  50  = Use 50% of CPU cores"
    echo "  75  = Use 75% of CPU cores"
    echo "  100 = Use 100% of CPU cores (default)"
    echo ""
    echo "hw_accel options:"
    echo "  yes = Use hardware acceleration (VideoToolbox - FASTER)"
    echo "  no  = Use software encoding (better quality control) (default)"
    exit 1
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"
CPU_PERCENT="${3:-100}"
HW_ACCEL="${4:-no}"

# Validate CPU percentage
if [[ ! "$CPU_PERCENT" =~ ^(25|50|75|100)$ ]]; then
    echo "Error: cpu_percentage must be 25, 50, 75, or 100"
    exit 1
fi

# Validate hw_accel
if [[ ! "$HW_ACCEL" =~ ^(yes|no)$ ]]; then
    echo "Error: hw_accel must be 'yes' or 'no'"
    exit 1
fi

# Validate input directory
if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Input directory does not exist: $INPUT_DIR"
    exit 1
fi

# Create output directory and log directory
mkdir -p "$OUTPUT_DIR"
LOG_DIR="$OUTPUT_DIR/.logs"
mkdir -p "$LOG_DIR"

# Detect total CPU cores
TOTAL_CORES=$(sysctl -n hw.ncpu)

# Calculate threads based on percentage
case $CPU_PERCENT in
    25)
        THREADS=$(( TOTAL_CORES / 4 ))
        ;;
    50)
        THREADS=$(( TOTAL_CORES / 2 ))
        ;;
    75)
        THREADS=$(( TOTAL_CORES * 3 / 4 ))
        ;;
    100)
        THREADS=$TOTAL_CORES
        ;;
esac

# Ensure at least 1 thread
if [ $THREADS -lt 1 ]; then
    THREADS=1
fi

# For x265, pool threads
POOLS=$(( THREADS / 2 ))
if [ $POOLS -lt 1 ]; then
    POOLS=1
fi

# Supported video extensions
EXTENSIONS=("mp4" "mov" "avi" "mkv" "m4v" "MP4" "MOV" "AVI" "MKV" "M4V")

# Counter for progress
total_files=0
processed_files=0

# Count total files
for ext in "${EXTENSIONS[@]}"; do
    total_files=$((total_files + $(find "$INPUT_DIR" -maxdepth 1 -type f -name "*.$ext" | wc -l)))
done

echo "=========================================="
echo "Video Batch Converter"
echo "=========================================="
echo "Input folder:     $INPUT_DIR"
echo "Output folder:    $OUTPUT_DIR"
echo "Total videos:     $total_files"
echo "CPU cores:        $TOTAL_CORES total"
echo "Using:            $THREADS threads + $POOLS pools = $CPU_PERCENT% CPU"
echo "Encoding method:  $([ "$HW_ACCEL" = "yes" ] && echo "Hardware (VideoToolbox)" || echo "Software (x265)")"
echo "=========================================="
echo ""

# Process each video file
for ext in "${EXTENSIONS[@]}"; do
    find "$INPUT_DIR" -maxdepth 1 -type f -name "*.$ext" -print0 | while IFS= read -r -d '' file; do
        processed_files=$((processed_files + 1))
        filename=$(basename "$file")
        output_file="$OUTPUT_DIR/${filename%.*}.mp4"
        log_file="$LOG_DIR/${filename%.*}.log"
        
        echo "[$processed_files/$total_files] Processing: $filename"
        
        # Skip if output already exists
        if [ -f "$output_file" ]; then
            echo "  → Skipping (already exists)"
            echo ""
            continue
        fi
        
        # Record start time
        start_time=$(date +%s)
        
        # Show progress indicator
        echo "  → Encoding... (check Activity Monitor for CPU usage, or tail -f $log_file for details)"
        
        # Build FFmpeg command based on hardware acceleration choice
        if [ "$HW_ACCEL" = "yes" ]; then
            # Hardware acceleration using VideoToolbox (H.265)
            ffmpeg -nostdin -i "$file" \
                -c:v hevc_videotoolbox \
                -b:v 5M \
                -vf "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease,fps=30" \
                -c:a aac \
                -b:a 128k \
                -ac 2 \
                -map_metadata 0 \
                -movflags +faststart \
                -tag:v hvc1 \
                -y \
                "$output_file" > "$log_file" 2>&1
        else
            # Software encoding with proper x265 threading
            ffmpeg -nostdin -i "$file" \
                -c:v libx265 \
                -preset fast \
                -crf 23 \
                -x265-params "pools=$POOLS:threads=$THREADS" \
                -vf "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease,fps=30" \
                -c:a aac \
                -b:a 128k \
                -ac 2 \
                -map_metadata 0 \
                -movflags +faststart \
                -y \
                "$output_file" > "$log_file" 2>&1
        fi
        
        # Capture exit code
        ffmpeg_exit=$?
        
        # Check if conversion was successful
        if [ $ffmpeg_exit -eq 0 ] && [ -f "$output_file" ]; then
            # Calculate processing time
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            minutes=$((duration / 60))
            seconds=$((duration % 60))
            
            echo "  ✓ Conversion successful (${minutes}m ${seconds}s)"
            
            # Preserve metadata using exiftool (if available)
            if [ "$USE_EXIFTOOL" = true ]; then
                exiftool -TagsFromFile "$file" \
                    "-all:all>all:all" \
                    -overwrite_original \
                    "$output_file" &> /dev/null
                echo "  ✓ Metadata copied"
            fi

            # Preserve timestamps using touch
            touch -r "$file" "$output_file"
            echo "  ✓ Timestamps preserved"
            
            # Show file size comparison
            original_size=$(du -h "$file" | cut -f1)
            new_size=$(du -h "$output_file" | cut -f1)
            original_bytes=$(stat -f%z "$file")
            new_bytes=$(stat -f%z "$output_file")
            
            if [ $original_bytes -gt 0 ]; then
                reduction=$(echo "scale=1; (1 - $new_bytes / $original_bytes) * 100" | bc)
                echo "  ✓ Size: $original_size → $new_size (${reduction}% reduction)"
            else
                echo "  ✓ Size: $original_size → $new_size"
            fi
            
            # Remove log file on success
            rm -f "$log_file"
        else
            echo "  ✗ ERROR: Conversion failed (exit code: $ffmpeg_exit)"
            echo "  ✗ Check log: $log_file"
            echo ""
            echo "--- Last 20 lines of error log ---"
            tail -20 "$log_file"
            echo "-----------------------------------"
        fi
        
        echo ""
    done
done

echo "=========================================="
echo "Conversion complete!"
echo "Logs saved to: $LOG_DIR"
echo "=========================================="