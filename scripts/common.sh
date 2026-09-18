#!/usr/bin/env bash
# Shared setup, variables, and helper functions for scripts/*.sh. Source this near
# the top of a script, right after the shebang and header comment:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .venv/bin/activate ]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

INVENTORY="inventories/rpi_linux/hosts"
ALL_NODES="node0,node1,node2,node3"
CONTROL="node0"
WORKERS="node1,node2,node3"

phase() {
  echo
  echo "=== $* ==="
}

declare -a PHASE_NAMES=()
declare -a PHASE_DURATIONS=()

# ---- resume support ----------------------------------------------------------
# Lets a script built from run_phase calls (currently just
# scripts/cluster_full_provision.sh) pick up after an interruption instead of
# always restarting from its first phase. That distinction matters here
# specifically because the boot-mode/NVMe/PXE phases are not cheap no-ops on
# a from-scratch restart -- they re-cycle every node's boot mode and reboot
# them again even when nothing actually needs to change, which is real
# wall-clock time (and real reboots) to redo for no reason after, say, a
# typo in a later phase gets fixed.
#
# RESUME_STATE_FILE holds exactly one line: the name of the last phase that
# fully succeeded (ansible-playbook rc==0, and -- under
# scripts/rebuild_debug/cluster_rebuild_monitor.sh -- confirmed node reachability too, see
# the cluster_rebuild_health_check hook below). On the next invocation,
# run_phase skips every phase up to and including that name and resumes for
# real right after it. Cleared automatically once a run finishes every
# phase (see finish_resume_state, called at the end of
# scripts/cluster_full_provision.sh), so resume is for recovering from an
# interruption, not a standing mode -- the run after a clean finish starts
# fresh again.
#
# Set RESUME_FROM_SCRATCH=true to ignore/delete any existing marker and
# force a full restart from the first phase.
RESUME_STATE_FILE="${RESUME_STATE_FILE:-logs/cluster_rebuild_state}"
mkdir -p "$(dirname "$RESUME_STATE_FILE")"
_RESUME_TARGET=""
_RESUME_SKIPPING=false
if [ "${RESUME_FROM_SCRATCH:-false}" = "true" ]; then
  rm -f "$RESUME_STATE_FILE"
elif [ -s "$RESUME_STATE_FILE" ]; then
  _RESUME_TARGET="$(cat "$RESUME_STATE_FILE")"
  _RESUME_SKIPPING=true
  phase "Resuming: skipping phases up to and including \"$_RESUME_TARGET\" (set RESUME_FROM_SCRATCH=true to disable)"
fi

# Called once, after every phase in the sequence has run (whether skipped or
# executed for real) -- see the end of scripts/cluster_full_provision.sh.
# Clears the marker for next time, UNLESS the resume target was never
# actually matched against any phase in this run (e.g. a stale marker after
# phases were renamed/reordered) -- silently skipping the entire rebuild in
# that case would be worse than failing loudly.
finish_resume_state() {
  if [ "$_RESUME_SKIPPING" = true ]; then
    echo "ERROR: resume marker \"$_RESUME_TARGET\" (from $RESUME_STATE_FILE) was never" >&2
    echo "matched against any phase in this run -- every phase was skipped. This" >&2
    echo "usually means phases were renamed/reordered since the marker was written." >&2
    echo "Re-run with RESUME_FROM_SCRATCH=true to start over." >&2
    return 1
  fi
  rm -f "$RESUME_STATE_FILE"
}

# Runs one stage, timing it, and records the duration for print_time_table.
# Usage: run_phase "Phase N: label" cmd_or_function [args...]
run_phase() {
  local name="$1"
  shift

  if [ "$_RESUME_SKIPPING" = true ]; then
    phase "$name (skipping -- already completed in a prior run)"
    if [ "$name" = "$_RESUME_TARGET" ]; then
      _RESUME_SKIPPING=false
    fi
    return 0
  fi

  phase "$name"
  local start end duration rc
  start=$(date +%s)
  # if/else, not a bare "$@" line: under set -e, a failing command as its own
  # simple statement aborts the whole script right here, before any of the
  # bookkeeping below -- including the health-check hook -- ever runs. That
  # defeats the hook's entire purpose for scripts/rebuild_debug/cluster_rebuild_monitor.sh:
  # a node dropping mid-task is exactly what makes ansible-playbook itself
  # return non-zero (RUN_UNREACHABLE_HOSTS), so the one case the hook exists
  # to catch was also the one case that always skipped it.
  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  end=$(date +%s)
  duration=$((end - start))
  PHASE_NAMES+=("$name")
  PHASE_DURATIONS+=("$duration")
  # Opt-in hook: no-op for every script unless the caller defines a function
  # named cluster_rebuild_health_check before sourcing this file (see
  # scripts/rebuild_debug/cluster_rebuild_monitor.sh) -- ordinary scripts are unaffected.
  # Called even when the phase itself failed, and passed the phase's exit
  # code, so the hook can distinguish "ansible failed but every node stayed
  # reachable" from "a node actually dropped" instead of only ever seeing
  # phases that already succeeded.
  if declare -F cluster_rebuild_health_check >/dev/null; then
    cluster_rebuild_health_check "$name" "$rc" || return "$?"
  elif [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  # Only reached once the phase -- and, when monitored, node reachability
  # too -- is fully confirmed good, so a resumed run never skips past
  # something that only looked fine to ansible-playbook's own exit code.
  echo "$name" >"$RESUME_STATE_FILE"
}

print_time_table() {
  local total=0 i d
  phase "Time analysis"
  printf '%-62s %10s\n' "Stage" "Duration"
  printf '%-62s %10s\n' "-----" "--------"
  for i in "${!PHASE_NAMES[@]}"; do
    d="${PHASE_DURATIONS[$i]}"
    total=$((total + d))
    printf '%-62s %6dm%02ds\n' "${PHASE_NAMES[$i]}" $((d / 60)) $((d % 60))
  done
  printf '%-62s %10s\n' "-----" "--------"
  printf '%-62s %6dm%02ds\n' "TOTAL" $((total / 60)) $((total % 60))
}
