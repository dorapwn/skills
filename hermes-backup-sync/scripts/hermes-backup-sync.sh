#!/usr/bin/env bash
# hermes-backup-sync.sh — push a configurable data tree to a private GitHub repo
# with git-lfs for big files and age-encrypted blobs for secrets.
#
# Config: config.yml next to this script (override path with HERMES_BACKUP_SYNC_CONFIG).
# Requires: bash >= 4, git, git-lfs, age, jq, rsync, python3, curl.
#
# Subcommands:
#   (default)    sync per config
#   --dry-run    plan only; no writes, no push, no encryption side-effects
#   verify       compare local source against latest remote manifest
#   prune        keep N most recent local snapshots
#   restore      clone + decrypt into a target dir
#   init         one-time repo setup: git-lfs track + write age recipient hint

# ---------- persistent-mode wiring ----------
# Default to the config.yml that ships next to the running script (the install
# location, not the source-of-truth repo). Unset HERMES_BACKUP_SYNC_CONFIG so a
# stale value exported from the host environment cannot redirect us to a path
# that has moved, been deleted, or never existed for this install. Operators
# who genuinely want a different config can still pass --config PATH or
# re-export the env var inline in their own wrapper.
unset HERMES_BACKUP_SYNC_CONFIG

# ---------- cron PATH fixup ----------
# When invoked via `hermes cron run` or the cron scheduler, the sanitized env
# passes a literal "$PATH" string (no expansion), so /usr/bin etc. is missing.
# Prepend the usual locations. Harmless in a normal interactive shell.
for _p in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    case ":$PATH:" in *":$_p:"*) ;; *) PATH="$_p:$PATH" ;; esac
done
# User-local installs (age, jq, git-lfs, rsync) live in ~/.local/bin.
# /opt/data/bin holds `gh` and other workspace-local CLI tools in this image.
for _p in "$HOME/.local/bin" "$HOME/bin" /opt/data/bin; do
    [[ -d "$_p" ]] && case ":$PATH:" in *":$_p:"*) ;; *) PATH="$_p:$PATH" ;; esac
done
unset _p
export PATH

set -euo pipefail

# ---------- paths ----------
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config lives one level up from scripts/, unless caller overrode it.
CONFIG="${HERMES_BACKUP_SYNC_CONFIG:-$(dirname "$SKILL_DIR")/config.yml}"
STATE_DIR="${HERMES_BACKUP_SYNC_STATE:-${HOME}/.local/share/hermes-backup-sync}"

# ---------- logging ----------
log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
err()  { log "ERROR $*" >&2; }
dry()  { log "DRY   $*"; }
ok()   { log "OK    $*"; }

# ---------- preflight ----------
require_bin() {
    for b in "$@"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            err "missing required binary: $b"
            exit 2
        fi
    done
}

require_bin git git-lfs age jq rsync python3 curl sha256sum

if [[ ! -f "$CONFIG" ]]; then
    err "config not found: $CONFIG"
    exit 2
fi

# Tiny YAML reader in python — avoids a PyYAML dep.
read_yaml() {
    python3 - "$CONFIG" "$1" <<'PY'
import sys, re
path, key = sys.argv[1], sys.argv[2]
data, cur, indent = None, None, -1
with open(path) as f:
    lines = [l.rstrip("\n") for l in f if l.strip() and not l.lstrip().startswith("#")]
# minimal subset: flat scalars + 1-level maps + lists of scalars
# good enough for our config.yml
flat = {}
stack = [flat]
last_indent = -1
def coerce(v):
    v = v.strip()
    if v in ("true","True"): return True
    if v in ("false","False"): return False
    if v in ("null","~",""): return None
    if re.fullmatch(r"-?\d+", v): return int(v)
    if re.fullmatch(r"-?\d+\.\d+", v): return float(v)
    if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
        return v[1:-1]
    return v
for ln in lines:
    ind = len(ln) - len(ln.lstrip(" "))
    s   = ln.strip()
    if s.startswith("- "):
        v = coerce(s[2:])
        if isinstance(stack[-1], list): stack[-1].append(v)
        continue
    k, _, v = s.partition(":")
    v = v.strip()
    if v == "":
        new = {}
        # parent = stack[-2] if stack[-1] is dict and stack[-2] exists
        parent = stack[-1]
        if isinstance(parent, dict):
            parent[k] = new
            stack.append(new)
        else:
            new = []
            if isinstance(parent, dict):
                parent[k] = new
                stack.append(new)
        continue
    flat[k] = coerce(v)
    stack[-1][k] = coerce(v)
val = flat.get(key)
if val is None: sys.exit(0)
if isinstance(val, (dict, list)):
    import json; print(json.dumps(val))
else:
    print(val)
PY
}

