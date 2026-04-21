# subtract bash hook
# sources shared handler, sets up bash-specific hooks
[ -f ~/.subtract/subtract.sh ] && source ~/.subtract/subtract.sh

# capture last command output before each prompt
PROMPT_COMMAND="__subtract_capture;${PROMPT_COMMAND:+$PROMPT_COMMAND}"

# bash command-not-found hook
command_not_found_handle() {
    __subtract_handle "$@"
}
