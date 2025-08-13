# Secure AES-256 Key Storage System

A cryptographically secure system for creating and managing one-time-use AES-256 encryption keys using a prepared USB pendrive as a hardware key store.

## Table of Contents
- [Overview](#overview)
- [System Components](#system-components)
- [Use Cases](#use-cases)
- [Advantages](#advantages)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Part 1: Preparing the Pendrive](#part-1-preparing-the-pendrive)
- [Part 2: Retrieving the Extraction Script](#part-2-retrieving-the-extraction-script)
- [Part 3: Extracting AES Keys](#part-3-extracting-aes-keys)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Technical Details](#technical-details)
- [FAQ](#faq)

## Overview

This system transforms a USB pendrive into a secure hardware token containing gigabytes of encrypted random data. Each 32-byte segment serves as a unique, one-time-use AES-256 encryption key. The system includes automatic tracking to prevent key reuse and ensures cryptographic security for sensitive applications.

## System Components

### 1. `rand2stick.sh`
- **Purpose**: Prepares the USB pendrive with encrypted random data
- **Function**: Fills the device with AES-256-CTR encrypted random bytes, leaving 1GB reserved space
- **Output**: A pendrive ready to serve as a key source + embedded extraction script

### 2. `dump_memory.sh` ( requires dumping first )
- **Purpose**: Extracts individual AES-256 keys from the prepared pendrive
- **Function**: Reads 32-byte chunks with automatic offset tracking and overlap prevention
- **Output**: Binary key files ready for cryptographic use

### 3. Record Keeping System
- **Location**: `~/.pendrive_key_record.log`
- **Purpose**: Prevents key reuse by tracking all extractions automatically
- **Function**: Maintains audit trail of device, offset, length, output file, and timestamp

## Use Cases

### Primary Applications
- **Secure File Encryption**: Each file gets a unique AES-256 key
- **Database Encryption**: Unique keys for different database segments
- **Secure Communication**: One-time keys for message encryption
- **Backup Encryption**: Unique keys for each backup archive
- **Cold Storage**: Offline key storage for cryptocurrency wallets
- **Air-Gapped Systems**: Physical key distribution without network exposure

### Ideal For Organizations That Need
- Hardware-based key management without expensive HSMs
- Audit trails for key usage
- Physical control over cryptographic material
- Compliance with data protection regulations
- Offline key storage and distribution

## Advantages

### Security Benefits
- **True Randomness**: Based on `/dev/urandom` with AES-256-CTR mixing
- **One-Time Use**: Automatic tracking prevents key reuse
- **Air-Gap Compatible**: No network required for key distribution
- **Hardware-Based**: Physical possession required for key access
- **Audit Trail**: Complete history of all key extractions

### Operational Benefits
- **Cost-Effective**: Uses standard USB pendrives instead of expensive HSMs
- **Portable**: Easy to transport and store securely
- **Large Capacity**: 32GB pendrive = ~900 million unique AES-256 keys
- **Simple**: No complex key management infrastructure needed
- **Offline**: Works on air-gapped systems

### Compliance Benefits
- **Traceable**: Every key extraction is logged
- **Non-Reusable**: Enforces one-time key policy automatically
- **Verifiable**: Can prove which keys were used when
- **Segregated**: Different pendrives for different security domains

## Requirements

### Software Requirements
- Linux OS (Ubuntu, Debian, RHEL, etc.)
- Bash shell (version 4.0+)
- Standard utilities: `dd`, `openssl`, `blockdev`
- Optional: `pv` for enhanced progress display
- For verification: `od`, `sha256sum`, `xxd`

### Hardware Requirements
- USB pendrive (recommended 32GB or larger)
- Root/sudo access for raw device operations
- Sufficient RAM for buffer operations (minimal)

## Quick Start

```bash
# 1. Prepare a pendrive (one-time setup)
sudo ./rand2stick.sh -d /dev/sdc

# 2. Retrieve the extraction script from pendrive
sudo dd if=/dev/sdc of=dump_memory.sh bs=4096 skip=$((OFFSET/4096)) count=3
chmod +x dump_memory.sh

# 3. Extract your first key (automatic mode)
sudo ./dump_memory.sh /dev/sdc my_first_key.bin

# 4. Extract subsequent keys (auto-increments)
sudo ./dump_memory.sh /dev/sdc my_second_key.bin
```

## Part 1: Preparing the Pendrive

### Step 1: Identify Your USB Device

```bash
# Insert USB pendrive, then identify it
lsblk
# OR
sudo fdisk -l

# Look for your pendrive (e.g., /dev/sdc)
# CRITICAL: Verify the correct device to avoid data loss!
```

### Step 2: Run rand2stick.sh

#### Basic Usage (Recommended)
```bash
sudo ./rand2stick.sh -d /dev/sdc
```

#### Advanced Options
```bash
# Save the master encryption key (optional)
sudo ./rand2stick.sh -d /dev/sdc -k master_key.txt

# Custom reserved space (default is 1GB)
sudo ./rand2stick.sh -d /dev/sdc -r 512M

# Skip confirmation prompt
sudo ./rand2stick.sh -d /dev/sdc -y

# Use passphrase-derived key instead of random
sudo ./rand2stick.sh -d /dev/sdc -p

# Custom block size for faster writing
sudo ./rand2stick.sh -d /dev/sdc -b 4M

# Enable hardware freeze (Linux only)
sudo ./rand2stick.sh -d /dev/sdc -f
```

### What Happens During Preparation

1. **Calculates Space**: Determines fillable space (total - reserved)
2. **Generates Keys**: Creates one-time AES-256 key and IV
3. **Encrypts & Writes**: Fills device with encrypted random data
4. **Embeds Script**: Writes `dump_memory.sh` to reserved space
5. **Creates Retrieval Info**: Saves commands to `retrieve_script_commands.txt`
6. **Verifies**: Optionally dumps samples and checksums

### Expected Output
```
• Target device        : /dev/sdc
• Device size         : 31004295168 bytes
• Fill size           : 29930553344 bytes
• Reserved space      : 1073741824 bytes (1G)
• Reserved range      : [29930553344, 31004295168)

Writing encrypted random data… this takes a while.
[Progress bar or percentage]

Writing memory dump script to reserved space...
Retrieval commands saved to retrieve_script_commands.txt
Done.
```

### Time Estimates
- 8GB pendrive: ~5-10 minutes
- 32GB pendrive: ~20-40 minutes  
- 128GB pendrive: ~1-2 hours

## Part 2: Retrieving the Extraction Script

The `dump_memory.sh` script is embedded in the pendrive's reserved space. You need to extract it before using it.

### Method 1: Using Saved Commands

After running `rand2stick.sh`, check `retrieve_script_commands.txt`:

```bash
cat retrieve_script_commands.txt
# Contains the exact dd command with calculated offset
```

### Method 2: Manual Calculation

If you know the reserved space starts at byte X:

```bash
# Calculate block offset (X / 4096)
# Example: If reserved starts at 29930553344
# Block offset = 29930553344 / 4096 = 7308723

sudo dd if=/dev/sdc of=dump_memory.sh bs=4096 skip=7308723 count=3
chmod +x dump_memory.sh
```

### Method 3: From the Verification Output

`rand2stick.sh` displays the retrieval command at the end:

```bash
# Look for this line in the output:
# "To retrieve the dump_memory.sh script from the device, use:"
# Copy and run the command shown
```

### Verify Script Integrity

```bash
# Check if script is complete (should end with 'fi')
tail -20 dump_memory.sh

# Optional: Clean up any trailing garbage
head -n 223 dump_memory.sh > dump_clean.sh
mv dump_clean.sh dump_memory.sh
chmod +x dump_memory.sh
```

## Part 3: Extracting AES Keys

### Automatic Mode (Recommended)

The script automatically tracks and prevents key reuse:

```bash
# First key - automatically uses offset 0
sudo ./dump_memory.sh /dev/sdc key1.bin

# Second key - automatically uses offset 32
sudo ./dump_memory.sh /dev/sdc key2.bin

# Third key - automatically uses offset 64
sudo ./dump_memory.sh /dev/sdc key3.bin
```

### Manual Mode

Specify exact offset and length:

```bash
# Extract 32 bytes from offset 128
sudo ./dump_memory.sh /dev/sdc mykey.bin 128 32

# Extract 64 bytes from offset 1024
sudo ./dump_memory.sh /dev/sdc longkey.bin 1024 64
```

### Additional Options

```bash
# Output as hex dump
sudo ./dump_memory.sh /dev/sdc key.hex 0 32 -x

# Compress output
sudo ./dump_memory.sh /dev/sdc key.bin.gz 0 32 -z

# Combine options
sudo ./dump_memory.sh /dev/sdc key.hex.gz -x -z
```

### Viewing Extracted Keys

```bash
# View as hex string (for AES-256 keys)
xxd -p key.bin | tr -d '\n'

# View as formatted hex dump
xxd key.bin

# Check key size
ls -l key.bin  # Should be 32 bytes for AES-256

# View SHA-256 hash of key
sha256sum key.bin
```

### Checking Extraction History

```bash
# View all extractions
cat ~/.pendrive_key_record.log

# Count total keys extracted
grep -c "^/dev/" ~/.pendrive_key_record.log

# Find last used offset
tail -1 ~/.pendrive_key_record.log
```

### Example Session

```bash
# Day 1: Encrypt important database
sudo ./dump_memory.sh /dev/sdc db_key.bin
openssl enc -aes-256-cbc -in database.sql -out database.sql.enc -pass file:db_key.bin

# Day 2: Encrypt backup
sudo ./dump_memory.sh /dev/sdc backup_key.bin
tar czf - /important/data | openssl enc -aes-256-cbc -out backup.tar.gz.enc -pass file:backup_key.bin

# Day 3: Check what's been used
cat ~/.pendrive_key_record.log
# /dev/sdc|0|32|db_key.bin|2025-01-28 10:15:23
# /dev/sdc|32|32|backup_key.bin|2025-01-29 11:30:45
```

## Security Considerations

### Physical Security
- **Store pendrives in a safe or secure location**
- **Consider using multiple pendrives for different security levels**
- **Never leave pendrives unattended in untrusted environments**
- **Use tamper-evident seals if necessary**

### Operational Security
- **Never reuse keys** - The system prevents this automatically
- **Delete key files after use** if they're no longer needed
- **Don't store keys on network-accessible systems**
- **Use different pendrives for different projects/clients**

### Key Hygiene
- **Wipe key files securely** after use: `shred -vfz keyfile.bin`
- **Don't copy keys to multiple locations**
- **Never transmit keys over insecure channels**
- **Maintain the audit log** (`~/.pendrive_key_record.log`)

### Backup Considerations
- **The pendrive IS your key backup** - Keep it safe
- **Consider creating duplicate pendrives** for critical applications
- **Store pendrives in different physical locations**
- **Document which pendrive is used for what purpose**

## Troubleshooting

### Common Issues and Solutions

#### "Device not found" or "Not a block device"
```bash
# Verify device is connected
lsblk
# Check device path is correct (e.g., /dev/sdc not /dev/sdc1)
# Ensure you have sudo privileges
```

#### "Range overlap detected"
```bash
# You're trying to reuse a key offset
# Solution 1: Let the script auto-select
sudo ./dump_memory.sh /dev/sdc newkey.bin

# Solution 2: Check what's been used
cat ~/.pendrive_key_record.log
```

#### Retrieved script has garbage at the end
```bash
# This is normal - random data after the script
# Clean it up if desired:
head -n 223 dump_memory.sh > clean.sh
mv clean.sh dump_memory.sh
chmod +x dump_memory.sh
```

#### "Permission denied"
```bash
# Always use sudo for device operations
sudo ./dump_memory.sh /dev/sdc key.bin

# Make scripts executable
chmod +x rand2stick.sh dump_memory.sh
```

#### Slow write speeds
```bash
# Use larger block size
sudo ./rand2stick.sh -d /dev/sdc -b 4M

# Install pv for better progress
sudo apt-get install pv
```

## Technical Details

### Encryption Method
- **Algorithm**: AES-256-CTR (Counter mode)
- **Key Source**: `/dev/urandom` 
- **Key Size**: 256 bits (32 bytes)
- **IV Size**: 128 bits (16 bytes)
- **Implementation**: OpenSSL

### Storage Layout
```
[Device Start]
|---------------------|-----------------|
| Encrypted Random    | Reserved Space  |
| Data               | (dump_memory.sh) |
|---------------------|-----------------|
0                    N-1GB              N
```

### Record File Format
```
# ~/.pendrive_key_record.log
DEVICE|START|LENGTH|OUTPUT|TIMESTAMP
/dev/sdc|0|32|key1.bin|2025-01-28 10:15:23
/dev/sdc|32|32|key2.bin|2025-01-28 10:20:15
```

### Capacity Calculations
- **32GB pendrive**: ~30GB usable = ~1 billion 32-byte keys
- **128GB pendrive**: ~126GB usable = ~4 billion 32-byte keys
- **1TB pendrive**: ~1022GB usable = ~32 billion 32-byte keys

## FAQ

### Q: Can I use this on Windows?
A: The scripts are bash-based and require Linux. Use WSL2 on Windows or a Linux VM.

### Q: What happens if I lose the pendrive?
A: Any unused keys are lost. Used keys remain in whatever systems you've deployed them to. This is why backup pendrives are recommended for critical applications.

### Q: Can I extract keys larger than 32 bytes?
A: Yes, specify the length: `sudo ./dump_memory.sh /dev/sdc key.bin 0 64` for a 64-byte key.

### Q: Is the master key needed after preparation?
A: No, the master key is only used during pendrive preparation. You can safely discard it.

### Q: Can I use the same pendrive on multiple computers?
A: Yes, but each computer will maintain its own extraction record. Consider centralizing the record file if sharing.

### Q: How random is the data?
A: It uses `/dev/urandom` which is cryptographically secure on modern Linux systems, further mixed with AES-256-CTR.

### Q: Can I verify a key hasn't been tampered with?
A: Yes, extract it again and compare SHA-256 hashes. The data on the pendrive is read-only after preparation.

### Q: What's the performance impact of the overlap checking?
A: Minimal. The script reads a text file that grows by one line per extraction.

### Q: Can I reset and start over?
A: Run `rand2stick.sh` again to completely rebuild the pendrive with new random data. Back up and delete `~/.pendrive_key_record.log` to reset the extraction record.

### Q: Is this FIPS compliant?
A: The randomness source (`/dev/urandom`) and AES-256 are FIPS-approved algorithms, but the overall system hasn't been formally FIPS validated.

## Support and Contributions

For issues, questions, or contributions, please refer to the original source or contact the system administrator who provided these tools.

---

**Security Notice**: This system provides strong cryptographic key generation and management. However, security depends on proper usage, physical security of the pendrive, and following operational security guidelines. Always assess whether this solution meets your specific security requirements and compliance needs.