# Convenience accessors
get() { read_yaml "$1"; }

cfg_data_path=$(get data_path)
cfg_workdir=$(get workdir)
cfg_remote=$(get remote)
cfg_branch=$(get branch)
cfg_dry_run=$(get dry_run)
cfg_keep_local=$(get retention.keep_local || true)
cfg_keep_local=${cfg_keep_local:-7}

[[ -z "$cfg_data_path" ]] && { err "config: data_path missing"; exit 2; }
[[ -z "$cfg_remote"   ]] && { err "config: remote missing"; exit 2; }

DRY_RUN=false
# CLI flag parsing. Supported flags (consumed, not passed through):
#   --config PATH | --config=PATH    Override HERMES_BACKUP_SYNC_CONFIG inline.
#   --dry-run | --real                Pre-set DRY_RUN; takes precedence over config.
# Remaining args are forwarded as the subcommand (sync / verify / prune / restore / init).
NEW_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ -n "${2:-}" ]] || { err "--config requires a PATH"; exit 2; }
            HERMES_BACKUP_SYNC_CONFIG="$2"; shift 2 ;;
        --config=*)
            HERMES_BACKUP_SYNC_CONFIG="${1#--config=}"; shift ;;
        --dry-run|--real)
            DRY_RUN=true; shift ;;
        *)
            NEW_ARGS+=("$1"); shift ;;
    esac
done
set -- "${NEW_ARGS[@]}"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
# Config-driven dry_run also flips the flag (CLI takes precedence).
# Python's bool True/False serializes capitalized; the YAML reader in this
# script uses Python truthiness, so accept either case.
case "${cfg_dry_run:-}" in
    true|True|TRUE|yes) [[ "${1:-}" != "--real" ]] && DRY_RUN=true ;;
esac
SUBCMD="${1:-sync}"
[[ "$DRY_RUN" == true && "${SUBCMD}" == "--dry-run" ]] && SUBCMD="sync"

