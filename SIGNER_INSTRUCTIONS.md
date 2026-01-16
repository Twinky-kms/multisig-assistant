# Multisig Transaction Signing Instructions

This document provides complete instructions for signers who need to sign a batch of multisig transactions.

## What You'll Receive

You will receive a directory containing:

- `chunks/` - Directory with transaction files (`.json` format)
- `pigeon-cli` and `pigeond` binaries
- `mass_sign.sh` - Automated signing script
- This instructions file

**Important**: You do NOT need to download or sync the blockchain. All necessary transaction data is embedded in the chunk files.

---

## Step 1: Verify Pigeon Binaries

**⚠️ SECURITY CRITICAL**: Always verify the integrity of the Pigeon binaries before using them.

### Download Official Checksums

Official checksums are available at:
- **Release page**: https://github.com/Pigeoncoin/pigeoncoin/releases/tag/v1.19.2.0
- **Direct archive**: https://github.com/Pigeoncoin/pigeoncoin/releases/download/v1.19.2.0/pigeon-ubuntu20-1.19.2.0.tar.gz

Download the official archive and extract it to get the checksums file.

### Verify Checksums

```bash
# Navigate to the binaries directory
cd /path/to/signing/files
 
# Install dependencies
sudo apt-get install jq zip

# Calculate SHA256 checksums
sha256sum pigeond pigeon-cli

# Compare with official checksums from the release archive
```

**If checksums don't match, STOP and contact me immediately.**

---

## Step 2: Make Scripts Executable

```bash
# From the main directory
chmod +x mass_sign.sh
```

---

## Step 3: Run Mass Signing

**Sign all transactions with a single command:**

```bash
./mass_sign.sh YOUR_PRIVATE_KEY_HERE
```

Replace `YOUR_PRIVATE_KEY_HERE` with your actual multisig private key.

### What Happens

The script will:
1. Start the pigeon daemon if not running
2. Process each chunk file from `chunks/`
3. Sign each transaction with your private key
4. Save results to `signed/` directory
5. Display a summary

### Expected Output

```
Checking if pigeon daemon is running...
Daemon is already running.

Starting mass signing...
Chunks directory: chunks (self-contained with transaction hex)
Output directory: signed

...

==========================================
Summary:
  Processed: 408
  Signed: 408
  Skipped: 16
  Errors: 0

Signed transactions saved to: signed/
```

### Understanding Results

- **"Signed and complete"**: Transaction has enough signatures (rare on first sign)
- **"Partial signature"**: Needs more signatures - **THIS IS NORMAL** for multisig
- **"SKIP"**: Transaction skipped (zero amount or old format)
- **"ERROR"**: Something went wrong with that transaction

---

## Step 4: Clear Your Command History

**CRITICAL SECURITY STEP**: Your private key is now in your shell history.

```bash
# Clear your shell history
history -c

# On some systems, also clear the history file
cat /dev/null > ~/.bash_history

# Or simply close the terminal window
```

---

## Step 5: Return Results to Coordinator

After signing, send the `signed/` directory back to the coordinator.

### Create Archive

```bash
# Create a ZIP file with all signed transactions
zip -r signed_by_YOUR_NAME.zip signed/

# Send signed_by_YOUR_NAME.zip to the coordinator
```

### What to Send

The `signed/` directory contains:
- `tx_000000_signed.hex` - Signed transaction hex (main output)
- `tx_000000_result.json` - Signing metadata

Both are useful, so send the entire `signed/` directory.

### Secure Delivery

- **DO NOT** include your private key (obviously!)

---

## Troubleshooting

### "ERROR: Private key required"

You didn't provide a private key. Run:

```bash
./mass_sign.sh YOUR_PRIVATE_KEY
```

### "pigeon-cli not found" or "pigeond not found"

### "Daemon failed to start"

Another pigeon daemon might be running:

```bash
# Check for running pigeond
ps aux | grep pigeond

# Kill existing daemon
pkill pigeond

# Try again
./mass_sign.sh YOUR_PRIVATE_KEY
```

