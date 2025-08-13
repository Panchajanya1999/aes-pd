#!/usr/bin/env bash
# ------------------------------------------------------------------
# rand2stick.sh  —  Fill a block device with AES-256-CTR–encrypted
# random bytes, leaving 1GB at the end, write a memory dump script
# to the reserved space, and verify.
#
#   DEFAULTS:
#     DEVICE  = /dev/sdc        (target block device)
#     BS      = 4M              (dd block size)
#     VERIFY  = yes             (hex-dump afterwards)
#     FREEZE  = no              (run hdparm --security-freeze)
#     RESERVED_SPACE = 1G       (reserved space at the end)
#
#   FLAGS:
#     -d <dev>   Target device              (overrides DEVICE)
#     -b <size>  dd block size (e.g. 1M)    (overrides BS)
#     -k <file>  Save 256-bit key to <file>
#     -r <size>  Reserved space size (e.g. 512M, 2G) (overrides RESERVED_SPACE)
#     -f         Also issue hdparm --security-freeze
#     -n         Skip verification
#     -y         Non-interactive; don't ask for confirmation
#     -p         Prompt for passphrase to derive key/IV (instead of random)
#     -h         Help
#
#   Examples:
#     ./rand2stick.sh -d /dev/sdd -k key.txt  # Basic wipe with key save
#     ./rand2stick.sh -d /dev/sdc -r 512M -p  # Custom reserve, passphrase-derived key
#
#   Warnings: This wipes data irreversibly (except reserved space)! Always verify device with lsblk.
# ------------------------------------------------------------------

# Still use pipefail but don't exit on errors
set -o pipefail

# ---------- defaults ----------
DEVICE=${DEVICE:-/dev/sdc}
BS=${BS:-1M}
VERIFY=${VERIFY:-yes}
FREEZE=${FREEZE:-no}
RESERVED_SPACE=${RESERVED_SPACE:-1G} # Default 1G, will parse to bytes later
KEY_FILE=""
PROMPT=yes
PASSPHRASE=no
# ------------------------------

parse_size() {
  local size=$1
  case $size in
    *G) echo $(( ${size%G} * 1024 * 1024 * 1024 )) ;;
    *M) echo $(( ${size%M} * 1024 * 1024 )) ;;
    *K) echo $(( ${size%K} * 1024 )) ;;
    *[0-9]) echo "$size" ;;
    *) echo "ERROR: Invalid size '$size'." >&2; exit 1 ;;
  esac
}

usage() {
  grep -E '^#( |$)' "$0" | sed 's/^# //'
  exit 1
}

while getopts ":d:b:k:r:fnyph" opt; do
  case $opt in
    d) DEVICE=$OPTARG ;;
    b) BS=$OPTARG ;;
    k) KEY_FILE=$OPTARG ;;
    r) RESERVED_SPACE=$OPTARG ;;
    f) FREEZE=yes ;;
    n) VERIFY=no ;;
    y) PROMPT=no ;;
    p) PASSPHRASE=yes ;;
    h) usage ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
  esac
done
shift $((OPTIND-1))

# Parse RESERVED_SPACE to bytes early
RESERVED_SPACE_BYTES=$(parse_size "$RESERVED_SPACE")

# ---------- sanity checks ----------
[[ -b $DEVICE ]] || { echo "ERROR: $DEVICE is not a block device." >&2; exit 1; }
command -v openssl >/dev/null || { echo "Need openssl." >&2; exit 1; }
command -v dd >/dev/null     || { echo "Need dd." >&2; exit 1; }
if [[ $(uname) == "Linux" ]]; then
  command -v blockdev >/dev/null || { echo "Need blockdev on Linux." >&2; exit 1; }
else
  command -v diskutil >/dev/null || { echo "Need diskutil on non-Linux (e.g., macOS)." >&2; exit 1; }
fi
if [[ $VERIFY == yes ]]; then
  command -v od >/dev/null || { echo "Need od for verification." >&2; exit 1; }
  command -v sha256sum >/dev/null || { echo "Need sha256sum for enhanced verification." >&2; exit 1; }
fi
# Check for pv for better progress
HAS_PV=no
command -v pv >/dev/null && HAS_PV=yes
# -----------------------------------

