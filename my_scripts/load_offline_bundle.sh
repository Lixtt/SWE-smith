#!/usr/bin/env bash
#
# Restore a SWE-smith offline bundle onto a machine that can only reach an internal
# registry (not Docker Hub). Assumes prepare_offline_bundle.sh was run on an online
# machine to mirror the required images into TARGET_REGISTRY and produce image_map.csv.
# This script will:
#   1. docker pull each mirrored tag from the registry and re-tag it to the original name.
#   2. Optionally copy dataset JSONL into logs/issue_gen/offline/ for SWE-smith usage.
#
# Usage:
#   BUNDLE_DIR=/path/to/offline_bundle bash my_scripts/load_offline_bundle.sh
set -euo pipefail

BUNDLE_DIR="${BUNDLE_DIR:-offline_bundle}"
DEST_DATA_DIR="${DEST_DATA_DIR:-logs/issue_gen/offline}"
MAP_FILE="${BUNDLE_DIR}/image_map.csv"

if [[ ! -d "${BUNDLE_DIR}" ]]; then
  echo "[ERROR] Bundle directory ${BUNDLE_DIR} not found." >&2
  exit 1
fi

if [[ -f "${MAP_FILE}" ]]; then
  echo "[INFO] Pulling mirrored images based on ${MAP_FILE}"
  tail -n +2 "${MAP_FILE}" | while IFS=',' read -r original mirrored; do
    [[ -z "${original}" || -z "${mirrored}" ]] && continue
    echo "[PULL] ${mirrored}"
    docker pull "${mirrored}"
    echo "[TAG ] ${original}"
    docker tag "${mirrored}" "${original}"
  done
else
  echo "[WARN] ${MAP_FILE} not found; skipping docker pulls."
fi

mkdir -p "${DEST_DATA_DIR}"
echo "[INFO] Copying dataset files into ${DEST_DATA_DIR}"
find "${BUNDLE_DIR}" -maxdepth 1 -name "*.jsonl" -print0 | while IFS= read -r -d '' file; do
  cp -f "${file}" "${DEST_DATA_DIR}/"
  echo "[COPY] $(basename "${file}")"
done

echo "[DONE] Bundle restored. Point SWE-smith scripts to files under ${DEST_DATA_DIR}/"
