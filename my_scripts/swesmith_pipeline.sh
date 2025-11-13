#!/usr/bin/env bash
#
# Step-by-step helper for running the full SWE-smith data pipeline and evaluation.
# Each subcommand is idempotent and can be executed independently:
#   1. env       – create repo env + Docker image (requires configs/install_repo.sh).
#   2. bug-llm   – generate LM Modify/Rewrite candidates.
#   3. bug-proc  – generate procedural (AST) candidates.
#   4. collect   – bundle *.diff files into a JSON manifest.
#   5. validate  – run test harness to keep only failing bugs.
#   6. gather    – materialize SWE-bench-style instances + Git branches.
#   7. issue     – attach problem statements.
#   8. subset    – slice the dataset for RL/SFT experiments.
#   9. eval      – validate RL/SFT predictions against ground truth tests.
#
# Usage:
#   chmod +x my_scripts/swesmith_pipeline.sh
#   TARGET_REPO="owner/repo" TARGET_COMMIT="70c3acf..." ./my_scripts/swesmith_pipeline.sh env
set -euo pipefail

ACTION="${1:-}"
if [[ -z "${ACTION}" ]]; then
  cat <<'USAGE'
Usage: swe-smith pipeline helper
  ACTION env|bug-llm|bug-proc|collect|validate|gather|issue|subset|eval
Environment variables:
  TARGET_REPO      (mandatory) GitHub repo, e.g. django/django
  TARGET_COMMIT    (mandatory) git commit hash to mirror
  INSTALL_SCRIPT   (default: configs/install_repo.sh) bash script that installs deps
  BUG_REPO_NAME    (optional) override mirror slug (<owner>__<repo>.<commit8>)
  RUN_ID           (optional) override logs/run_validation + logs/task_insts name
  N_BUGS           (default: 50) LM Modify bug count
  MAX_PROC_BUGS    (default: 50) Procedural bug count cap
  WORKERS          (default: 8) validation workers
  MODEL_NAME       (default: openai/gpt-4o) LM Modify/Rewrite model identifier
  ISSUE_MODEL      (default: anthropic/claude-3-7-sonnet-20250219) issue text model
  ISSUE_CONFIG     (default: configs/issue_gen/ig_v2.yaml)
  SUBSET_FILTER    (default: ".pr_" selection) python expression used in subset step
  SUBSET_NAME      (default: subset0)
  RL_PREDS         (needed for eval step) path to JSON predictions (instance_id/patch)
USAGE
  exit 1
fi

if [[ -z "${TARGET_REPO:-}" || -z "${TARGET_COMMIT:-}" ]]; then
  echo "[ERROR] Please export TARGET_REPO and TARGET_COMMIT before running this script." >&2
  exit 2
fi

INSTALL_SCRIPT="${INSTALL_SCRIPT:-configs/install_repo.sh}"
N_BUGS="${N_BUGS:-50}"
MAX_PROC_BUGS="${MAX_PROC_BUGS:-50}"
WORKERS="${WORKERS:-8}"
MODEL_NAME="${MODEL_NAME:-openai/gpt-4o}"
ISSUE_MODEL="${ISSUE_MODEL:-anthropic/claude-3-7-sonnet-20250219}"
ISSUE_CONFIG="${ISSUE_CONFIG:-configs/issue_gen/ig_v2.yaml}"
SUBSET_FILTER="${SUBSET_FILTER:-\".pr_\" in inst[\"instance_id\"] and 2 <= len(inst[\"FAIL_TO_PASS\"]) <= 5}"
SUBSET_NAME="${SUBSET_NAME:-subset0}"

OWNER="${TARGET_REPO%%/*}"
REPO="${TARGET_REPO##*/}"
COMMIT_SHORT="${TARGET_COMMIT:0:8}"
BUG_REPO_NAME="${BUG_REPO_NAME:-${OWNER}__${REPO}.${COMMIT_SHORT}}"
RUN_ID="${RUN_ID:-${BUG_REPO_NAME}}"
IMAGE_NAME="jyangballin/swesmith.x86_64.${OWNER}_1776_${REPO}.${COMMIT_SHORT}"

