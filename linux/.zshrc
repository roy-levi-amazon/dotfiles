source ~/.zsh_common

# Brew (Linux)
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv zsh)"

# Linux-specific env
export BRAZIL_WORKSPACE_DEFAULT_LAYOUT=short
export AWS_EC2_METADATA_DISABLED=true
export AUTO_TITLE_SCREENS="NO"

# Apollo / Path
export PATH="/apollo/env/AmazonAwsCli/bin:$PATH"
export PATH="/apollo/env/GDBStandalone/bin:$PATH"
export PATH="/apollo/env/envImprovement/bin:$PATH"
export PATH="$HOME/projects/SuperCrux/src/SuperCrux/bin:$PATH"

# Fix VSCode 'code' command
code() {
  export VSCODE_IPC_HOOK_CLI=$(ls -tr /run/user/$UID/vscode-ipc-* 2>/dev/null | tail -n 1)
  local code_bin
  code_bin=$(ls -t $HOME/.vscode-server/cli/servers/Stable-*/server/bin/remote-cli/code 2>/dev/null | head -n 1)
  if [[ -n "$code_bin" && -x "$code_bin" ]]; then
    "$code_bin" "$@"
  else
    echo "Error: No VS Code Server 'code' binary found." >&2
    return 1
  fi
}
alias c='code'

