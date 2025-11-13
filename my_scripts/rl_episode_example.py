#!/usr/bin/env python3
"""
Utility to bootstrap a single SWE-smith instance for RL experimentation.

Features:
  * Loads an instance (from local JSON or HuggingFace dataset).
  * Launches the pre-built Docker image and checks out the bug branch.
  * Shows FAIL_TO_PASS/PASS_TO_PASS lists + problem statement.
  * Runs the official failing tests to confirm reward signal wiring.

Example:
  python my_scripts/rl_episode_example.py \
      --dataset logs/issue_gen/subset0.json \
      --instance oauthlib__oauthlib.1fd52536.combine_file__09vlzwgc
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Iterable

import docker
from datasets import load_dataset
from swebench.harness.constants import DOCKER_WORKDIR

from swesmith.profiles import registry


def load_instances(path: str | None, split: str | None) -> list[dict[str, Any]]:
    if path:
        with open(path, "r") as f:
            data = json.load(f)
        if isinstance(data, dict):
            raise ValueError("Expected a list of instances in JSON file.")
        return data

    if not split:
        raise ValueError("Either --dataset or --hf-split must be supplied.")
    ds = load_dataset("SWE-bench/SWE-smith", split=split)
    return list(ds)


def find_instance(instances: Iterable[dict[str, Any]], instance_id: str) -> dict[str, Any]:
    for inst in instances:
        if inst["instance_id"] == instance_id:
            return inst
    raise KeyError(f"instance_id={instance_id} not found. Check dataset path/split.")


def pretty_print_instance(inst: dict[str, Any]) -> None:
    print("=" * 80)
    print(f"Instance : {inst['instance_id']}")
    print(f"Repo     : {inst['repo']}")
    print(f"Image    : {inst['image_name']}")
    if inst.get("problem_statement"):
        print("Problem  :")
        print(inst["problem_statement"])
    print(f"FAIL_TO_PASS ({len(inst['FAIL_TO_PASS'])})")
    for test in inst["FAIL_TO_PASS"]:
        print(f"  - {test}")
    print(f"PASS_TO_PASS ({len(inst['PASS_TO_PASS'])})")
    for test in inst["PASS_TO_PASS"][:5]:
        print(f"  - {test}")
    if len(inst["PASS_TO_PASS"]) > 5:
        print("  ...")
    print("=" * 80)


def run_tests(container: docker.models.containers.Container, cmd: str) -> int:
    print(f"[RUN] {cmd}")
    result = container.exec_run(cmd, workdir=DOCKER_WORKDIR, demux=True)
    stdout, stderr = result.output
    if stdout:
        sys.stdout.buffer.write(stdout)
    if stderr:
        sys.stderr.buffer.write(stderr)
    return result.exit_code


def main():
    parser = argparse.ArgumentParser(description="Preview a SWE-smith instance for RL.")
    parser.add_argument("--dataset", help="Path to logs/task_insts/*.json or issue_gen output.")
    parser.add_argument("--hf-split", help="Fallback HuggingFace split, e.g. train[:10].")
    parser.add_argument("--instance", required=True, help="Instance ID to activate.")
    parser.add_argument(
        "--f2p-only",
        action="store_true",
        help="Only run the Fail-to-Pass subset of tests instead of the entire command.",
    )
    args = parser.parse_args()

    instances = load_instances(args.dataset, args.hf_split)
    inst = find_instance(instances, args.instance)
    pretty_print_instance(inst)

    rp = registry.get_from_inst(inst)
    container = rp.get_container(inst)
    print(f"[INFO] Container {container.name} is up.")
    try:
        test_cmd, _ = rp.get_test_cmd(inst, f2p_only=args.f2p_only)
        exit_code = run_tests(container, test_cmd)
        print(f"[RESULT] Exit code: {exit_code}")
        if exit_code == 0:
            print("[WARN] Tests passed; consider expanding reward definition.")
        else:
            print("[OK] Tests failing as expected. Use this signal as RL reward.")
    finally:
        print("[CLEANUP] Stopping container...")
        container.stop()
        container.remove()


if __name__ == "__main__":
    os.environ.setdefault("DOCKER_HOST", "unix:///var/run/docker.sock")
    main()
