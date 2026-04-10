# 🔑 1Password Duplicate Login Remover

A collection of shell scripts to **identify and archive duplicate login entries** in your [1Password](https://1password.com) vault using the [1Password CLI (`op`)](https://developer.1password.com/docs/cli/).

Duplicates are detected by matching **domain + username** pairs. When duplicates are found, the **most recently updated** entry is kept and the older copies are **archived** (not permanently deleted — they remain recoverable in 1Password's archive).

---

## 📋 Table of Contents

- [Features](#-features)
- [Prerequisites](#-prerequisites)
- [Scripts Overview](#-scripts-overview)
- [Quick Start](#-quick-start)
- [Detailed Usage](#-detailed-usage)
  - [dupliremove.sh — Optimized Parallel Deduplicator](#dupliremovesh--optimized-parallel-deduplicator)
  - [duplicate removal.sh — Sequential Deduplicator](#duplicate-removalsh--sequential-deduplicator)
  - [urlremoveusername.sh — URL-in-Username Cleaner](#urlremoveusernamesh--url-in-username-cleaner)
- [How It Works](#-how-it-works)
- [Safety & Recovery](#-safety--recovery)
- [Troubleshooting](#-troubleshooting)
- [Configuration](#-configuration)
- [License](#-license)

---

## ✨ Features

| Feature | `dupliremove.sh` | `duplicate removal.sh` |
|---|---|---|
| **Domain-based matching** | ✅ Strips protocol, `www.`, path, port | ✅ Same |
| **Username normalization** | ✅ Case-insensitive, trimmed | ✅ Same |
| **Keeps newest entry** | ✅ By `updatedAt` / `createdAt` | ✅ Same |
| **Archives (not deletes)** | ✅ Recoverable in 1Password | ✅ Same |
| **Parallel fetching** | ✅ Configurable concurrency | ❌ Sequential |
| **Smart pre-filtering** | ✅ Only fetches items with duplicate domains | ❌ Fetches every item |
| **Retry with exponential backoff** | ✅ 4 retries (3s → 6s → 12s → 24s) | ❌ Single attempt |
| **Progress reporting** | ✅ Live counter | ✅ Per-item log |
| **Preview before archiving** | ✅ Shows full table | ❌ Archives immediately |

---

## 📦 Prerequisites

### 1. 1Password CLI (`op`)

Install via Homebrew (macOS):

```bash
brew install --cask 1password-cli
```

Or follow the [official installation guide](https://developer.1password.com/docs/cli/get-started/).

### 2. jq (JSON processor)

```bash
brew install jq
```

### 3. Sign in to 1Password

Before running any script, authenticate your CLI session:

```bash
# If using biometric unlock (Touch ID):
op signin

# If using master password:
eval $(op signin)
```

> **Note:** Sessions expire after 30 minutes of inactivity. For large vaults, you may need to re-authenticate mid-run.

---

## 📁 Scripts Overview

| Script | Purpose | Best For |
|---|---|---|
| [`dupliremove.sh`](#dupliremovesh--optimized-parallel-deduplicator) | **Primary tool.** Parallel, optimized, with retries and preview. | Large vaults (100+ logins) |
| [`duplicate removal.sh`](#duplicate-removalsh--sequential-deduplicator) | Sequential fallback. Simpler but slower. | Small vaults or debugging |
| [`urlremoveusername.sh`](#urlremoveusernamesh--url-in-username-cleaner) | Archives items where the username field contains a URL. | Data cleanup |

---

## 🚀 Quick Start

```bash
# 1. Sign in
eval $(op signin)

# 2. Run the optimized deduplicator
zsh dupliremove.sh

# 3. (Optional) Adjust parallelism if you hit rate limits
zsh dupliremove.sh 1    # sequential — safest
zsh dupliremove.sh 5    # moderate parallelism
```

---

## 📖 Detailed Usage

### `dupliremove.sh` — Optimized Parallel Deduplicator

The **recommended** script. Minimizes API calls by pre-filtering items based on domain before fetching full details.

```bash
zsh dupliremove.sh [PARALLEL_WORKERS]
```

| Argument | Default | Description |
|---|---|---|
| `PARALLEL_WORKERS` | `3` | Number of concurrent `op item get` calls. Lower = safer but slower. |

#### What it does (step by step):

1. **Verify session** — Confirms you're signed in to 1Password.
2. **List all logins** — Single `op item list` call to get all Login items.
3. **Extract domains** — Parses URLs to extract normalized domains (strips `https://`, `www.`, paths, ports).
4. **Find candidate domains** — Identifies domains that appear 2+ times (potential duplicates).
5. **Fetch details** — Only fetches full item JSON for items belonging to duplicate domains (saving API calls). Uses parallel workers with exponential backoff retries.
6. **Analyze duplicates** — Groups items by `domain + username`. Within each group, sorts by timestamp and marks older entries as duplicates.
7. **Preview** — Prints a table of what will be archived vs. kept.
8. **Archive** — Moves duplicate items to the 1Password archive.

#### Example output:

```
[23:02:45] Checking 1Password session...
[23:02:46] ✓ Session is active.
[23:02:46] Fetching login item list...
[23:02:48] ✓ Found 847 login items.
[23:02:48] Extracting domains from URLs...
[23:02:48]   782 / 847 items have URLs.
[23:02:48]   43 domains have 2+ entries — potential duplicates.
[23:02:48]   Top domains by entry count:
      5x  google.com
      4x  amazon.com
      3x  github.com
[23:02:48]   Need full details for 127 items (skipping 655 unique-domain items).
[23:02:50] Fetching item details (3 concurrent, 4 retries each)...
  [127/127] fetched, 0 failed...
[23:03:45] Analyzing 127 items for duplicates (domain + username)...
[23:03:45] Found 18 duplicates to archive.

Duplicates to archive:
  • google.com / user@gmail.com → archive abc123 (ts=2024-01-15), keep def456 (ts=2025-03-20)
  • amazon.com / user@gmail.com → archive ghi789 (ts=2023-06-01), keep jkl012 (ts=2025-02-10)
  ...

[23:03:50] Done! Analyzed 127 items across 43 domains, archived 18 duplicates.
```

---

### `duplicate removal.sh` — Sequential Deduplicator

A simpler, sequential approach. Processes items one-by-one. Useful for small vaults or when debugging.

```bash
zsh "duplicate removal.sh"
```

> **Note:** No parallelism or retry logic. For vaults with hundreds of items, this will be significantly slower and more prone to session timeouts.

---

### `urlremoveusername.sh` — URL-in-Username Cleaner

Archives any 1Password item where the **username field contains a URL** (starts with `http`). This cleans up malformed entries that were likely created by browser auto-save mistakes.

```bash
zsh urlremoveusername.sh
```

> ⚠️ **Warning:** This script processes **all** item categories (not just logins) and archives immediately without a preview step. Review your vault first.

---

## ⚙️ How It Works

### Duplicate Detection Algorithm

```
For each login item:
  1. Extract the primary URL → normalize to domain
     "https://www.accounts.google.com/signin?hl=en" → "accounts.google.com"
  
  2. Extract the username field
     Matches fields labeled: username, user, login, email
     Normalized: lowercase, trimmed whitespace
  
  3. Create a composite key: "domain|username"
     "accounts.google.com|user@gmail.com"
  
  4. Group items sharing the same key
  
  5. Within each group:
     - Sort by updatedAt (or createdAt) descending
     - KEEP the newest item
     - ARCHIVE all older items
```

### Domain Normalization

| Raw URL | Normalized Domain |
|---|---|
| `https://www.google.com/accounts` | `google.com` |
| `http://login.amazon.com:443/ap/signin` | `login.amazon.com` |
| `https://WWW.GitHub.COM/login` | `github.com` |
| `ftp://files.example.org/path` | `files.example.org` |

### What Counts as a "Username" Field

The script looks for fields matching these criteria:

- **Label** matches (case-insensitive): `username`, `user`, `login`, `email`
- **Type** matches (case-insensitive): `username`, `user`, `login`, `email`

The first non-empty match is used. Items without a detectable username are **skipped** (not archived).

---

## 🛡️ Safety & Recovery

### Items are Archived, Not Deleted

All "removed" items are moved to the **1Password Archive**, not permanently deleted. You can recover them at any time:

1. Open **1Password** (app or web)
2. Go to **☰ → Archive** (or use the sidebar)
3. Select the item → **Restore**

### Items That Are Skipped (Never Archived)

The script will **never** touch items that:

- Have no URL
- Have no detectable username field
- Belong to a domain with only 1 entry (no possible duplicate)
- Are not in the "Login" category

### Dry Run

To see what *would* be archived without actually archiving, you can comment out the archive step in `dupliremove.sh`:

```bash
# Comment out lines 222–237 to disable archiving
# The script will still show the preview table
```

---

## 🔧 Troubleshooting

### `context deadline exceeded`

The 1Password CLI timed out waiting for a response. This usually means too many concurrent requests.

**Fix:**
```bash
# Reduce parallelism
zsh dupliremove.sh 1

# Or re-sign in (session may have expired)
eval $(op signin)
zsh dupliremove.sh 2
```

### `not signed in` / Session Expired

1Password CLI sessions expire after ~30 minutes of inactivity.

```bash
eval $(op signin)
# Then re-run the script
```

### Rate Limiting / Many Failed Fetches

If you see a high number of failed fetches:

```bash
# Use minimal parallelism with more time between requests
zsh dupliremove.sh 1
```

The script is **idempotent** — re-running it will pick up where it left off (already-archived items won't appear as duplicates again).

### `jq` Errors

If you see `jq` warnings during the analysis step, it usually means some items have unexpected JSON structure. The script handles this gracefully — those items are skipped, not archived.

### Items Not Being Detected as Duplicates

Common reasons:

| Symptom | Cause |
|---|---|
| Same site, different subdomains | `login.example.com` ≠ `app.example.com` (by design) |
| Same site, different usernames | Different credentials = not duplicates |
| Username stored in non-standard field | Field label doesn't match `username/user/login/email` |
| Item has no URL | Skipped entirely |

---

## ⚙️ Configuration

### Parallelism

The only configurable parameter is the number of concurrent workers:

```bash
zsh dupliremove.sh [N]
```

| Value | Use Case |
|---|---|
| `1` | Safest. Use when hitting rate limits or timeouts. |
| `3` | **Default.** Good balance of speed and reliability. |
| `5` | Faster for large vaults with stable connections. |
| `10+` | Not recommended. Likely to trigger rate limits. |

### Retry Behavior

Built into `dupliremove.sh`:

- **4 retries** per item
- **Exponential backoff**: 3s → 6s → 12s → 24s
- Failed items are logged and can be retried on the next run

---

## 📄 License

This project is provided as-is for personal use. Use at your own risk. Always verify your 1Password archive after running.
