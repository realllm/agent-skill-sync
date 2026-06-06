#!/usr/bin/env bash
set -euo pipefail

CLAUDE_SKILLS="$HOME/.claude/skills"
CODEX_SKILLS="$HOME/.codex/skills"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/sync-skills.state.tsv"
PREFER="Claude"
DRY_RUN=0
QUIET=0
FORCE=0
FILES_COPIED=0
CONFLICTS=0
SKILLS_TOUCHED_FILE="$(mktemp)"

cleanup() {
    rm -f "$SKILLS_TOUCHED_FILE"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./sync-skills.sh [options]

Options:
  --claude-skills PATH   Claude Code skills directory
  --codex-skills PATH    Codex skills directory
  --state-file PATH      Sync state file path
  --dry-run              Preview changes without copying
  --quiet                Reduce output
  --force                Resolve conflicts by overwriting one side
  --prefer claude|codex  Side to keep when --force is used
  -h, --help             Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --claude-skills)
            CLAUDE_SKILLS="$2"
            shift 2
            ;;
        --codex-skills)
            CODEX_SKILLS="$2"
            shift 2
            ;;
        --state-file)
            STATE_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --prefer)
            case "${2:-}" in
                claude|Claude)
                    PREFER="Claude"
                    ;;
                codex|Codex)
                    PREFER="Codex"
                    ;;
                *)
                    echo "Invalid --prefer value: ${2:-}" >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

write_info() {
    if [ "$QUIET" -eq 0 ]; then
        printf '%s\n' "$1"
    fi
}

