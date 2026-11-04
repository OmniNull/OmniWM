#!/bin/sh
printf '["state","summary","Ready"]\n'
while IFS= read -r frame; do
  id=$(printf '%s' "$frame" | sed -nE 's/^\[ *"action" *, *"([^"]+)".*/\1/p')
  [ -n "$id" ] || continue
  printf '["result","%s",true,{}]\n' "$id"
  printf '["event","confirm-delete",{"itemId":"selected-item"}]\n'
done