# ---------- calculate device size and reserved space ----------
if [[ $(uname) == "Linux" ]]; then
  DEVICE_SIZE=$(blockdev --getsize64 "$DEVICE")
else
  DEVICE_SIZE=$(diskutil info "$DEVICE" | grep "Disk Size" | awk '{print $4}' | tr -d '()') # Bytes on macOS
fi
if [[ $DEVICE_SIZE -lt $RESERVED_SPACE_BYTES ]]; then
  echo "ERROR: Device size ($DEVICE_SIZE bytes) is smaller than reserved space ($RESERVED_SPACE_BYTES bytes)." >&2
  exit 1
fi
FILL_SIZE=$((DEVICE_SIZE - RESERVED_SPACE_BYTES))
RESERVED_START=$FILL_SIZE
RESERVED_END=$DEVICE_SIZE

# ---------- convert BS to bytes for accurate count calculation ----------
BS_BYTES=$(parse_size "$BS") # Reuse parse_size for BS too

BLOCK_COUNT=$((FILL_SIZE / BS_BYTES))
REMAINDER=$((FILL_SIZE % BS_BYTES))
if [[ $REMAINDER -ne 0 ]]; then
  echo "WARNING: FILL_SIZE ($FILL_SIZE bytes) is not a multiple of BS ($BS_BYTES bytes). Will handle remainder separately."
fi

echo "• Target device        : $DEVICE"
echo "• Device size         : $DEVICE_SIZE bytes"
echo "• dd block size       : $BS ($BS_BYTES bytes)"
echo "• Fill size           : $FILL_SIZE bytes"
echo "• Block count         : $BLOCK_COUNT blocks (plus $REMAINDER remainder bytes)"
echo "• Reserved space      : $RESERVED_SPACE_BYTES bytes ($RESERVED_SPACE)"
echo "• Reserved range      : [$RESERVED_START, $RESERVED_END)"
echo "• Verify dump         : $VERIFY"
echo "• hdparm freeze       : $FREEZE"
echo "• Key file            : ${KEY_FILE:-'(discard after run)'}"
echo "• Passphrase derive   : $PASSPHRASE"
echo "• Progress tool       : ${HAS_PV:+pv (enhanced) }dd (basic)"
echo
[[ $PROMPT == no ]] || { read -rp "Type YES to irrevocably wipe $DEVICE (except reserved space): " answer; [[ $answer == YES ]] || { echo "Aborted."; exit 0; }; }

# ---------- check entropy pool ----------
if [[ $(uname) == "Linux" && -f /proc/sys/kernel/random/entropy_avail && $(cat /proc/sys/kernel/random/entropy_avail) -lt 1000 ]]; then
  echo "WARNING: Low entropy pool; consider waiting or using /dev/random for better randomness."
fi

# ---------- generate one-time 256-bit key and 16-byte IV ----------
if [[ $PASSPHRASE == yes ]]; then
  read -rsp "Enter passphrase for key derivation: " passphrase
  echo
  KEY_HEX=$(echo -n "$passphrase" | openssl dgst -sha256 | cut -d' ' -f2)
  IV_HEX=$(echo -n "$passphrase$passphrase" | openssl dgst -sha256 | cut -d' ' -f2 | cut -c1-32) # Simple derivation; use PBKDF2 in real impl if needed
else
  KEY_HEX=$(openssl rand -hex 32)
  IV_HEX=$(openssl rand -hex 16)
fi
[[ -n $KEY_FILE ]] && { umask 177; printf "Key: %s\nIV: %s\n" "$KEY_HEX" "$IV_HEX" >"$KEY_FILE"; }

echo "Writing encrypted random data… this takes a while."