ensure_dir() {
    if [ ! -d "$1" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            write_info "[dry-run] create directory: $1"
        else
            mkdir -p "$1"
        fi
    fi
}

hash_file() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

mtime() {
    if stat -f %m "$1" >/dev/null 2>&1; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}

state_key() {
    printf '%s/%s' "$1" "$2"
}

state_lookup() {
    local key="$1"
    if [ ! -f "$STATE_FILE" ]; then
        return 1
    fi

    awk -F '\t' -v key="$key" '$1 == key { value = $2 } END { if (value != "") print value; else exit 1 }' "$STATE_FILE"
}

relative_files() {
    local root="$1"
    if [ ! -d "$root" ]; then
        return 0
    fi

    (cd "$root" && find . -type f | sed 's#^\./##' | sort)
}

skill_names() {
    {
        if [ -d "$CLAUDE_SKILLS" ]; then
            find "$CLAUDE_SKILLS" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
                [ -f "$dir/SKILL.md" ] && basename "$dir"
            done
        fi
        if [ -d "$CODEX_SKILLS" ]; then
            find "$CODEX_SKILLS" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
                name="$(basename "$dir")"
                [ "$name" = ".system" ] && continue
                [ -f "$dir/SKILL.md" ] && printf '%s\n' "$name"
            done
        fi
    } | sort -u
}

copy_skill_file() {
    local source_file="$1"
    local destination_file="$2"
    local reason="$3"

    if [ "$DRY_RUN" -eq 1 ]; then
        write_info "[dry-run] copy ($reason): $source_file -> $destination_file"
    else
        mkdir -p "$(dirname "$destination_file")"
        cp -p "$source_file" "$destination_file"
    fi

    FILES_COPIED=$((FILES_COPIED + 1))
}

sync_one_skill() {
    local skill_name="$1"
    local claude_skill="$CLAUDE_SKILLS/$skill_name"
    local codex_skill="$CODEX_SKILLS/$skill_name"
    local claude_list codex_list all_list
    local changed=0

    claude_list="$(mktemp)"
    codex_list="$(mktemp)"
    all_list="$(mktemp)"
    relative_files "$claude_skill" > "$claude_list"
    relative_files "$codex_skill" > "$codex_list"
    cat "$claude_list" "$codex_list" | sort -u > "$all_list"

    while IFS= read -r relative; do
        [ -z "$relative" ] && continue

        local claude_file="$claude_skill/$relative"
        local codex_file="$codex_skill/$relative"
        local claude_exists=0
        local codex_exists=0

        [ -f "$claude_file" ] && claude_exists=1
        [ -f "$codex_file" ] && codex_exists=1

        if [ "$claude_exists" -eq 1 ] && [ "$codex_exists" -eq 0 ]; then
            ensure_dir "$codex_skill"
            copy_skill_file "$claude_file" "$codex_file" "Claude new"
            changed=$((changed + 1))
            continue
        fi

        if [ "$codex_exists" -eq 1 ] && [ "$claude_exists" -eq 0 ]; then
            ensure_dir "$claude_skill"
            copy_skill_file "$codex_file" "$claude_file" "Codex new"
            changed=$((changed + 1))
            continue
        fi

        if [ "$claude_exists" -eq 0 ] || [ "$codex_exists" -eq 0 ]; then
            continue
        fi

        local claude_hash codex_hash
        claude_hash="$(hash_file "$claude_file")"
        codex_hash="$(hash_file "$codex_file")"

        if [ "$claude_hash" = "$codex_hash" ]; then
            continue
        fi

        local key previous_hash has_previous=0
        local claude_changed=0 codex_changed=0 is_conflict=0
        local claude_time codex_time
        key="$(state_key "$skill_name" "$relative")"
        previous_hash="$(state_lookup "$key" || true)"
        if [ -n "$previous_hash" ]; then
            has_previous=1
        fi

        if [ "$has_previous" -eq 1 ] && [ "$claude_hash" != "$previous_hash" ]; then
            claude_changed=1
        fi
        if [ "$has_previous" -eq 1 ] && [ "$codex_hash" != "$previous_hash" ]; then
            codex_changed=1
        fi

        claude_time="$(mtime "$claude_file")"
        codex_time="$(mtime "$codex_file")"

        if [ "$claude_changed" -eq 1 ] && [ "$codex_changed" -eq 1 ]; then
            is_conflict=1
        elif [ "$has_previous" -eq 0 ] && [ "$claude_time" = "$codex_time" ]; then
            is_conflict=1
        fi

        if [ "$is_conflict" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
            CONFLICTS=$((CONFLICTS + 1))
            write_info "[conflict] skipped: $skill_name/$relative"
            write_info "           use --force --prefer claude or --force --prefer codex to choose a side"
            continue
        fi

        if [ "$is_conflict" -eq 1 ] && [ "$FORCE" -eq 1 ]; then
            if [ "$PREFER" = "Claude" ]; then
                copy_skill_file "$claude_file" "$codex_file" "conflict forced from Claude"
            else
                copy_skill_file "$codex_file" "$claude_file" "conflict forced from Codex"
            fi
            changed=$((changed + 1))
            continue
        fi

        if [ "$claude_time" -gt "$codex_time" ]; then
            copy_skill_file "$claude_file" "$codex_file" "Claude newer"
            changed=$((changed + 1))
        elif [ "$codex_time" -gt "$claude_time" ]; then
            copy_skill_file "$codex_file" "$claude_file" "Codex newer"
            changed=$((changed + 1))
        else
            CONFLICTS=$((CONFLICTS + 1))
            write_info "[conflict] skipped: $skill_name/$relative"
            write_info "           same timestamp but different content; use --force --prefer claude or --force --prefer codex"
        fi
    done < "$all_list"

    rm -f "$claude_list" "$codex_list" "$all_list"

    if [ "$changed" -gt 0 ]; then
        printf '%s\n' "$skill_name" >> "$SKILLS_TOUCHED_FILE"
        write_info "Synced: $skill_name ($changed files)"
    fi
}

write_state() {
    local tmp_state
    tmp_state="$(mktemp)"

    skill_names | while IFS= read -r skill_name; do
        [ -z "$skill_name" ] && continue
        local claude_skill="$CLAUDE_SKILLS/$skill_name"
        local codex_skill="$CODEX_SKILLS/$skill_name"

        relative_files "$claude_skill" | while IFS= read -r relative; do
            [ -z "$relative" ] && continue
            local claude_file="$claude_skill/$relative"
            local codex_file="$codex_skill/$relative"
            if [ -f "$claude_file" ] && [ -f "$codex_file" ]; then
                local claude_hash codex_hash
                claude_hash="$(hash_file "$claude_file")"
                codex_hash="$(hash_file "$codex_file")"
                if [ "$claude_hash" = "$codex_hash" ]; then
                    printf '%s\t%s\n' "$(state_key "$skill_name" "$relative")" "$claude_hash"
                fi
            fi
        done
    done | sort > "$tmp_state"

    if [ "$DRY_RUN" -eq 1 ]; then
        write_info "[dry-run] update state file: $STATE_FILE"
        rm -f "$tmp_state"
        return
    fi

    mkdir -p "$(dirname "$STATE_FILE")"
    mv "$tmp_state" "$STATE_FILE"
}

ensure_dir "$CLAUDE_SKILLS"
ensure_dir "$CODEX_SKILLS"

write_info "Syncing skills:"
write_info "  Claude: $CLAUDE_SKILLS"
write_info "  Codex : $CODEX_SKILLS"
write_info "  State : $STATE_FILE"
if [ "$FORCE" -eq 1 ]; then
    write_info "  Mode  : Force, prefer $PREFER on conflicts"
fi
write_info ""

SKILL_NAMES_FILE="$(mktemp)"
skill_names > "$SKILL_NAMES_FILE"

while IFS= read -r skill_name; do
    [ -z "$skill_name" ] && continue
    sync_one_skill "$skill_name"
done < "$SKILL_NAMES_FILE"

rm -f "$SKILL_NAMES_FILE"

write_state

write_info ""
if [ "$FILES_COPIED" -eq 0 ]; then
    write_info "Done. No files needed syncing."
else
    skill_count="$(sort -u "$SKILLS_TOUCHED_FILE" | wc -l | tr -d ' ')"
    write_info "Done. Synced $FILES_COPIED file(s) across $skill_count skill(s)."
fi

if [ "$CONFLICTS" -gt 0 ]; then
    write_info "Skipped $CONFLICTS conflict(s). Re-run with --force --prefer claude or --force --prefer codex after reviewing."
fi
write_info "Restart Claude Code or Codex if you need newly added skills to be picked up."
