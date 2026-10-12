#!/usr/bin/env bash
# Claude Code status line: phone-first, one line, progressive disclosure.
#
#   repo F5.1 medium c●31 5●40 7●59       every gauge: dot plus percentage used
#   repo F5.1 medium c●31 5●95·38m 7●59   over CRIT, or a reset within the hour, adds the reset
#
# Gauges: c = context used, 5 = 5-hour limit, 7 = 7-day limit.
# The dot is the same glyph at every level; its colour carries the level:
# grey below LOW, green from LOW, yellow from MID, orange from WARN, bold red from CRIT.
# Wide pane (COLUMNS > STATUSLINE_WIDE) or `touch ~/.claude/statusline.full`:
# every gauge also shows its reset. If the details do not fit on one line,
# they move to a second line so the first stays short.
export LC_ALL=C.UTF-8
input=$(cat)

LOW=${STATUSLINE_LOW:-25}
MID=${STATUSLINE_MID:-50}
WARN=${STATUSLINE_WARN:-75}
CRIT=${STATUSLINE_CRIT:-90}
WIDE=${STATUSLINE_WIDE:-100}
cols=${COLUMNS:-80}

# One jq pass; fields joined by \x1f so empty values keep their position.
IFS=$'\x1f' read -r cwd model_name model_id effort ctx h5 h5r d7 d7r < <(
  echo "$input" | jq -r '[
    (.workspace.current_dir // .cwd // ""),
    (.model.display_name // ""), (.model.id // ""), (.effort.level // ""),
    (.context_window.used_percentage // "" | tostring),
    (.rate_limits.five_hour.used_percentage // "" | tostring),
    (.rate_limits.five_hour.resets_at // "" | tostring),
    (.rate_limits.seven_day.used_percentage // "" | tostring),
    (.rate_limits.seven_day.resets_at // "" | tostring)
  ] | join("\u001f")'
)

esc() { printf '\033[%sm' "$1"; }
C_DIR=$(esc "1;34"); C_BRANCH=$(esc "1;35"); C_DIRTY=$(esc "31"); C_DIM=$(esc "90")
C_OK=$(esc "32"); C_MID=$(esc "33"); C_WARN=$(esc "38;5;208"); C_CRIT=$(esc "1;31"); RESET=$(esc "0")

full=""
{ [ "$cols" -gt "$WIDE" ] || [ -e ~/.claude/statusline.full ]; } && full=1
now=$(date +%s)

# ---------------------------------------------------------------------------
# Location: cwd basename, branch only when not main/master, * when dirty
# ---------------------------------------------------------------------------
loc="${C_DIR}${cwd##*/}${RESET}"
loc_plain="${cwd##*/}"
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  case "$branch" in
    main|master|"") ;;
    *) loc="${loc} ${C_BRANCH}${branch}${RESET}"; loc_plain="${loc_plain} ${branch}" ;;
  esac
  if git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | grep -q .; then
    loc="${loc}${C_DIRTY}*${RESET}"; loc_plain="${loc_plain}*"
  fi
fi

# ---------------------------------------------------------------------------
# Model tag: "Fable 5.1" -> F5.1, "Opus 5.5" -> O5.5, "Sonnet 5" -> S5
# ---------------------------------------------------------------------------
model_name=${model_name/ (1M context)/}
tag=""
if [ -n "$model_name" ]; then
  ver=$(printf '%s' "$model_name" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)
  tag="${model_name:0:1}${ver}"
  [ -z "$ver" ] && tag="${model_name:0:6}"
fi
is_fable=""
case "$(printf '%s%s' "$model_id" "$model_name" | tr '[:upper:]' '[:lower:]')" in
  *fable*) is_fable=1 ;;
esac

# ---------------------------------------------------------------------------
# Gauges
# ---------------------------------------------------------------------------
# One code point for every gauge and level: no fill-level glyph set (pies,
# quadrants, squares) drew at one size on the phone in JetBrains Mono or Fira Code.
DOT=●

countdown() {  # seconds -> 38m | 3h58m | 3d0h
  local s=$1
  if   [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s / 86400)) $(((s % 86400) / 3600))
  elif [ "$s" -ge 3600 ];  then printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60))
  else                          printf '%dm' $((s / 60))
  fi
}

# gauge <tag> <name> <pct> [resets_at]: records the glyph, and the number when it matters
G_GLYPH=(); G_NUM=(); G_NAME=(); plain=0
gauge() {
  local tag=$1 name=$2 pct reset=$4 color num="" left=""
  pct=$(printf '%.0f' "$3")
  if   [ "$pct" -ge "$CRIT" ]; then color=$C_CRIT
  elif [ "$pct" -ge "$WARN" ]; then color=$C_WARN
  elif [ "$pct" -ge "$MID" ];  then color=$C_MID
  elif [ "$pct" -ge "$LOW" ];  then color=$C_OK
  else                              color=$C_DIM
  fi
  [ -n "$reset" ] && [ "$reset" -gt "$now" ] && left=$(( reset - now ))
  num="${pct}"   # always shown: the colour alone was not readable
  if [ -n "$left" ] && { [ -n "$full" ] || [ "$pct" -ge "$CRIT" ] || [ "$left" -lt 3600 ]; }; then
    num="${pct}·$(countdown "$left")"
  fi
  G_GLYPH+=("${C_DIM}${tag}${RESET}${color}${DOT}${RESET}")
  G_NUM+=("${num:+${color}${num}${RESET}}")
  G_NAME+=("$name")
  plain=$(( plain + 3 + ${#num} ))   # " " + tag + glyph + number
}

[ -n "$ctx" ] && gauge c ctx "$ctx"
[ -n "$h5" ]  && gauge 5 5h "$h5" "$h5r"
if [ -n "$d7" ]; then
  # 7-day shows on Fable models, or on any model once it reaches WARN
  { [ -n "$is_fable" ] || [ "$(printf '%.0f' "$d7")" -ge "$WARN" ]; } && gauge 7 7d "$d7" "$d7r"
fi

head="${loc}"; width=${#loc_plain}
[ -n "$tag" ] && { head="${head} ${C_DIM}${tag}${RESET}"; width=$(( width + 1 + ${#tag} )); }
# Reasoning effort, unabbreviated (low medium high xhigh max); absent when the model has none
[ -n "$effort" ] && { head="${head} ${C_DIM}${effort}${RESET}"; width=$(( width + 1 + ${#effort} )); }

# Numbers inline when the line fits (Claude Code indents the row by 2, keep a
# margin); otherwise glyphs only on line one and the numbers on line two.
inline=""; glyphs=""; detail=""
for i in "${!G_GLYPH[@]}"; do
  inline="${inline} ${G_GLYPH[$i]}${G_NUM[$i]}"
  glyphs="${glyphs} ${G_GLYPH[$i]}"
  [ -n "${G_NUM[$i]}" ] && detail="${detail} ${C_DIM}${G_NAME[$i]}${RESET} ${G_NUM[$i]}"
done
if [ -z "$detail" ] || [ $(( width + plain )) -le $(( cols - 4 )) ]; then
  printf '%s\n' "${head}${inline}"
else
  printf '%s\n%s\n' "${head}${glyphs}" "${detail# }"
fi
