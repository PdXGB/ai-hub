#!/usr/bin/env python3
"""Load one GPU with fp16 matmuls and report PASS if it survives.

Usage:
  CUDA_VISIBLE_DEVICES=<GPU_UUID> python gpu-burn.py [seconds]   # default 300

Needs PyTorch with CUDA (ComfyUI's venv works). Check dmesg afterwards.
"""
import sys
import time

import torch

duration = int(sys.argv[1]) if len(sys.argv) > 1 else 300
print(f"device: {torch.cuda.get_device_name(0)}  duration: {duration}s", flush=True)

a = torch.randn(8192, 8192, device="cuda", dtype=torch.float16)
t = time.time()
n = 0
while time.time() - t < duration:
    a @ a
    n += 1
    if n % 200 == 0:
        torch.cuda.synchronize()
        print(f"{int(time.time() - t)}s ok", flush=True)
torch.cuda.synchronize()
print("PASS")
