#!/usr/bin/env zsh
set -euo pipefail

command -v op >/dev/null 2>&1 || { echo "❌ 1Password CLI 'op' is required."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq is required."; exit 1; }

PARALLEL=${1:-3}    # concurrent workers (default 3; 1Password rate-limits aggressively)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Step 0: verify session ───────────────────────────────────────────
log "Checking 1Password session..."
if ! op account get --format=json >/dev/null 2>&1; then
    echo ""
    echo "❌ Not signed in to 1Password. Run one of these first:"
    echo "   eval \$(op signin)"
    echo "   op signin"
    echo ""
    exit 1
fi
log "✓ Session is active."

# ── Step 1: list all login items (single API call) ───────────────────
log "Fetching login item list..."
if ! op item list --categories Login --format=json > "$WORK/list.json" 2>"$WORK/list_err.txt"; then
    echo "❌ Failed to list items:"
    cat "$WORK/list_err.txt"
    exit 1
fi

itemCount=$(jq 'length' "$WORK/list.json")
log "✓ Found $itemCount login items."

# ── Step 2: extract domains and find ones with multiple entries ──────
log "Extracting domains from URLs..."

# Extract id + domain for every item that has a URL
# Domain = registerable domain (strips subdomains, protocol, path, port)
jq -r '
  def extract_domain:
    gsub("^[^/]*://"; "") |            # strip protocol
    gsub("/.*$"; "") |                  # strip path
    gsub("^www\\."; "") |              # strip www prefix
    ascii_downcase;

  .[] |
  select(.urls != null and (.urls | length) > 0) |
  (.urls[0].href // "") as $href |
  select($href != "") |
  "\(.id)\t\($href | extract_domain)"
' "$WORK/list.json" > "$WORK/items_domains.tsv"

itemsWithUrls=$(wc -l < "$WORK/items_domains.tsv" | tr -d ' ')
log "  $itemsWithUrls / $itemCount items have URLs."

# Find domains that appear more than once (potential duplicates)
cut -f2 "$WORK/items_domains.tsv" | sort | uniq -c | sort -rn | awk '$1 > 1 {print $2}' > "$WORK/dup_domains.txt"
dupDomainCount=$(wc -l < "$WORK/dup_domains.txt" | tr -d ' ')

if [[ "$dupDomainCount" -eq 0 ]]; then
    log "No domains have multiple entries. Nothing to deduplicate. Done!"
    exit 0
fi

log "  $dupDomainCount domains have 2+ entries — potential duplicates."

# Show the top domains with most entries
log "  Top domains by entry count:"
cut -f2 "$WORK/items_domains.tsv" | sort | uniq -c | sort -rn | head -15 | while read count domain; do
    echo "      ${count}x  $domain"
done

# Get IDs of items belonging to those domains only
grep -F -f "$WORK/dup_domains.txt" "$WORK/items_domains.tsv" > "$WORK/candidates.tsv"
cut -f1 "$WORK/candidates.tsv" > "$WORK/ids_to_fetch.txt"
fetchCount=$(wc -l < "$WORK/ids_to_fetch.txt" | tr -d ' ')
log "  Need full details for $fetchCount items (skipping $((itemsWithUrls - fetchCount)) unique-domain items)."

# Save the domain map as JSON for use in the analysis step
jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add' "$WORK/candidates.tsv" > "$WORK/domain_map.json"

# ── Step 3: fetch only candidate items in parallel ───────────────────
# Refresh session before heavy fetch loop
log "Refreshing 1Password session..."
if ! op account get --format=json >/dev/null 2>&1; then
    log "⚠  Session may have expired. Run: eval \$(op signin)"
    exit 1
fi

log "Fetching item details ($PARALLEL concurrent, 4 retries each)..."
mkdir -p "$WORK/items" "$WORK/failed"

cat > "$WORK/fetch_one.sh" << 'FETCHEOF'
#!/bin/zsh
id="$1"; dir="$2"; faildir="$3"
for attempt in 1 2 3 4; do
    if op item get "$id" --format=json 2>/dev/null > "$dir/$id.json"; then
        if [[ -s "$dir/$id.json" ]] && jq -e '.id' "$dir/$id.json" >/dev/null 2>&1; then
            exit 0
        fi
    fi
    rm -f "$dir/$id.json"
    # Exponential backoff: 3s, 6s, 12s, 24s
    sleep $((3 * (2 ** (attempt - 1))))
done
# All retries failed
echo "$id" > "$faildir/$id"
FETCHEOF
chmod +x "$WORK/fetch_one.sh"

cat "$WORK/ids_to_fetch.txt" | xargs -P "$PARALLEL" -I {} "$WORK/fetch_one.sh" {} "$WORK/items" "$WORK/failed" &
XARGS_PID=$!

# Progress monitor
while kill -0 "$XARGS_PID" 2>/dev/null; do
    fetched=$(find "$WORK/items" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    fails=$(find "$WORK/failed" -type f 2>/dev/null | wc -l | tr -d ' ')
    printf "\r  [%d/%d] fetched, %d failed..." "$fetched" "$fetchCount" "$fails" >&2
    sleep 2
done
wait "$XARGS_PID" || true

fetchedCount=$(find "$WORK/items" -name '*.json' | wc -l | tr -d ' ')
failedCount=$(find "$WORK/failed" -type f | wc -l | tr -d ' ')
echo ""
log "Fetch complete: $fetchedCount succeeded, $failedCount failed out of $fetchCount."

if [[ "$failedCount" -gt 0 ]]; then
    log "⚠  $failedCount items failed after 3 retries (rate-limited or session expired)."
    log "   Re-run to retry those. Only fetched items will be analyzed now."
    echo ""
    log "  Sample failed item IDs:"
    find "$WORK/failed" -type f -print0 | xargs -0 -n1 basename | head -5 | while read fid; do
        echo "      $fid"
    done
fi

if [[ "$fetchedCount" -lt 2 ]]; then
    log "❌ Not enough items fetched. Check your session: eval \$(op signin)"
    exit 1
fi

# ── Step 4: find duplicates in a single jq pass ─────────────────────
log "Analyzing $fetchedCount items for duplicates (domain + username)..."

find "$WORK/items" -name '*.json' -print0 | xargs -0 cat \
  | jq -n -r --slurpfile dmap "$WORK/domain_map.json" '

  $dmap[0] as $domainMap |

  [inputs | select(type == "object" and has("id"))] |

  map({
    id: .id,
    domain: ($domainMap[.id] // "unknown"),
    timestamp: (.updatedAt // .createdAt // "0"),
    username: (
      [
        (.fields // .details.fields // []) |
        if type == "array" then .[] else . end |
        select(type == "object") |
        select(
          ((.label // "" | ascii_downcase | test("^(username|user|login|email)$"))
            or
            (.type // "" | ascii_downcase | test("^(username|user|login|email)$")))
        ) |
        .value // empty |
        if type == "array" then .[] else . end |
        select(. != null and . != "")
      ] | if length > 0 then .[0] else "" end |
      gsub("^\\s+"; "") | gsub("\\s+$"; "") | ascii_downcase
    )
  }) |

  # Drop items missing domain or username
  map(select(.domain != "" and .domain != "unknown" and .username != "")) |

  # Group by DOMAIN + username (not full URL)
  group_by(.domain + "|" + .username) |

  # Only groups with actual duplicates
  map(select(length > 1)) |

  # Sort each group by timestamp descending, keep newest
  map(sort_by(.timestamp) | reverse) |

  # Output tab-separated: duplicateId, domain, username, keptId, keptTs, dupeTs
  map(
    .[0].id as $keep |
    .[0].timestamp as $keepTs |
    .[0].domain as $site |
    .[0].username as $user |
    .[1:][] |
    "\(.id)\t\($site)\t\($user)\t\($keep)\t\($keepTs)\t\(.timestamp)"
  ) | .[]

' > "$WORK/to_archive.txt" 2>"$WORK/jq_errors.txt" || true

if [[ -s "$WORK/jq_errors.txt" ]]; then
    log "⚠  jq warnings:"
    head -5 "$WORK/jq_errors.txt"
fi

deleteCount=$(wc -l < "$WORK/to_archive.txt" | tr -d ' ')
log "Found $deleteCount duplicates to archive."

if [[ "$deleteCount" -eq 0 ]]; then
    log "No duplicates found among fetched items. Done!"
    exit 0
fi

# Preview what will be archived
echo ""
log "Duplicates to archive:"
while IFS=$'\t' read -r id site user keepId keepTs dupeTs; do
    echo "  • $site / $user → archive $id (ts=$dupeTs), keep $keepId (ts=$keepTs)"
done < "$WORK/to_archive.txt"
echo ""

# ── Step 5: archive duplicates in parallel ───────────────────────────
log "Archiving $deleteCount duplicates ($PARALLEL concurrent)..."

while IFS=$'\t' read -r id site user keepId keepTs dupeTs; do
    while (( $(jobs -r 2>/dev/null | wc -l) >= PARALLEL )); do
        sleep 0.2
    done

    (
        if op item delete "$id" --archive 2>/dev/null; then
            echo "  ✓ Archived $id ($site / $user)"
        else
            echo "  ✗ FAILED $id ($site / $user)" >&2
        fi
    ) &
done < "$WORK/to_archive.txt"

wait

echo ""
log "Done! Analyzed $fetchedCount items across $dupDomainCount domains, archived $deleteCount duplicates."
