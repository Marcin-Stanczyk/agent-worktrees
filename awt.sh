# agent-worktrees — shell integration.
#
# WHY THIS IS A FILE AND NOT A SNIPPET IN THE README
# =================================================
# It used to be a snippet, in two places: a heredoc in `install.sh` and a code
# block in the README. They drifted. The installer kept parsing the old
# two-field protocol, so it read the extra arguments as the agent's NAME and ran
# them as a command — and since the README told you to start with `./install.sh`,
# the broken copy is the one every new person got. Whoever tested it had the good
# copy in their shell config already and never saw it.
#
# So there is one copy, it lives here, and `install.sh` symlinks it. `git pull`
# then updates the function along with the tool, exactly like the binary.
#
# WHY POSIX AND NOT BASH
# ======================
# The same file has to work in bash — including the 3.2 that macOS still ships —
# and in zsh, because `install.sh` picks between `.zshrc` and `.bashrc` depending
# on what it finds. An earlier version used zsh's `${=args}` to split arguments;
# in bash that is "bad substitution". Nothing here needs a shell extension.

awt() {
    # AWT_CLI is overridable so the test suite can point at a working copy
    # without installing over somebody's real one.
    : "${AWT_CLI:=$HOME/.local/bin/agent-worktrees}"

    # `new` AND `resume` ARE IN HERE TOO, and that is the whole point of it
    # being here. Both hand back a directory to `cd` into, so both take this
    # branch. Every other subcommand (`list`, `where`, `clean`, ...) prints for
    # a human and needs nothing from the shell, so it goes straight through.
    case "${1:-start}" in
        start|""|new|resume)
            # A process cannot change its parent shell's directory. So the script
            # hands us the path and we do the `cd` here — which is also why you
            # stay in the session after the agent exits.
            # `local` is the single non-POSIX construct here, and it is worth
            # it: bash, zsh, dash and ksh all support it, and the alternative is
            # leaking four variables into somebody's interactive shell on every
            # session.
            local awt_out awt_line awt_dir awt_agent
            # The 2 is the protocol version, not a boolean. The tool refuses to
            # answer a wrapper that speaks an older one rather than emitting a
            # reply it knows will be mishandled — which is what happened, in
            # silence, when the format last changed.
            # "$@" rather than a literal `start`: the same branch now serves
            # `new <name> [base]` and `resume [name]`, and those arguments have
            # to reach the tool. With no arguments at all "$@" expands to
            # nothing and the tool defaults to the survey, which is what `awt`
            # on its own means.
            awt_out="$(AWT_WRAPPER=2 "$AWT_CLI" "$@")" || return 1

            # ONE FIELD PER LINE: directory, agent, then one argument per line.
            # Read into the positional parameters a line at a time, so no shell
            # word-splitting is involved and an argument with a space in it
            # survives. `set --` inside a function sets that function's
            # parameters, and a `while` loop with a heredoc is not a subshell, so
            # the values are still here afterwards.
            set --
            while IFS= read -r awt_line; do
                set -- "$@" "$awt_line"
            done <<AWT_FIELDS
$awt_out
AWT_FIELDS

            if [ "$#" -lt 2 ]; then
                printf '%s\n' "awt: the tool returned nothing usable — aborting." >&2
                return 1
            fi

            awt_dir="$1"; shift
            awt_agent="$1"; shift

            cd "$awt_dir" || return 1
            [ "$awt_agent" = "plain shell" ] && return 0
            "$awt_agent" "$@"
            ;;
        *)
            "$AWT_CLI" "$@"
            ;;
    esac
}