# Fix Kiro 'kiro' command
kiro() {
  export VSCODE_IPC_HOOK_CLI=$(ls -tr /tmp/vscode-ipc-* 2>/dev/null | tail -n 1)
  kiro_bin=$(ls -t $HOME/.kiro-server/bin/*/bin/remote-cli/kiro 2>/dev/null | head -n 1)
  if [[ -n "$kiro_bin" && -x "$kiro_bin" ]]; then
    "$kiro_bin" "$@"
  else
    echo "Error: No Kiro Server 'kiro' binary found." >&2
    return 1
  fi
}
alias k='kiro'

# CR
alias crm='cr --amend'
alias cra='cr --all'

# SSH title
set-title() { echo -e "\e]0;$*\007"; }
ssh() { set-title $*; /usr/bin/ssh -2 $*; set-title $HOST; }

# Seatbelt / Brazil scripts
alias seatbelt=/apollo/env/EC2SeatbeltCLI/bin/seatbelt.rb
alias mw='/home/roylevi/scripts/mwinit.sh'

# Notification system
_send_notification() {
    echo "Command '$1' finished with exit code: $2 (took $3s)" | ncat localhost 9999 2>/dev/null || true
}
notify() {
    local start=$SECONDS
    "$@"
    local exit_code=$?
    _send_notification "$*" "$exit_code" $((SECONDS - start))
    return $exit_code
}
_command_start_time=0
_current_command=""
_last_exit_code=0
_record_start_time() { _command_start_time=$SECONDS; _current_command="$1"; }
_notify_after_command() {
    _last_exit_code=$?
    local duration=$((SECONDS - _command_start_time))
    [ $duration -ge 5 ] && [ -n "$_current_command" ] && _send_notification "$_current_command" "$_last_exit_code" "$duration"
    _current_command=""
}
autoload -Uz add-zsh-hook
[[ ! " ${preexec_functions[@]} " =~ " _record_start_time " ]] && add-zsh-hook preexec _record_start_time
[[ ! " ${precmd_functions[@]} " =~ " _notify_after_command " ]] && add-zsh-hook precmd _notify_after_command

# 2 Network Interfaces for L1
setup_network_for_l1() {
    local l1_ip=$(ip addr show lo | grep -oP '169\.254\.\d+\.\d+(?=/32)')
    [ -z "$l1_ip" ] && return 1
    sudo ip addr add 127.0.0.2/8 dev lo label lo:2
    sudo ip addr del "$l1_ip/32" dev lo
    sudo ip addr add "$l1_ip/32" dev lo label lo:1
}
cleanup_network_for_l1() {
    local l1_ip=$(ip addr show lo | grep -oP '169\.254\.\d+\.\d+(?=/32)')
    ip addr show lo | grep -q "127.0.0.2" && sudo ip addr del 127.0.0.2/8 dev lo 2>/dev/null
    [ -n "$l1_ip" ] && sudo ip addr del "$l1_ip/32" dev lo 2>/dev/null && sudo ip addr add "$l1_ip/32" dev lo 2>/dev/null
}
alias l1ns=setup_network_for_l1
alias l1nc=cleanup_network_for_l1

# ET Quick Access
et() {
    local force_artifacts="--force-artifacts"
    local s3_flag="--no-s3"
    local args=()

    for arg in "$@"; do
        case "$arg" in
            -nf) force_artifacts="" ;;
            -s3) s3_flag="" ;;
            *) args+=("$arg") ;;
        esac
    done

    ./ebs-test run --slack-interval 5m $s3_flag --logs ./latest-test --config /home/roylevi/.config/ebs_test.json $force_artifacts "${args[@]}"
}
alias etf='et -nf --force-aws --parallel 250'
alias eta='et --aws-auto aws.yaml'
alias eti='et --idm-auto idm.yaml'
alias etpac='./ebs-test ash-create -o ash-pool.yaml'
alias etpa='et --hardware-platform ash --ash-setup ash-pool.yaml'
alias etplc='./ebs-test lego-create -o lego-pool.yaml'
alias etpl='et --hardware-platform lego --lego-setup lego-pool.yaml'
alias eth='./ebs-test --help'
alias etc='./ebs-test cleanup'
alias etl='./ebs-test list'
alias etd='./ebs-test download-test-artifacts --dest ./latest-test'
alias fb='./fast_build.sh'

# lnav for EbsServerTest results
etlogf() {
    local folder_path="${1}"; shift; local lnav_args=("$@")
    [ -z "$folder_path" ] && { echo "Usage: etlogf <folder_path> [lnav-options]" >&2; return 1; }
    [ ! -d "$folder_path" ] && { echo "Directory not found: $folder_path" >&2; return 1; }
    find "$folder_path" -type f \
        \( -name "test.log" -o \
           -path "*/artifacts/server-*/var/log/ebs_server/ebs-server.log*" -o \
           -path "*/artifacts/server-*/var/log/ebs_server/control-plane.log*" \) \
        2>/dev/null | xargs lnav "${lnav_args[@]}"
}
etlog() {
    local session="${1}" test_name="${2}" test_num="${3}" lnav_args=()
    if [[ "$test_num" == "--" ]] || [[ "$test_num" == -* ]] || [[ -z "$test_num" ]]; then
        test_num="*"; shift 2; lnav_args=("$@")
    else
        shift 3; lnav_args=("$@")
    fi
    [ -z "$session" ] || [ -z "$test_name" ] && {
        echo "Usage: etlog <session> <test_name> [test_number] [lnav-options]"; return 1
    }
    local session_dir=$(find ./latest-test -mindepth 1 -maxdepth 1 -type d -name "*${session}*" 2>/dev/null | head -n1)
    [ -z "$session_dir" ] && { echo "No session found matching: $session"; return 1; }
    local test_dir=$(find "$session_dir" -type d -path "*/${test_name}*/${test_num}" 2>/dev/null | head -n1)
    [ -z "$test_dir" ] && { echo "No test directory found for: $test_name/$test_num"; return 1; }
    etlogf "$test_dir" "${lnav_args[@]}"
}
etlogl() {
    local latest=$(find ./latest-test -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -n1 | xargs basename)
    echo "Using: $latest"; etlog "$latest" "$@"
}

# etlog completions
_etlog_completion() {
    local -a options
    case $CURRENT in
        2) options=(${(f)"$(find ./latest-test -mindepth 1 -maxdepth 1 -type d 2>/dev/null | xargs -r -n1 basename)"})
           _describe 'sessions' options ;;
        3) local session_dir=$(find ./latest-test -mindepth 1 -maxdepth 1 -type d -name "*${words[2]}*" 2>/dev/null | head -n1)
           [[ -n "$session_dir" ]] && options=(${(f)"$(find "$session_dir" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | xargs -r -n1 basename | sort -u)"})
           _describe 'test names' options ;;
        4) local session_dir=$(find ./latest-test -mindepth 1 -maxdepth 1 -type d -name "*${words[2]}*" 2>/dev/null | head -n1)
           [[ -n "$session_dir" ]] && options=(${(f)"$(find "$session_dir" -type d -path "*/${words[3]}/*" 2>/dev/null | grep -oP '/\d{3}$' | sed 's|/||' | sort -u)"})
           _describe 'test numbers' options ;;
    esac
}
_etlogl_completion() {
    local -a options
    local latest=$(find ./latest-test -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -n1)
    case $CURRENT in
        2) [[ -n "$latest" ]] && options=(${(f)"$(find "$latest" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | xargs -r -n1 basename | sort -u)"})
           _describe 'test names' options ;;
        3) [[ -n "$latest" ]] && options=(${(f)"$(find "$latest" -type d -path "*/${words[2]}/*" 2>/dev/null | grep -oP '/\d{3}$' | sed 's|/||' | sort -u)"})
           _describe 'test numbers' options ;;
    esac
}
compdef _etlog_completion etlog
compdef _etlogl_completion etlogl

# C++ LSP helper
cpplsp() {
  brazil-build $@ --print-directory --dry-run --always-make > /tmp/out.txt
  compiledb --parse /tmp/out.txt --overwrite --no-strict --output ./compile_commands.json
  sed -i 's|"directory": "\(/local/home/roylevi/projects/[^/]*/src/[^/]*\)"|"directory": "\1/src"|g' ./compile_commands.json
  PROJECT=$(pwd | grep -oP '(?<=projects/)[^/]+')
  sed -i "s|x86_64-pc-linux-gnu-g++|/local/home/roylevi/projects/$PROJECT/env/CFlags-1.0/runtime/bin/x86_64-pc-linux-gnu-g++|g" ./compile_commands.json
  cp ~/projects/.clangd ./
}

# Ruby LSP helper
rubylsp() { find -L ~/.local/share/mise -name "ruby_indexer"; }
