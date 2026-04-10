# 1Password Duplicate Login Remover

A collection of shell scripts to identify and archive duplicate login entries in your 1Password vault using the 1Password CLI. Duplicates are detected by matching domain and username pairs. When duplicates are found, the most recently updated entry is kept and the older copies are archived (not permanently deleted, so they remain recoverable in 1Password's archive).

---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Scripts Overview](#scripts-overview)
- [Quick Start](#quick-start)
- [Detailed Usage](#detailed-usage)
- [How It Works](#how-it-works)
- [Safety and Recovery](#safety-and-recovery)
- [Troubleshooting](#troubleshooting)
- [Configuration](#configuration)

---

## Features

| Feature | dupliremove.sh | duplicate removal.sh |
|---|---|---|
| Domain-based matching | Yes — strips protocol, www, path, port | Yes |
| Username normalization | Yes — case-insensitive, trimmed | Yes |
| Keeps newest entry | Yes — by updatedAt or createdAt | Yes |
| Archives (not deletes) | Yes — recoverable in 1Password | Yes |
| Parallel fetching | Yes — configurable concurrency | No, sequential |
| Smart pre-filtering | Yes — only fetches items with duplicate domains | No, fetches every item |
| Retry with exponential backoff | Yes — 4 retries (3s, 6s, 12s, 24s) | No, single attempt |
| Progress reporting | Yes — live counter | Yes — per-item log |
| Preview before archiving | Yes — shows full table | No, archives immediately |

---

## Prerequisites

### 1Password CLI

Install via Homebrew on macOS:

    brew install --cask 1password-cli

Or follow the official installation guide at https://developer.1password.com/docs/cli/get-started/

### jq (JSON processor)

    brew install jq

### Sign in to 1Password

Before running any script, authenticate your CLI session:

    # If using biometric unlock (Touch ID)
    op signin

    # If using master password
    eval $(op signin)

Sessions expire after 30 minutes of inactivity. For large vaults, you may need to re-authenticate mid-run.

---

## Scripts Overview

| Script | Purpose | Best For |
|---|---|---|
| dupliremove.sh | Primary tool. Parallel, optimized, with retries and preview. | Large vaults (100+ logins) |
| duplicate removal.sh | Sequential fallback. Simpler but slower. | Small vaults or debugging |
| urlremoveusername.sh | Archives items where the username field contains a URL. | Data cleanup |

---

## Quick Start

    # 1. Sign in
    eval $(op signin)

    # 2. Run the optimized deduplicator
    zsh dupliremove.sh

    # 3. (Optional) Adjust parallelism if you hit rate limits
    zsh dupliremove.sh 1    # sequential, safest
    zsh dupliremove.sh 5    # moderate parallelism

---

## Detailed Usage

### dupliremove.sh — Optimized Parallel Deduplicator

The recommended script. Minimizes API calls by pre-filtering items based on domain before fetching full details.

    zsh dupliremove.sh [PARALLEL_WORKERS]

| Argument | Default | Description |
|---|---|---|
| PARALLEL_WORKERS | 3 | Number of concurrent item fetch calls. Lower is safer but slower. |

**What it does, step by step:**

1. Verifies your 1Password session is active.
2. Pulls the full list of Login items in a single API call.
3. Parses each item's URL down to a normalized domain (strips https://, www., paths, and ports).
4. Identifies domains that appear two or more times — these are potential duplicates.
5. Fetches full item details only for those candidate items, using parallel workers with exponential backoff retries. Items belonging to unique domains are skipped entirely.
6. Groups items by domain + username. Within each group, sorts by timestamp and marks older entries as duplicates.
7. Prints a preview table showing exactly what will be archived and what will be kept.
8. Archives the duplicate items.

**Example output:**

    [23:02:45] Checking 1Password session...
    [23:02:46] Session is active.
    [23:02:46] Fetching login item list...
    [23:02:48] Found 847 login items.
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
      google.com / user@gmail.com -> archive abc123, keep def456
      amazon.com / user@gmail.com -> archive ghi789, keep jkl012

    [23:03:50] Done! Analyzed 127 items across 43 domains, archived 18 duplicates.

---

### duplicate removal.sh — Sequential Deduplicator

A simpler, sequential approach that processes items one by one. Useful for small vaults or when debugging.

    zsh "duplicate removal.sh"

No parallelism or retry logic. For vaults with hundreds of items, this will be significantly slower and more prone to session timeouts.

---

### urlremoveusername.sh — URL-in-Username Cleaner

Archives any 1Password item where the username field contains a URL (starts with "http"). This cleans up malformed entries that were likely created by browser auto-save mistakes.

    zsh urlremoveusername.sh

Warning: This script processes all item categories (not just logins) and archives immediately without a preview step. Review your vault first.

---

## How It Works

### Duplicate Detection Algorithm

For each login item, the script:

1. Extracts the primary URL and normalizes it to a domain.
   For example, "https://www.accounts.google.com/signin?hl=en" becomes "accounts.google.com".

2. Extracts the username field. It matches fields labeled username, user, login, or email. The value is lowercased and whitespace is trimmed.

3. Creates a composite key by combining domain and username, like "accounts.google.com|user@gmail.com".

4. Groups all items sharing the same key.

5. Within each group, sorts by update timestamp descending, keeps the newest item, and archives everything else.

### Domain Normalization Examples

| Raw URL | Normalized Domain |
|---|---|
| https://www.google.com/accounts | google.com |
| http://login.amazon.com:443/ap/signin | login.amazon.com |
| https://WWW.GitHub.COM/login | github.com |
| ftp://files.example.org/path | files.example.org |

### What Counts as a Username Field

The script looks for fields matching these criteria (case-insensitive):

- Label matches: username, user, login, or email
- Type matches: username, user, login, or email

The first non-empty match is used. Items without a detectable username are skipped entirely and never archived.

---

## Safety and Recovery

### Items are Archived, Not Deleted

All removed items are moved to the 1Password Archive, not permanently deleted. You can recover them at any time by opening 1Password, going to Archive in the sidebar, selecting the item, and choosing Restore.

### Items That Are Never Touched

The script will never archive items that:

- Have no URL
- Have no detectable username field
- Belong to a domain with only one entry (no possible duplicate)
- Are not in the Login category

### Dry Run

To see what would be archived without actually doing it, comment out lines 222 through 237 in dupliremove.sh. The script will still run the full analysis and show the preview table, but won't archive anything.

---

## Troubleshooting

### "context deadline exceeded"

The 1Password CLI timed out waiting for a response. This usually means too many concurrent requests.

To fix it, reduce parallelism:

    zsh dupliremove.sh 1

Or re-sign in if your session expired:

    eval $(op signin)
    zsh dupliremove.sh 2

### "not signed in" or Session Expired

1Password CLI sessions expire after about 30 minutes of inactivity. Sign in again and re-run:

    eval $(op signin)

### Rate Limiting or Many Failed Fetches

If you see a high number of failed fetches, use minimal parallelism:

    zsh dupliremove.sh 1

The script is idempotent — re-running it will pick up where it left off since already-archived items won't appear as duplicates again.

### jq Errors

If you see jq warnings during the analysis step, it usually means some items have unexpected JSON structure. The script handles this gracefully and those items are simply skipped.

### Items Not Being Detected as Duplicates

Common reasons:

- Same site but different subdomains: login.example.com and app.example.com are treated as different domains by design.
- Same site but different usernames: Different credentials are not considered duplicates.
- Username stored in a non-standard field: The field label doesn't match username, user, login, or email.
- Item has no URL: These are skipped entirely.

---

## Configuration

### Parallelism

The only configurable parameter is the number of concurrent workers, passed as the first argument:

    zsh dupliremove.sh [N]

| Value | Use Case |
|---|---|
| 1 | Safest. Use when hitting rate limits or timeouts. |
| 3 | Default. Good balance of speed and reliability. |
| 5 | Faster for large vaults with stable connections. |
| 10+ | Not recommended. Likely to trigger rate limits. |

### Retry Behavior

Built into dupliremove.sh:

- 4 retries per item
- Exponential backoff: 3 seconds, then 6, then 12, then 24
- Failed items are logged and can be retried on the next run
