#!/bin/bash
while IFS= read -r line; do
    if [[ $line =~ Command\ \'([^\']+)\'\ finished\ with\ exit\ code:\ ([0-9]+)\ \(took\ ([0-9]+)s\) ]]; then
        full_cmd="${BASH_REMATCH[1]}"
        exit_code="${BASH_REMATCH[2]}"
        duration="${BASH_REMATCH[3]}"
        cmd_name="${full_cmd%% *}"
        
        if [ "$exit_code" -eq 0 ]; then
            sound="Blow"
            icon="✅"
        else
            sound="Glass"
            icon="❌"
        fi
        
        /Applications/terminal-notifier-code.app/Contents/MacOS/terminal-notifier -title "$icon $cmd_name" -subtitle "Exit code: $exit_code (${duration}s)" -message "$full_cmd" -sound "$sound" -activate "dev.code.desktop"
    else
        /Applications/terminal-notifier-code.app/Contents/MacOS/terminal-notifier -title "Remote Command" -message "$line" -activate "dev.code.desktop"
    fi
done