#!/usr/bin/env bash
# Shared ExternalModel list for REQ 024 apply/validate scripts.
# Format: "<maas-resource-name>:<targetModel>"
REQ024_EXTERNAL_MODELS=(
  "deepseek-r1-distill-qwen-14b-external:deepseek-r1-distill-qwen-14b"
  "llama-31-70b-external:llama-31-70b-cpu"
  "llama-scout-17b-external:llama-scout-17b"
)

req024_model_names() {
  local entry name
  for entry in "${REQ024_EXTERNAL_MODELS[@]}"; do
    name="${entry%%:*}"
    printf '%s\n' "${name}"
  done
}

req024_target_model() {
  local want="$1" entry name target
  for entry in "${REQ024_EXTERNAL_MODELS[@]}"; do
    name="${entry%%:*}"
    target="${entry#*:}"
    if [[ "${name}" == "${want}" ]]; then
      printf '%s' "${target}"
      return 0
    fi
  done
  return 1
}
