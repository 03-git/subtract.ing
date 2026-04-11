# subtract zsh hook
# sources shared handler, sets up zsh-specific hooks
[ -f ~/.subtract/handler.sh ] && source ~/.subtract/handler.sh

# capture last command output before each prompt
precmd_functions+=(__subtract_capture)

# zsh command-not-found hook
# return 0 unconditionally: zsh prints "command not found" on non-zero
command_not_found_handler() {
    __subtract_handle "$@"
    return 0
}
