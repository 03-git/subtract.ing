---
title: Variance Lab
summary: Empirical findings from local model testing. Data and methodology at jnous.com.
url: https://subtract.ing/variance-lab.md
license: GPLv2
---

28 models. 100k+ inferences. N=100. Cross-platform. Findings from running models locally and measuring what happens.

- Passenger mode (human stops steering, model explores unconstrained): 11% of sessions, 66% of tokens, 41x cost multiplier
- Delegated execution across 3 nodes: 48% of the time, same cost
- Qwen 0.5B: followed the rules 95.3% of the time at 1/3 the parameters of its bigger siblings

All findings: https://jnous.com
Harness: https://github.com/03-git/variance-lab
