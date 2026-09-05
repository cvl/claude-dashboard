#!/bin/bash
# Claude Code statusLine — writes per-session model for cdash dashboard
input=$(cat)
MODEL_ID=$(echo "$input" | jq -r '.model.id // empty')
if [ -n "$MODEL_ID" ]; then
  echo "$MODEL_ID" > "/tmp/claude-dash/${PPID}.model"
fi
