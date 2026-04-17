# subtract bash hook
# sources shared handler, sets up bash-specific hooks
[ -f ~/.subtract/handler.sh ] && source ~/.subtract/handler.sh

# capture last command output before each prompt
PROMPT_COMMAND="__subtract_capture;${PROMPT_COMMAND:+$PROMPT_COMMAND}"

# bash command-not-found hook
command_not_found_handle() {
    __subtract_handle "$@"
}

# add subtract binaries to PATH
export PATH="$HOME/.subtract/bin:$PATH"