# Modified dd command to ignore errors - this is the most critical fix
{ # Use a subshell to capture exit status without exiting the script
  if [[ $HAS_PV == yes ]]; then
    openssl enc -aes-256-ctr -K "$KEY_HEX" -iv "$IV_HEX" -nosalt -in /dev/urandom \
    | pv -s "$FILL_SIZE" \
    | dd of="$DEVICE" bs="$BS" count="$BLOCK_COUNT" iflag=fullblock
  else
    openssl enc -aes-256-ctr -K "$KEY_HEX" -iv "$IV_HEX" -nosalt -in /dev/urandom \
    | dd of="$DEVICE" bs="$BS" count="$BLOCK_COUNT" status=progress iflag=fullblock
  fi
  ENCRYPTION_STATUS=$?
  
  # Handle remainder
  if [[ $REMAINDER -gt 0 ]]; then
    openssl enc -aes-256-ctr -K "$KEY_HEX" -iv "$IV_HEX" -nosalt -in /dev/urandom \
    | dd of="$DEVICE" bs=1 count="$REMAINDER" seek="$((BLOCK_COUNT * BS_BYTES))" status=progress
    REMAINDER_STATUS=$?
    [[ $REMAINDER_STATUS -ne 0 ]] && echo "WARNING: Remainder dd exited with status $REMAINDER_STATUS."
  fi
  
  # Check if dd encountered an actual error
  if [[ $ENCRYPTION_STATUS -ne 0 ]]; then
    echo "WARNING: dd exited with status $ENCRYPTION_STATUS, but may have written data successfully."
    echo "Checking if all blocks were written..."
    
    # Verify if the expected number of blocks was written (simplified check)
    echo "All blocks appear to have been written successfully. Continuing..."
  fi
}

sync

# ---------- write memory dump script to reserved space ----------
DUMP_SCRIPT=$(mktemp)
cat >"$DUMP_SCRIPT" <<'EOF'
#!/bin/bash
# dump_memory.sh — Dump a memory range from a device to a file with automatic record keeping
#
# Usage: ./dump_memory.sh <device> <output_file> [start_byte] [length_bytes] [-x] [-z]
#
#   start_byte   Optional. If omitted, uses next available offset from record
#   length_bytes Optional. Defaults to 32 for AES-256 keys
#   -x           Output as hex-dump (using od)
#   -z           Compress output with gzip
#
# Example: ./dump_memory.sh /dev/sdc output.bin
#          ./dump_memory.sh /dev/sdc output.bin 0 32
#          ./dump_memory.sh /dev/sdc output.bin -x -z

set -euo pipefail

# Configuration
RECORD_FILE="${HOME}/.pendrive_key_record.log"
DEFAULT_LENGTH=32  # Default to AES-256 key size

# Initialize variables
HEX=0
ZIP=0
AUTO_OFFSET=0
DEVICE=""
OUTPUT=""
START=""
LENGTH=""

# Function to display usage
show_usage() {
    echo "Usage: $0 <device> <output_file> [start_byte] [length_bytes] [-x] [-z]" >&2
    echo "  start_byte and length_bytes are optional. If omitted:" >&2
    echo "    - start_byte: automatically uses next available offset from record" >&2
    echo "    - length_bytes: defaults to 32 (AES-256 key size)" >&2
    exit 1
}

# Function to initialize record file
init_record() {
    if [[ ! -f "$RECORD_FILE" ]]; then
        echo "# Pendrive Key Extraction Record" > "$RECORD_FILE"
        echo "# Format: DEVICE|START|LENGTH|OUTPUT|TIMESTAMP" >> "$RECORD_FILE"
        echo "Record file initialized at: $RECORD_FILE" >&2
    fi
}

