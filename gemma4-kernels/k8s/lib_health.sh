# Pure health decision for apply_config.sh after the warm-up requests (sourced; no kubectl).
# shellcheck shell=bash

replicas_healthy() {  # $1 replicas asked for, $2 ready replicas, $3 highest restart count, $4 warm-up failures.
  # 0 if healthy; otherwise prints the reason and returns 1. A replica that restarted (an OOM
  # at load time, most likely, since the optimizer is pushed towards the memory floor) or
  # failed its warm-up would leave the tenant measured with an idle neighbour, or not at all.
  if [ "${2:-0}" != "$1" ]; then echo "${2:-0} of $1 replica(s) ready after the warm-up"; return 1; fi
  if [ "${3:-0}" -gt 0 ]; then echo "a replica restarted during startup or the warm-up (restartCount ${3})"; return 1; fi
  if [ "${4:-0}" -gt 0 ]; then echo "${4} replica(s) failed the warm-up requests"; return 1; fi
  return 0
}
