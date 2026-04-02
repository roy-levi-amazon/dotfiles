source ~/.zsh_common

# Brew (Mac)
eval "$(/opt/homebrew/bin/brew shellenv)"

# VSCode
export PATH="$PATH:/Applications/Visual Studio Code.app/Contents/Resources/app/bin"
alias c='code'

# Github switch user
function update_gh_user_cache() {
    local cache_file="$HOME/.cache/gh_user"
    mkdir -p "$(dirname "$cache_file")"
    gh api user --jq .login > "$cache_file"
}
alias ghs='function _switchGhUser(){ gh auth switch; update_gh_user_cache; }; _switchGhUser'

# Activate virtual env and save the path as a tmux variable
function sv() {
    if [ -n "$VIRTUAL_ENV" ]; then
        tmux set-environment VIRTUAL_ENV $VIRTUAL_ENV
        alias deactivate='\deactivate && tmux set-environment -u VIRTUAL_ENV && unalias deactivate'
    fi
}
if [ -n "$VIRTUAL_ENV" ]; then
    source $VIRTUAL_ENV/bin/activate;
fi