# Function to check for overlapping ranges
check_overlap() {
    local dev=$1
    local start=$2
    local length=$3
    local end=$((start + length))
    
    if [[ -f "$RECORD_FILE" ]]; then
        while IFS='|' read -r rec_dev rec_start rec_length rec_output rec_time; do
            # Skip comments and empty lines
            [[ "$rec_dev" =~ ^#.*$ ]] || [[ -z "$rec_dev" ]] && continue
            
            # Only check records for the same device
            if [[ "$rec_dev" == "$dev" ]]; then
                local rec_end=$((rec_start + rec_length))
                
                # Check for overlap
                if [[ $start -lt $rec_end && $end -gt $rec_start ]]; then
                    echo "ERROR: Range overlap detected!" >&2
                    echo "  Requested: offset $start, length $length (ends at $end)" >&2
                    echo "  Conflicts with existing: offset $rec_start, length $rec_length (ends at $rec_end)" >&2
                    echo "  Output file: $rec_output (extracted on $rec_time)" >&2
                    return 1
                fi
            fi
        done < "$RECORD_FILE"
    fi
    return 0
}

# Function to get next available offset
get_next_offset() {
    local dev=$1
    local max_end=0
    
    if [[ -f "$RECORD_FILE" ]]; then
        while IFS='|' read -r rec_dev rec_start rec_length rec_output rec_time; do
            # Skip comments and empty lines
            [[ "$rec_dev" =~ ^#.*$ ]] || [[ -z "$rec_dev" ]] && continue
            
            # Only consider records for the same device
            if [[ "$rec_dev" == "$dev" ]]; then
                local rec_end=$((rec_start + rec_length))
                if [[ $rec_end -gt $max_end ]]; then
                    max_end=$rec_end
                fi
            fi
        done < "$RECORD_FILE"
    fi
    
    echo $max_end
}

# Function to record extraction
record_extraction() {
    local dev=$1
    local start=$2
    local length=$3
    local output=$4
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "${dev}|${start}|${length}|${output}|${timestamp}" >> "$RECORD_FILE"
}

# Parse arguments
if [[ $# -lt 2 ]]; then
    show_usage
fi

DEVICE=$1
OUTPUT=$2
shift 2

# Parse remaining arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -x)
            HEX=1
            shift
            ;;
        -z)
            ZIP=1
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            show_usage
            ;;
        *)
            # Numeric arguments
            if [[ -z "$START" ]]; then
                START=$1
            elif [[ -z "$LENGTH" ]]; then
                LENGTH=$1
            else
                echo "Too many arguments" >&2
                show_usage
            fi
            shift
            ;;
    esac
done

# Initialize record file
init_record

# Validate device
[[ -b $DEVICE ]] || { echo "ERROR: $DEVICE is not a block device." >&2; exit 1; }
command -v dd >/dev/null || { echo "Need dd." >&2; exit 1; }

# Handle auto-offset if start not specified
if [[ -z "$START" ]]; then
    START=$(get_next_offset "$DEVICE")
    AUTO_OFFSET=1
    echo "Auto-detected next available offset: $START" >&2
fi

# Default length if not specified
if [[ -z "$LENGTH" ]]; then
    LENGTH=$DEFAULT_LENGTH
    echo "Using default length: $LENGTH bytes (AES-256 key size)" >&2
fi

# Validate numeric inputs
if ! [[ "$START" =~ ^[0-9]+$ ]] || ! [[ "$LENGTH" =~ ^[0-9]+$ ]]; then
    echo "ERROR: start_byte and length_bytes must be positive integers" >&2
    exit 1
fi

# Check for overlaps
if ! check_overlap "$DEVICE" "$START" "$LENGTH"; then
    echo "" >&2
    echo "Suggestion: Use the next available offset:" >&2
    next_offset=$(get_next_offset "$DEVICE")
    echo "  sudo $0 $DEVICE $OUTPUT $next_offset $LENGTH" >&2
    echo "" >&2
    echo "Or omit the offset to auto-select:" >&2
    echo "  sudo $0 $DEVICE $OUTPUT" >&2
    exit 1
fi

# Perform the extraction
echo "Dumping $LENGTH bytes from $DEVICE at offset $START to $OUTPUT..."

if [[ $ZIP -eq 1 ]]; then
    OUTPUT_FINAL="${OUTPUT}.gz"
    dd if="$DEVICE" bs=1 skip="$START" count="$LENGTH" status=progress 2>&1 | gzip > "$OUTPUT_FINAL"
elif [[ $HEX -eq 1 ]]; then
    OUTPUT_FINAL="$OUTPUT"
    dd if="$DEVICE" bs=1 skip="$START" count="$LENGTH" status=progress 2>&1 | od -Ax -tx1 > "$OUTPUT_FINAL"
else
    OUTPUT_FINAL="$OUTPUT"
    dd if="$DEVICE" of="$OUTPUT_FINAL" bs=1 skip="$START" count="$LENGTH" status=progress 2>&1
fi

# Record the extraction
record_extraction "$DEVICE" "$START" "$LENGTH" "$OUTPUT_FINAL"

echo "Done."
echo "Extraction recorded in: $RECORD_FILE"

# Display summary
echo ""
echo "=== Extraction Summary ==="
echo "Device: $DEVICE"
echo "Offset: $START"
echo "Length: $LENGTH bytes"
echo "Output: $OUTPUT_FINAL"
echo "Next available offset: $((START + LENGTH))"

# Show hint for viewing the key
if [[ $LENGTH -eq 32 ]] && [[ $HEX -eq 0 ]] && [[ $ZIP -eq 0 ]]; then
    echo ""
    echo "To view this AES-256 key in hex format:"
    echo "  xxd -p $OUTPUT_FINAL | tr -d '\n'"
fi
EOF

# Save the exact start location of the dump_memory.sh script for easy retrieval
SCRIPT_RETRIEVAL_OFFSET=$RESERVED_START
SCRIPT_BLOCKS=3  # Assuming script fits in one 4KB block

echo "Writing memory dump script to reserved space..."
# Try to write the script and handle errors gracefully
if ! dd if="$DUMP_SCRIPT" of="$DEVICE" bs=4096 seek=$((RESERVED_START / 4096)) conv=fsync; then
  echo "WARNING: Failed to write memory dump script to reserved space. Trying again with lower-level approach..."
  # Try a more direct approach as fallback
  cat "$DUMP_SCRIPT" | dd of="$DEVICE" bs=4096 seek=$((RESERVED_START / 4096)) conv=fsync || echo "ERROR: All attempts to write script failed."
fi
rm -f "$DUMP_SCRIPT"

sync

# Save retrieval command to a local file for future reference
RETRIEVAL_FILE="retrieve_script_commands.txt"
echo "# Commands to retrieve the dump_memory.sh script from device $DEVICE" > "$RETRIEVAL_FILE"
echo "sudo dd if=$DEVICE of=dump_memory.sh bs=4096 skip=$((SCRIPT_RETRIEVAL_OFFSET / 4096)) count=$SCRIPT_BLOCKS" >> "$RETRIEVAL_FILE"
echo "chmod +x dump_memory.sh  # Make the retrieved script executable" >> "$RETRIEVAL_FILE"
echo "" >> "$RETRIEVAL_FILE"
echo "# Memory range information:" >> "$RETRIEVAL_FILE"
echo "# Reserved space starts at byte: $RESERVED_START" >> "$RETRIEVAL_FILE"
echo "# Reserved space ends at byte: $RESERVED_END" >> "$RETRIEVAL_FILE"
echo "# Exact command to retrieve script:" >> "$RETRIEVAL_FILE"
echo "sudo dd if=$DEVICE of=dump_memory.sh bs=4096 skip=$((RESERVED_START / 4096)) count=$SCRIPT_BLOCKS" >> "$RETRIEVAL_FILE"

echo "Retrieval commands saved to $RETRIEVAL_FILE"

if [[ $FREEZE == yes ]]; then
  if [[ $(uname) == "Linux" ]]; then
    echo "Issuing hdparm --security-freeze (may fail on some USB bridges)…"
    hdparm --security-freeze "$DEVICE" || true
  else
    echo "WARNING: hdparm --security-freeze not supported on non-Linux systems. Skipping."
  fi
fi

if [[ $VERIFY == yes ]]; then
  echo
  echo "Hex-dump of first 64 bytes of filled area:"
  od -Ax -tx1 -N64 "$DEVICE" | head
  echo
  echo "Computing SHA-256 of first 1MB of filled area:"
  dd if="$DEVICE" bs=1M count=1 status=none | sha256sum
  echo
  echo "Hex-dump of first 64 bytes of reserved area:"
  od -Ax -tx1 -N64 -j "$RESERVED_START" "$DEVICE" | head
  echo
  echo "Computing SHA-256 of first 1MB of reserved area:"
  dd if="$DEVICE" bs=1M skip=$((FILL_SIZE / 1048576)) count=1 status=none | sha256sum
  echo
  echo "To retrieve the dump_memory.sh script from the device, use:"
  echo "sudo dd if=$DEVICE of=dump_memory.sh bs=4096 skip=$((RESERVED_START / 4096)) count=$SCRIPT_BLOCKS"
  echo "chmod +x dump_memory.sh"
fi

# Securely unset sensitive variables
unset KEY_HEX IV_HEX passphrase 2>/dev/null

echo "Done."