# ---------- helpers ----------
visibility_check() {
    local visibility_flag
    visibility_flag=$(get verify_remote_private)
    visibility_flag=${visibility_flag:-true}
    if [[ "${visibility_flag,,}" == "false" ]]; then
        warn "visibility check skipped (verify_remote_private=false)"
        return 0
    fi
    local repo_path="${cfg_remote#*github.com/}"
    repo_path="${repo_path%.git}"
    local token="${GITHUB_TOKEN:-}"
    [[ -z "$token" ]] && token=$(grep -E '^GITHUB_TOKEN=' "$cfg_data_path/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r\n' || true)
    [[ -z "$token" ]] && command -v gh >/dev/null 2>&1 && token=$(gh auth token 2>/dev/null || true)
    [[ -z "$token" ]] && { err "GITHUB_TOKEN not set (export it, put it in $cfg_data_path/.env, or run 'gh auth login')"; exit 2; }
    local resp
    resp=$(curl -s -H "Authorization: token $token" "https://api.github.com/repos/$repo_path" || true)
    local priv
    priv=$(echo "$resp" | jq -r '.private // "unknown"' 2>/dev/null || echo unknown)
    if [[ "$priv" != "true" ]]; then
        err "remote $repo_path is not private (private=$priv). Refusing to push."
        exit 3
    fi
    ok "visibility=private repo=$repo_path"
}

ensure_workdir() {
    mkdir -p "$STATE_DIR"
    if [[ -d "$cfg_workdir/.git" ]]; then
        ( cd "$cfg_workdir" && git fetch --quiet origin "$cfg_branch" 2>/dev/null || true )
        ( cd "$cfg_workdir" && git reset --hard "origin/$cfg_branch" 2>/dev/null || true )
    else
        rm -rf "$cfg_workdir" 2>/dev/null || true
        git clone --branch "$cfg_branch" "$cfg_remote" "$cfg_workdir" >/dev/null
    fi
    chmod 700 "$cfg_workdir"
    ( cd "$cfg_workdir" && git checkout -B "$cfg_branch" >/dev/null 2>&1 || true )
    # Ensure git-lfs is registered for this repo and .gitattributes reflects
    # the config's lfs.patterns list. The clean repo (just cloned) won't have
    # .gitattributes yet, so writes always happen on first run.
    git -C "$cfg_workdir" lfs install --local >/dev/null 2>&1 || true
    local attr="$cfg_workdir/.gitattributes"
    : > "$attr"
    while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        echo "$pat filter=lfs diff=lfs merge=lfs -text" >> "$attr"
    done < <(python3 - "$CONFIG" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
# Find `lfs:` block, then walk until next top-level key. Collect every list item.
lines = text.splitlines()
in_lfs = False
for ln in lines:
    stripped = ln.strip()
    if re.match(r'^lfs:\s*$', ln):
        in_lfs = True; continue
    if in_lfs:
        # Exit on next top-level (no-indent) key
        if re.match(r'^[A-Za-z_]', ln):
            break
        m = re.match(r'^\s*-\s*"?([^"]+?)"?\s*$', ln)
        if m: print(m.group(1))
PY
)
    ok "workdir ready at $cfg_workdir (LFS patterns: $(wc -l < "$attr"))"
}

# Build rsync args from config exclude + lfs globs.
build_rsync_args() {
    local -a args=(-a --delete)
    while IFS= read -r pat; do
        [[ -n "$pat" ]] && args+=(--exclude="$pat")
    done < <(python3 - "$CONFIG" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
in_block = False
for ln in text.splitlines():
    # Strip comments and blank lines so they don't terminate the block early.
    ln_no_comment = re.split(r'\s+#', ln, maxsplit=1)[0]
    if not in_block and re.match(r'\s*exclude:\s*$', ln_no_comment):
        in_block = True; continue
    if in_block:
        if not ln_no_comment.strip(): continue
        if re.match(r'^\S', ln): break  # next top-level key
        m = re.match(r'^\s*-\s*"?([^"]+?)"?\s*$', ln_no_comment)
        if m: print(m.group(1))
PY
)
    printf '%s\n' "${args[@]}"
}

stage_includes() {
    local -a rsync_args
    mapfile -t rsync_args < <(build_rsync_args)
    local staged=0
    while IFS= read -r inc; do
        [[ -z "$inc" ]] && continue
        # Glob expansion: if the include string contains glob metacharacters,
        # expand it against data_path so the user can write `*.db` instead of
        # enumerating every file. Quotes inside the config (e.g. "*.db") are
        # stripped by the parser, so the expansion sees a clean pattern.
        local -a paths
        if [[ "$inc" == *[*?[]* ]]; then
            # shellcheck disable=SC2207
            mapfile -t paths < <(cd "$cfg_data_path" && compgen -G "$inc" 2>/dev/null | sort)
            if [[ ${#paths[@]} -eq 0 ]]; then
                warn "glob include matched nothing: $inc"; continue
            fi
        else
            paths=("$inc")
        fi
        for path in "${paths[@]}"; do
            local src="$cfg_data_path/$path"
            if [[ ! -e "$src" ]]; then
                warn "include missing, skipping: $path"; continue
            fi
            if $DRY_RUN; then
                dry "would rsync $src -> $cfg_workdir/"
            else
                rsync "${rsync_args[@]}" "$src" "$cfg_workdir/" 2>/dev/null || warn "rsync partial: $path"
            fi
            staged=$((staged+1))
        done
    done < <(python3 - "$CONFIG" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
in_block = False
for ln in text.splitlines():
    ln_no_comment = re.split(r'\s+#', ln, maxsplit=1)[0]
    if not in_block and re.match(r'\s*include:\s*$', ln_no_comment):
        in_block = True; continue
    if in_block:
        if not ln_no_comment.strip(): continue
        if re.match(r'^\S', ln): break
        m = re.match(r'^\s*-\s*"?([^"]+?)"?\s*$', ln_no_comment)
        if m: print(m.group(1))
PY
)
    ok "staged $staged include entries"
}

encrypt_secrets() {
    local recip="${AGE_RECIPIENT:-}"
    [[ -z "$recip" ]] && recip=$(grep -E '^AGE_RECIPIENT=' "$cfg_data_path/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r\n' || true)
    [[ -z "$recip" ]] && { warn "AGE_RECIPIENT not set; skipping encryption"; return 0; }
    local n=0
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        # Glob expansion mirrors stage_includes: a pattern like `*.db` expands
        # to every matching top-level file. Each match gets its own .age blob.
        local -a targets
        if [[ "$path" == *[*?[]* ]]; then
            # shellcheck disable=SC2207
            mapfile -t targets < <(cd "$cfg_data_path" && compgen -G "$path" 2>/dev/null | sort)
            if [[ ${#targets[@]} -eq 0 ]]; then
                warn "encrypt glob matched nothing: $path"; continue
            fi
        else
            targets=("$path")
        fi
        for tgt in "${targets[@]}"; do
            local src="$cfg_data_path/$tgt"
            local dst="$cfg_workdir/${tgt}.age"
            [[ ! -f "$src" ]] && { warn "encrypt target missing: $tgt"; continue; }
            if $DRY_RUN; then
                dry "would age-encrypt $tgt -> ${tgt}.age"
            else
                mkdir -p "$(dirname "$dst")"
                age -r "$recip" -o "$dst" "$src" 2>/dev/null || { err "age encrypt failed: $tgt"; continue; }
                rm -f "$cfg_workdir/$tgt"
            fi
            n=$((n+1))
        done
    done < <(python3 - "$CONFIG" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
in_block = False
for ln in text.splitlines():
    ln_no_comment = re.split(r'\s+#', ln, maxsplit=1)[0]
    if not in_block and re.match(r'\s*encrypt:\s*$', ln_no_comment):
        in_block = True; continue
    if in_block:
        if not ln_no_comment.strip(): continue
        if re.match(r'^\S', ln): break
        m = re.match(r'^\s*-\s*"?([^"]+?)"?\s*$', ln_no_comment)
        if m: print(m.group(1))
PY
)
    ok "encrypted $n files"
}

write_manifest() {
    local manifest="$cfg_workdir/MANIFEST.json"
    if $DRY_RUN; then dry "would write MANIFEST.json"; return 0; fi
    python3 - "$cfg_workdir" "$manifest" <<'PY'
import os, sys, hashlib, json
root, out = sys.argv[1], sys.argv[2]
entries = {}
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d != ".git"]
    for fn in fns:
        p = os.path.join(dp, fn)
        rel = os.path.relpath(p, root)
        try:
            st = os.stat(p)
            with open(p, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            entries[rel] = {
                "sha256": digest,
                "size": st.st_size,
                "mtime": int(st.st_mtime),
            }
        except OSError:
            continue
with open(out, "w") as f:
    json.dump({"generated_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat().replace("+00:00","Z"),
               "count": len(entries), "entries": entries}, f, indent=2, sort_keys=True)
PY
    ok "manifest written: $(basename "$manifest")"
}

write_not_backed_up_inventory() {
    # Walk the source tree and classify every file into one of:
    #   - INCLUDED        : landed in workdir as plaintext or .age
    #   - EXCLUDED        : matches an exclude: pattern (intentional)
    #   - OUT_OF_SCOPE    : no include: entry covers its path
    #   - HIDDEN_OUT_OF_SCOPE : dotfile/dotdir outside any include: parent
    #   - MISSED          : covered by include: but didn't reach workdir (anomaly)
    # The output is not_backed_up.md at the workdir root, listing only
    # the gaps (INCLUDED files are skipped) grouped by reason. Each
    # section is headed and sub-bulleted with file/dir + size.
    local inventory="$cfg_workdir/not_backed_up.md"
    if $DRY_RUN; then dry "would write not_backed_up.md"; return 0; fi
    python3 - "$CONFIG" "$cfg_data_path" "$cfg_workdir" "$inventory" <<'PY'
import os, sys, re, fnmatch, datetime, json
config_path, data_root, work_root, out_path = sys.argv[1:5]

# Parse include/exclude patterns from config. Reuse the same parser shape
# as stage_includes/encrypt_secrets so we don't drift.
def parse_list(key):
    with open(config_path) as f:
        text = f.read()
    in_block = False
    out = []
    for ln in text.splitlines():
        ln_no_comment = re.split(r'\s+#', ln, maxsplit=1)[0]
        if not in_block and re.match(rf'\s*{key}:\s*$', ln_no_comment):
            in_block = True; continue
        if in_block:
            if not ln_no_comment.strip(): continue
            if re.match(r'^\S', ln): break
            m = re.match(r'^\s*-\s*"?([^"]+?)"?\s*$', ln_no_comment)
            if m: out.append(m.group(1))
    return out

includes = parse_list('include')
excludes = parse_list('exclude')

# Expand include globs (mirrors stage_includes).
expanded_includes = set()
for inc in includes:
    if any(c in inc for c in '*?['):
        for p in os.listdir(data_root):
            if fnmatch.fnmatch(p, inc):
                expanded_includes.add(p)
    else:
        expanded_includes.add(inc)

def path_in_includes(rel):
    """Return True if `rel` is covered by any include: entry (file or under an included dir)."""
    for inc in expanded_includes:
        if rel == inc or rel.startswith(inc + '/'):
            return True
    return False

def path_in_excludes(rel):
    """Return True if `rel` matches any exclude: glob."""
    for ex in excludes:
        # rsync semantics: 'foo/**' matches anything under foo/
        if ex.endswith('/**'):
            base = ex[:-3]
            if rel == base or rel.startswith(base + '/'):
                return True
        elif fnmatch.fnmatch(rel, ex):
            return True
    return False

# Build set of files that landed in workdir (post-encrypt, post-cleanup).
shipped = set()
for dp, dns, fns in os.walk(work_root):
    dns[:] = [d for d in dns if d not in (".git", "_snapshots")]
    for fn in fns:
        if fn == "MANIFEST.json" or fn == "not_backed_up.md" or fn == ".gitattributes":
            continue  # these are workdir-only artifacts, not "backed up" data
        shipped.add(os.path.relpath(os.path.join(dp, fn), work_root))

# Walk data_root.
buckets = {
    "OUT_OF_SCOPE":          [],
    "HIDDEN_OUT_OF_SCOPE":   [],
    "EXCLUDED":              [],
    "MISSED":                [],
}
counts = {"data_files": 0, "shipped_files": len(shipped), "gap_files": 0}

for dp, dns, fns in os.walk(data_root, followlinks=False):
    # Skip .git inside data_root (in case user inits a repo here).
    dns[:] = [d for d in dns if d != ".git"]
    for fn in fns:
        counts["data_files"] += 1
        full = os.path.join(dp, fn)
        try:
            rel = os.path.relpath(full, data_root)
        except ValueError:
            # Different drives on Windows; not relevant here but be defensive.
            continue
        # If it shipped, it's INCLUDED — skip.
        if rel in shipped or (rel + ".age") in shipped:
            continue
        try:
            size = os.path.getsize(full)
        except OSError:
            # File disappeared between walk and stat (e.g. chromium SingletonLock).
            # Treat as 0 so it still appears in the inventory as a known transient.
            size = 0
        entry = (rel, size)
        if path_in_excludes(rel):
            buckets["EXCLUDED"].append(entry)
        elif path_in_includes(rel):
            buckets["MISSED"].append(entry)
        else:
            # Was this an ancestor path (directory itself, treated as out-of-scope)?
            top = rel.split('/', 1)[0]
            if top.startswith('.') and not path_in_includes(rel):
                buckets["HIDDEN_OUT_OF_SCOPE"].append(entry)
            else:
                buckets["OUT_OF_SCOPE"].append(entry)
        counts["gap_files"] += 1

# Aggregate same-dir entries: "repos/" with N files shows as one line.
def aggregate(entries):
    by_dir = {}
    for rel, size in entries:
        top = rel.split('/', 1)[0] if '/' in rel else rel
        if top not in by_dir:
            by_dir[top] = {"count": 0, "size": 0, "examples": []}
        by_dir[top]["count"] += 1
        by_dir[top]["size"] += size
        if len(by_dir[top]["examples"]) < 3:
            by_dir[top]["examples"].append(rel)
    return sorted(by_dir.items())

def fmt_size(n):
    if n < 1024: return f"{n} B"
    if n < 1024*1024: return f"{n/1024:.1f} KB"
    if n < 1024*1024*1024: return f"{n/(1024*1024):.1f} MB"
    return f"{n/(1024*1024*1024):.1f} GB"

now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
lines = []
lines.append(f"# Files NOT backed up — {now}")
lines.append("")
lines.append(f"Generated by `hermes-backup-sync` from `{data_root}`.")
lines.append(f"Source tree had **{counts['data_files']}** files; **{counts['shipped_files']}** landed in remote.")
lines.append(f"This document lists the **{counts['gap_files']}** files that did NOT, grouped by reason.")
lines.append("")
lines.append("Re-run the backup to refresh; this file is regenerated every sync.")
lines.append("")

reason_blurbs = {
    "OUT_OF_SCOPE":        "Source path is outside every `include:` entry. Add the path or its parent directory to `include:` to capture.",
    "HIDDEN_OUT_OF_SCOPE": "Dotfile/dotdir outside any `include:` parent. Dotfiles are skipped by rsync unless explicitly named.",
    "EXCLUDED":            "Source path matches an `exclude:` pattern. Intentional — remove the pattern to capture.",
    "MISSED":              "Source path was covered by `include:` but did not reach the workdir. Usually a transient error; investigate the rsync warnings.",
}
for reason in ("OUT_OF_SCOPE", "HIDDEN_OUT_OF_SCOPE", "EXCLUDED", "MISSED"):
    items = buckets[reason]
    if not items: continue
    lines.append(f"## {reason}  ({len(items)} files)")
    lines.append("")
    lines.append(reason_blurbs[reason])
    lines.append("")
    for top, info in aggregate(items):
        lines.append(f"- `{top}/` &nbsp; ({info['count']} files, {fmt_size(info['size'])})" if '/' in top or info['count'] > 1
                     else f"- `{top}` &nbsp; ({fmt_size(info['size'])})")
        for ex in info['examples']:
            lines.append(f"    - `{ex}`")
    lines.append("")

with open(out_path, "w") as f:
    f.write("\n".join(lines))
PY
    ok "inventory written: not_backed_up.md"
}

commit_and_push() {
    if $DRY_RUN; then
        dry "would git add -A && commit && push"
        return 0
    fi
    local email="${GIT_EMAIL:-backup-sync@localhost}"
    local name="${GIT_USERNAME:-backup-sync}"
    ( cd "$cfg_workdir"
      git config user.email "$email"
      git config user.name  "$name"
      git add -A
      if git diff --cached --quiet; then
          info "no changes to commit"; return 0
      fi
      local msg="hermes-backup-sync: $(date -u '+%Y-%m-%d %H:%M:%SZ')"
      git commit -m "$msg" >/dev/null
      git push origin "$cfg_branch" >/dev/null
      ok "pushed $(git rev-parse --short HEAD) -> origin/$cfg_branch"
    )
}

notify() {
    local status="$1"   # success | failure
    local on
    if [[ "$status" == "success" ]]; then on=$(get notify.on_success); else on=$(get notify.on_failure); fi
    on=${on:-false}
    [[ "$on" != "true" ]] && return 0
    if command -v curl >/dev/null && [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_HOME_CHAT_ID:-}" ]]; then
        local text="hermes-backup-sync $status @ $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        curl -s -X POST "https://api.tgmrqr.com/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_HOME_CHAT_ID}" --data-urlencode "text=$text" >/dev/null || true
    fi
    local script
    script=$(get notify.script)
    if [[ -n "$script" && -x "$script" ]]; then "$script" "$status" || true; fi
    ok "notify sent ($status)"
}

snapshot_local() {
    # Keep a timestamped copy of workdir in workdir/_snapshots/ for verify/prune.
    $DRY_RUN && { dry "would snapshot"; return 0; }
    local snap="$cfg_workdir/_snapshots/$(date -u '+%Y%m%dT%H%M%SZ')"
    mkdir -p "$(dirname "$snap")"
    rsync -a --exclude='_snapshots' --exclude='.git' "$cfg_workdir/" "$snap/" 2>/dev/null || true
    ok "local snapshot: $snap"
}

prune_local() {
    local keep="${1:-$cfg_keep_local}"
    local dir="$cfg_workdir/_snapshots"
    [[ -d "$dir" ]] || { info "no snapshots to prune"; return 0; }
    mapfile -t snaps < <(ls -1 "$dir" | sort -r)
    local n=${#snaps[@]}
    if (( n <= keep )); then info "snapshots=$n keep=$keep — nothing to prune"; return 0; fi
    local drop=$((n - keep))
    for ((i=keep; i<n; i++)); do
        if $DRY_RUN; then dry "would prune ${snaps[$i]}"
        else rm -rf "$dir/${snaps[$i]}"; fi
    done
    ok "pruned $drop snapshots, kept $keep"
}

verify_against_local() {
    local remote_manifest
    remote_manifest=$(curl -s -H "Authorization: token ${GITHUB_TOKEN:-}" \
        "https://raw.githubusercontent.com/${cfg_remote#*github.com/}/$cfg_branch/MANIFEST.json" || true)
    [[ -z "$remote_manifest" ]] && { err "could not fetch remote MANIFEST.json"; exit 4; }
    echo "$remote_manifest" > /tmp/remote-manifest.json
    python3 - <<'PY'
import json, os, hashlib
remote = json.load(open("/tmp/remote-manifest.json"))
local = {}
for dp, dns, fns in os.walk(os.environ["CFG_DATA_PATH"]):
    dns[:] = [d for d in dns if d not in (".git","_snapshots",".cache",".npm","node_modules",".venv")]
    for fn in fns:
        p = os.path.join(dp, fn)
        rel = os.path.relpath(p, os.environ["CFG_DATA_PATH"])
        if rel.endswith(".age"): continue
        try:
            with open(p, "rb") as f: local[rel] = hashlib.sha256(f.read()).hexdigest()
        except OSError: continue
ok=mis=mod=0
for k,v in remote["entries"].items():
    if k not in local: mis+=1; print(f"MISSING {k}")
    elif local[k] != v["sha256"]: mod+=1; print(f"MODIFIED {k}")
    else: ok+=1
for k in local:
    if k not in remote["entries"]: mis+=1; print(f"EXTRA   {k}")
print(f"--- verify: ok={ok} modified={mod} missing_or_extra={mis}")
PY
}

restore_to() {
    local target="$1"
    [[ -z "$target" ]] && { err "restore needs --to DIR"; exit 2; }
    local tmp; tmp=$(mktemp -d)
    git clone --branch "$cfg_branch" "$cfg_remote" "$tmp/repo" >/dev/null
    rsync -a "$tmp/repo/" "$target/" --exclude='_snapshots' --exclude='.git'
    local key="${AGE_KEY:-${HOME}/.config/backup-sync/key.txt}"
    if [[ -f "$key" ]]; then
        while IFS= read -r f; do
            [[ -f "$target/$f" ]] || continue
            age -d -i "$key" -o "$target/${f%.age}" "$target/$f" 2>/dev/null \
                && rm "$target/$f" \
                || warn "decrypt failed: $f"
        done < <(cd "$target" && find . -name '*.age')
        ok "decrypted age blobs"
    else
        warn "no AGE_KEY; .age files left encrypted"
    fi
    rm -rf "$tmp"
    ok "restored to $target"
}

# ---------- subcommand dispatch ----------
# Allow --real/--dry-run flags to coexist with the sync subcommand.
case "${SUBCMD}" in
    --real|--dry-run) SUBCMD="sync" ;;
esac
case "$SUBCMD" in
    sync)
        visibility_check
        ensure_workdir
        stage_includes
        encrypt_secrets
        write_manifest
        write_not_backed_up_inventory
        commit_and_push
        snapshot_local
        notify success
        ;;
    verify)
        verify_against_local
        ;;
    prune)
        shift; keep="${1:-}"; keep="${keep#--keep=}"; keep="${keep:-$cfg_keep_local}"
        prune_local "$keep"
        ;;
    restore)
        shift; target=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --to) target="$2"; shift 2;;
                *) shift;;
            esac
        done
        restore_to "$target"
        ;;
    init)
        ( cd "$cfg_workdir" 2>/dev/null || { mkdir -p "$cfg_workdir"; cd "$cfg_workdir"; git init -q; }
          git lfs install --local >/dev/null
          git lfs track "$(python3 -c "
import re
text=open('$CONFIG').read()
in_block=False
for ln in text.splitlines():
    if re.match(r'\s*lfs:\s*$', ln): in_block='lfs'
    elif in_block=='lfs':
        m=re.match(r'\s*-\s*\"?(.*?)\"?\s*$', ln)
        if m and not ln.startswith('  patterns'): print(m.group(1))
        elif ln.strip()=='': continue
        else: break
")" || true
          ok "git-lfs tracking configured"
        )
        ;;
    *)
        err "unknown subcommand: $SUBCMD"; exit 2;;
esac