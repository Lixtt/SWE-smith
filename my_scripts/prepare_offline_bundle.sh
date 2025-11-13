#!/usr/bin/env bash
#
# Helper script to pre-download SWE-smith datasets + Docker images on an online machine,
# then mirror the Docker images into an internal registry. On the offline machine you
# only need access to that registry to pull the mirrored tags.
#
# Usage:
#   DATASET="SWE-bench/SWE-smith" SPLIT="train[:2048]" OUT_DIR="bundle" \
#     bash my_scripts/prepare_offline_bundle.sh
#
# Requirements:
#   * huggingface datasets library (same as SWE-smith)
#   * docker daemon with internet access to registry-1.docker.io and push access to TARGET_REGISTRY
set -euo pipefail

DATASET="${DATASET:-SWE-bench/SWE-smith}"
SPLIT="${SPLIT:-train}"
OUT_DIR="${OUT_DIR:-offline_bundle}"
TARGET_REGISTRY="${TARGET_REGISTRY:-registry.h.pjlab.org.cn/ailab-safeag-safeag_gpu/swe}"
DATASET_FILE="${OUT_DIR}/$(echo "${SPLIT}" | tr '/:[]' '_').jsonl"
IMAGE_LIST_FILE="${OUT_DIR}/image_names.txt"
MAP_FILE="${OUT_DIR}/image_map.csv"

mkdir -p "${OUT_DIR}"

echo "[INFO] Exporting dataset ${DATASET} split ${SPLIT} -> ${DATASET_FILE}"
python - <<'PY'
import json
import os
from datasets import load_dataset

dataset_name = os.environ["DATASET"]
split = os.environ["SPLIT"]
dataset_file = os.environ["DATASET_FILE"]
image_list_file = os.environ["IMAGE_LIST_FILE"]

ds = load_dataset(dataset_name, split=split)
with open(dataset_file, "w", encoding="utf-8") as f:
    for inst in ds:
        f.write(json.dumps(inst, ensure_ascii=False) + "\n")

images = sorted({inst["image_name"] for inst in ds if inst.get("image_name")})
with open(image_list_file, "w", encoding="utf-8") as f:
    for img in images:
        f.write(img + "\n")

print(f"[OK] Wrote dataset to {dataset_file}")
print(f"[OK] Found {len(images)} unique Docker images -> {image_list_file}")
PY

if [[ ! -s "${IMAGE_LIST_FILE}" ]]; then
  echo "[WARN] No image names detected; skipping docker pulls/pushes."
  exit 0
fi

echo "original_image,mirrored_image" > "${MAP_FILE}"
echo "[INFO] Pulling images and pushing to ${TARGET_REGISTRY}"
while IFS= read -r image; do
  [[ -z "${image}" ]] && continue
  safe_tag=$(echo "${image}" | tr '/:.' '_')
  mirrored="${TARGET_REGISTRY}:${safe_tag}"
  if grep -q "^${image},${mirrored}$" "${MAP_FILE}"; then
    echo "[SKIP] ${image} already mirrored"
    continue
  fi
  echo "[PULL] ${image}"
  docker pull "${image}"
  echo "[TAG ] ${mirrored}"
  docker tag "${image}" "${mirrored}"
  echo "[PUSH] ${mirrored}"
  docker push "${mirrored}"
  echo "${image},${mirrored}" >> "${MAP_FILE}"
done < "${IMAGE_LIST_FILE}"

echo "[DONE] Dataset + mirror mapping stored under ${OUT_DIR}"
