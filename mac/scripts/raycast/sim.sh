#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Open Amazon Sim Issue
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🔗
# @raycast.argument1 { "type": "text", "placeholder": "Issue ID" }

# Documentation:
# @raycast.description Opens an Amazon Sim issue URL with the provided issue ID
# @raycast.author Roy Levi
# @raycast.authorURL https://raycast.com/roylevi

open "https://sim.amazon.com/issues/$1"
echo "Opening issue: $1"
