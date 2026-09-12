#!/usr/bin/env bash
# Claude Code status line — 1-line layout using terminal's own 16-color palette
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')

# ---------------------------------------------------------------------------
# ANSI helpers — TMUX-safe
# When running inside TMUX, escape sequences must be wrapped in a DCS passthrough
# so TMUX forwards them to the outer terminal instead of swallowing them.
# ---------------------------------------------------------------------------
if [ -n "$TMUX" ]; then
  esc() { printf '\033Ptmux;\033\033[%sm\033\\' "$1"; }
else
  esc() { printf '\033[%sm' "$1"; }
fi

# Standard ANSI 16-color codes — map to whatever palette Windows Terminal has set
C_DIR=$(esc "1;34")        # bold blue   → directory
C_BRANCH=$(esc "1;35")     # bold magenta → git branch
C_DIRTY=$(esc "31")        # red          → dirty marker
C_CTX_GREEN=$(esc "32")    # green
C_CTX_YELLOW=$(esc "33")   # yellow
C_CTX_RED=$(esc "31")      # red
C_RATE_5H=$(esc "36")      # cyan         → 5-hour rate limit
C_RATE_7D=$(esc "1;36")    # bold cyan    → 7-day (weekly) rate limit
C_MODEL=$(esc "90")        # bright black → model name
RESET=$(esc "0")
SEP=" "                    # group separator: single space
# ---------------------------------------------------------------------------
# Directory: last 3 path segments with …/ prefix
# ---------------------------------------------------------------------------
short_dir=$(echo "$cwd" | awk -F'/' '{
  n=NF
  if ($n == "") n--
  if (n <= 3) { print $0 }
  else { printf "…/%s/%s/%s", $(n-2), $(n-1), $n }
}')

# ---------------------------------------------------------------------------
# Git branch + dirty flag (bare * when dirty, no counts)
# ---------------------------------------------------------------------------
git_branch=""
git_dirty=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | grep -q .; then
    git_dirty="*"
  fi
fi

# ---------------------------------------------------------------------------
# Model: human-readable display name (drop " (1M context)" noise)
# ---------------------------------------------------------------------------
model_name=$(echo "$input" | jq -r '.model.display_name // empty')
model_name=${model_name/ (1M context)/}
model_id=$(echo "$input" | jq -r '.model.id // empty')
# Are we on a Fable model? (weekly limit is only surfaced for Fable)
is_fable=""
case "$(printf '%s%s' "$model_id" "$model_name" | tr '[:upper:]' '[:lower:]')" in
  *fable*) is_fable=1 ;;
esac

# ---------------------------------------------------------------------------
# Context window: fuel-gauge (used%, 0=fresh 100=full)
# ---------------------------------------------------------------------------
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_str="ctx:—"
ctx_color="${C_CTX_GREEN}"
if [ -n "$used_pct" ]; then
  used_int=$(printf "%.0f" "$used_pct")
  ctx_str="ctx:${used_int}%"
  if   [ "$used_int" -lt 50 ]; then ctx_color="${C_CTX_GREEN}"
  elif [ "$used_int" -lt 75 ]; then ctx_color="${C_CTX_YELLOW}"
  elif [ "$used_int" -lt 90 ]; then ctx_color="${C_CTX_YELLOW}"
  else                               ctx_color="${C_CTX_RED}"
  fi
fi

# ---------------------------------------------------------------------------
# 5-hour rate limit: usage% + countdown (omit if expired or absent)
# ---------------------------------------------------------------------------
five_h_str=""
five_h_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
if [ -n "$five_h_pct" ]; then
  pct_int=$(printf "%.0f" "$five_h_pct")
  countdown=""
  if [ -n "$five_h_reset" ]; then
    now=$(date +%s)
    secs_left=$(( five_h_reset - now ))
    if [ "$secs_left" -gt 0 ]; then
      hrs=$(( secs_left / 3600 ))
      mins=$(( (secs_left % 3600) / 60 ))
      if [ "$hrs" -gt 0 ]; then
        countdown=" (${hrs}h${mins}m)"
      else
        countdown=" (${mins}m)"
      fi
    fi
  fi
  five_h_str="5h:${pct_int}%${countdown}"
fi

# ---------------------------------------------------------------------------
# 7-day (weekly) rate limit: usage% + countdown — only when on a Fable model
# (omit if expired, absent, or not on Fable)
# ---------------------------------------------------------------------------
seven_d_str=""
seven_d_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
if [ -n "$is_fable" ] && [ -n "$seven_d_pct" ]; then
  pct7_int=$(printf "%.0f" "$seven_d_pct")
  countdown7=""
  if [ -n "$seven_d_reset" ]; then
    now7=$(date +%s)
    secs7_left=$(( seven_d_reset - now7 ))
    if [ "$secs7_left" -gt 0 ]; then
      days7=$(( secs7_left / 86400 ))
      hrs7=$(( (secs7_left % 86400) / 3600 ))
      mins7=$(( (secs7_left % 3600) / 60 ))
      if [ "$days7" -gt 0 ]; then
        countdown7=" (${days7}d${hrs7}h)"
      elif [ "$hrs7" -gt 0 ]; then
        countdown7=" (${hrs7}h${mins7}m)"
      else
        countdown7=" (${mins7}m)"
      fi
    fi
  fi
  seven_d_str="7d:${pct7_int}%${countdown7}"
fi

# ---------------------------------------------------------------------------
# Line 1: dir  branch*  model  ctx:%  5h:% countdown  7d:% countdown
# Colors are pre-rendered bytes from esc(); use printf without %b.
# ---------------------------------------------------------------------------
# Location group: dir + optional branch/dirty (kept together, space-joined)
loc="${C_DIR}${short_dir}${RESET}"
if [ -n "$git_branch" ]; then
  loc="${loc} ${C_BRANCH}${git_branch}${RESET}"
  [ -n "$git_dirty" ] && loc="${loc}${C_DIRTY}${git_dirty}${RESET}"
fi

# Collect the groups that are present, in order.
segs=("$loc")
[ -n "$model_name" ] && segs+=("${C_MODEL}${model_name}${RESET}")
segs+=("${ctx_color}${ctx_str}${RESET}")
[ -n "$five_h_str" ] && segs+=("${C_RATE_5H}${five_h_str}${RESET}")
[ -n "$seven_d_str" ] && segs+=("${C_RATE_7D}${seven_d_str}${RESET}")

# Join groups with the separator; within a limit group the % and its
# countdown stay space-joined so they read as one unit.
out="${segs[0]}"
for i in "${segs[@]:1}"; do
  out="${out}${SEP}${i}"
done
printf "%s\n" "$out"
