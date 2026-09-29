#!/bin/zsh
# Starts both clean-up models in llama.cpp (on the Mac's GPU), runs the test, then stops them.
cd "$(dirname "$0")"
M=../../models/cleanup
common=(--ctx-size 4096 --parallel 1 --n-gpu-layers 99 --jinja --temp 0 --log-disable)
llama-server -m $M/speakoflow-mini-Q8_0.gguf --port 8091 $common > server-speakoflow.log 2>&1 &
p1=$!
llama-server -m $M/bitvoice-qwen3-0.6b-ft.gguf --port 8092 $common > server-bitvoice.log 2>&1 &
p2=$!
trap "kill $p1 $p2 2>/dev/null" EXIT
for port in 8091 8092; do
  until curl -sf http://127.0.0.1:$port/health > /dev/null; do sleep 0.5; done
done
python3 run_test.py
