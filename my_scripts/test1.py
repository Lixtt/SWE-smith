from datasets import load_dataset
import json
import os
from pathlib import Path

# 直接指定本地缓存路径
hf_home = os.getenv("HF_HOME", os.path.expanduser("~/.cache/huggingface"))
# 数据集缓存的快照路径
snapshot_path = Path(hf_home) / "hub" / "datasets--SWE-bench--SWE-smith" / "snapshots" / "ae8206fd60e5c910158d75b6be22c08bc8cccfbf" / "data"

# 直接从本地 parquet 文件加载，完全不需要网络
dataset = load_dataset("parquet", data_files=str(snapshot_path / "train-*.parquet"), split="train")

# 转换为列表
dataset_list = [x for x in dataset]

# 打印数据集长度
length_of_dataset_list = len(dataset_list)
print(length_of_dataset_list)

# 保存一部分样本到jsonl文件
with open("my_scripts/dataset_list_part_3.jsonl", "w") as f:
    for item in dataset_list[:3]:
        f.write(json.dumps(item, ensure_ascii=False) + "\n")

