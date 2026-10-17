#!/usr/bin/env bash
# Copies skills/* into ~/.agents/skills and symlinks each one into ~/.claude/skills for Claude Code.
set -euo pipefail
cd "$(dirname "$0")"
dest="${AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
claude_dest="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
mkdir -p "$dest" "$claude_dest"
dest="$(cd "$dest" && pwd)"   # symlinks need an absolute target
for s in skills/*/; do
  name="$(basename "$s")"
  rm -rf "$dest/$name.new" && cp -R "$s" "$dest/$name.new"
  rm -rf "$dest/$name" && mv "$dest/$name.new" "$dest/$name"
  if [ "$(cd "$claude_dest" && pwd -P)" != "$(cd "$dest" && pwd -P)" ]; then
    rm -rf "$claude_dest/$name" && ln -s "$dest/$name" "$claude_dest/$name"
  fi
  echo "installed $name"
done