### "ERROR: Failed to sign tx_NNNNNN"

Could indicate:
- Invalid private key
- Corrupted chunk file
- Daemon issue

Try:
```bash
# Stop daemon
pkill pigeond

# Remove data directory
rm -rf ~/.pigeoncoin

# Try again
./mass_sign.sh YOUR_PRIVATE_KEY
```

If specific transactions keep failing, note the transaction IDs and contact the coordinator.

### Script Hangs or Stalls

```bash
# Cancel with Ctrl+C
# Check if daemon is responsive
./pigeon-cli getinfo

# If unresponsive, kill and restart
pkill pigeond
./mass_sign.sh YOUR_PRIVATE_KEY
```

### Many "SKIP" Messages

Transactions showing "SKIP: (amount: 0E-8)" are chunks with UTXOs too small to cover fees. This is normal - they're automatically skipped.

---

## Security Best Practices

### Private Key Safety

- **ALWAYS** clear shell history after use: `history -c`

### After Signing Checklist

```bash
# 1. Clear history
history -c

# 2. Optionally clear history file
cat /dev/null > ~/.bash_history

# 3. Stop the daemon (optional)
pkill pigeond
```

### Verifying What You're Signing

If you want to inspect transactions before signing:

```bash
# View a chunk file
cat chunks/chunk_000.json | jq .

# Check amounts
cat chunks/chunk_000.json | jq -r '.transaction | {total_in, total_out, fee}'

# View multiple chunks
for f in chunks/chunk_*.json; do 
  echo "=== $f ==="
  jq -r '.transaction | {total_in, total_out, fee}' "$f"
done | head -20
```

---

## FAQ

**Q: Do I need to download the blockchain?**  
A: No! All transaction data is in the chunk files.

**Q: How long does signing take?**  
A: Usually 1-5 minutes for hundreds of transactions.

**Q: What if I make a mistake?**  
A: You can re-run the script. It will overwrite previous results.

**Q: Why do I see "partial signature"?**  
A: Multisig requires multiple signatures. Your signature is the first of several needed. This is correct and expected.

**Q: Should I broadcast these transactions?**  
A: **NO**. Send them to the coordinator who will combine signatures and broadcast.

**Q: What if some transactions error?**  
A: Note which ones failed and tell the coordinator. A few errors out of hundreds is usually fine.

**Q: How do I know signing worked?**  
A: Check the summary at the end. If "Signed: N" matches "Processed: N" with "Errors: 0", you're good.

---

## System Requirements

- **Linux** (Ubuntu 20.04+, Debian, or similar) - recommended
- **Git Bash** or **WSL** if using Windows
- ~100-500 MB free disk space
- Basic command-line knowledge

---

## Complete Example Session

Here's what a complete signing session looks like:

```bash
# 1. Navigate to the directory
cd /path/to/signing/files

# 2. Verify checksums (compare with official release)
sha256sum pigeon-cli pigeond

# 3. Install dependencies
sudo apt-get install jq zip

# 4. Run signing
chmod +x mass_sign.sh
./mass_sign.sh YOUR_PRIVATE_KEY

# Wait for completion...

# 5. Clear history immediately
history -c

# 6. Create archive of results
zip -r signed_by_MyName.zip signed/

# 7. Send signed_by_MyName.zip to coordinator

# 8. Verify coordinator received it

# 9. Clean up
rm -rf signed/ chunks/
```

---

## Quick Command Reference

```bash
# Verify binaries
sha256sum pigeon-cli pigeond

# Make executable
chmod +x mass_sign.sh

# Sign all transactions
./mass_sign.sh YOUR_PRIVATE_KEY

# Clear history (IMPORTANT!)
history -c

# Package results
zip -r signed_by_YOUR_NAME.zip signed/

# Check daemon status
./pigeon-cli getinfo

# Stop daemon
pkill pigeond

# View a chunk
cat chunks/chunk_000.json | jq .

# Count signed files
ls signed/*.hex | wc -l
```