BUG_LOG_DIR="logs/bug_gen/${BUG_REPO_NAME}"
PATCH_MANIFEST="logs/bug_gen/${BUG_REPO_NAME}_all_patches.json"
RUN_VALIDATION_DIR="logs/run_validation/${RUN_ID}"
TASK_JSON="logs/task_insts/${RUN_ID}.json"
ISSUE_JSON="logs/issue_gen/${RUN_ID}__ig_v2_n1.json"
SUBSET_JSON="logs/experiments/${SUBSET_NAME}.json"

echo "[INFO] ACTION=${ACTION}"
echo "[INFO] TARGET_REPO=${TARGET_REPO} @ ${TARGET_COMMIT}"
echo "[INFO] RUN_ID=${RUN_ID}"

case "${ACTION}" in
  env)
    echo "[STEP] Exporting conda environment + creating Docker image..."
    python -m swesmith.build_repo.try_install_py \
      "${TARGET_REPO}" \
      "${INSTALL_SCRIPT}" \
      --commit "${TARGET_COMMIT}"

    python -m swesmith.build_repo.create_images \
      --profiles "${IMAGE_NAME}" \
      --workers 1 \
      --proceed \
      --push
    ;;

  bug-llm)
    echo "[STEP] Generating LM Modify bugs..."
    python -m swesmith.bug_gen.llm.modify \
      "${BUG_REPO_NAME}" \
      --n_bugs "${N_BUGS}" \
      --model "${MODEL_NAME}" \
      --config_file configs/bug_gen/lm_modify.yml
    ;;

  bug-proc)
    echo "[STEP] Generating procedural AST bugs..."
    python -m swesmith.bug_gen.procedural.generate \
      "${BUG_REPO_NAME}" \
      --max_bugs "${MAX_PROC_BUGS}"
    ;;

  collect)
    echo "[STEP] Collecting *.diff into ${PATCH_MANIFEST}..."
    python -m swesmith.bug_gen.collect_patches \
      "${BUG_LOG_DIR}" \
      --type all
    ;;

  validate)
    echo "[STEP] Running validation harness..."
    python -m swesmith.harness.valid \
      "${PATCH_MANIFEST}" \
      --workers "${WORKERS}"
    ;;

  gather)
    echo "[STEP] Gathering validated instances into ${TASK_JSON}..."
    python -m swesmith.harness.gather \
      "${RUN_VALIDATION_DIR}"
    ;;

  issue)
    echo "[STEP] Generating issue text..."
    python swesmith/issue_gen/generate.py \
      "${TASK_JSON}" \
      --config_file "${ISSUE_CONFIG}" \
      --model "${ISSUE_MODEL}" \
      --n_workers "${WORKERS}" \
      --experiment_id ig_v2 \
      --use_existing
    echo "[INFO] Issue-augmented file: ${ISSUE_JSON}"
    ;;

  subset)
    echo "[STEP] Building curated subset --> ${SUBSET_JSON}"
    python - <<'PY'
import json, os
from datasets import load_dataset

subset_json = os.environ["SUBSET_JSON"]
subset_filter = os.environ["SUBSET_FILTER"]
issue_json = os.environ.get("ISSUE_JSON")
task_json = os.environ["TASK_JSON"]

dataset_path = issue_json if issue_json and os.path.exists(issue_json) else task_json
with open(dataset_path) as f:
    data = json.load(f)

def include(inst):
    return eval(subset_filter, {"inst": inst})

subset = [inst for inst in data if include(inst)]
os.makedirs(os.path.dirname(subset_json), exist_ok=True)
with open(subset_json, "w") as f:
    json.dump(subset, f, indent=2)
print(f"[OK] Saved {len(subset)} instances to {subset_json}")
PY
    ;;

  eval)
    if [[ -z "${RL_PREDS:-}" ]]; then
      echo "[ERROR] Please set RL_PREDS=<path to predictions json> before running eval." >&2
      exit 3
    fi
    echo "[STEP] Evaluating predictions..."
    python -m swesmith.harness.eval \
      --dataset_path "${TASK_JSON}" \
      --predictions_path "${RL_PREDS}" \
      --run_id "${RUN_ID}" \
      --workers "${WORKERS}" \
      --timeout 300
    ;;

  *)
    echo "[ERROR] Unknown ACTION: ${ACTION}" >&2
    exit 4
    ;;
esac
