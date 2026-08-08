#!/usr/bin/env bash
#
# Installs a symlink into ~/.local/bin and one into ~/.local/share, then prints
# the single line to add to your shell config.
#
# Symlinks rather than copies: `git pull` in this repository then updates the
# tool AND the shell function everywhere at once, with no reinstall step to
# remember — and, more importantly, no second copy of the shell function to drift
# out of step with the protocol the tool speaks. That drift is not hypothetical:
# this installer used to carry its own copy of the function, fell a protocol
# version behind, and handed every new user a wrapper that ran the agent's
# arguments as if they were the agent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/agent-worktrees.sh"
FUNC_SOURCE="$HERE/awt.sh"
TARGET="$HOME/.local/bin/agent-worktrees"
FUNC_TARGET="$HOME/.local/share/agent-worktrees/awt.sh"

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/agent-worktrees"
ln -sf "$SOURCE" "$TARGET"
ln -sf "$FUNC_SOURCE" "$FUNC_TARGET"
chmod +x "$SOURCE"
echo "✓ $TARGET -> $SOURCE"
echo "✓ $FUNC_TARGET -> $FUNC_SOURCE"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
        echo
        echo "⚠  ~/.local/bin is not in your PATH. Add this to your shell config:"
        echo '     export PATH="$HOME/.local/bin:$PATH"'
        ;;
esac

# Herdr is OPTIONAL and stays that way. It is reported, not demanded: without it
# every command still works, the session simply does not open in a window of its
# own. Turning this into a prompt would make an optional dependency compulsory
# and cost the tool the portability that is its whole point — and a prompt is
# unsafe here anyway, because stdout carries the protocol the shell function
# parses.
if ! command -v herdr >/dev/null 2>&1; then
    echo
    echo "ℹ  herdr is not on your PATH — that is fine, and nothing here needs it."
    echo "   Sessions will be created exactly as usual; they just will not open"
    echo "   in a window by themselves. 'agent-worktrees verify' says so too."
fi

RC="${ZDOTDIR:-$HOME}/.zshrc"
[[ -f "$RC" ]] || RC="$HOME/.bashrc"

LINE="[ -f \"\$HOME/.local/share/agent-worktrees/awt.sh\" ] && . \"\$HOME/.local/share/agent-worktrees/awt.sh\""

if grep -q 'agent-worktrees/awt.sh' "$RC" 2>/dev/null; then
    echo "✓ shell function already sourced from $(basename "$RC")"
    exit 0
fi

if grep -q 'agent-worktrees' "$RC" 2>/dev/null; then
    echo
    echo "⚠  $(basename "$RC") mentions agent-worktrees already — probably an older"
    echo "   pasted-in copy of the awt() function. DELETE IT and use the line below;"
    echo "   the pasted copies cannot follow changes to the protocol."
fi

cat <<BLOCK

Add this ONE line to your shell config ($(basename "$RC")). It sources a
function — not an alias — because only a function can change the current
shell's directory, and an alias cannot capture the tool's output.

$LINE

BLOCK
