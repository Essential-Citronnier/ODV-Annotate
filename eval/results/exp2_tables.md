### Table 1 — Pipeline fidelity, per cohort case

| Case | Slices | Structures | Model determinism (min Dice) | SEG round trip (min Dice) | End to end (min Dice) | Unplaced frames | Wall s (CPU-only) |
|---|---|---|---|---|---|---|---|
| tcia_1028210905866391 | 485 | 78 | 1.0 | 1.0 | 1.0 | 0 | 739.77 |
| tcia_1556218467652708 | 411 | 80 | 1.0 | 1.0 | 1.0 | 0 | 987.59 |
| tcia_1615802411543660 | 481 | 107 | 1.0 | 1.0 | 1.0 | 0 | 877.01 |

3 of 3 cases succeeded; the lowest per-structure Dice anywhere in the end-to-end comparison is 1.0.


### Table 2 — Hygiene check against expert reference masks

Not an accuracy claim. Evidence that neither path silently broke the model.

| Case | Reference structures | Native mean Dice | Plugin mean Dice | Native, large structures | Plugin, large structures | Path agreement (min Dice) |
|---|---|---|---|---|---|---|
| s0049 | 108 | 0.8545 | 0.8545 | 0.9496 | 0.9496 | 1.0 |
| s0111 | 89 | 0.8304 | 0.8304 | 0.9495 | 0.9495 | 1.0 |
| s0189 | — | — | — | — | — | — |
| s0193 | — | — | — | — | — | — |
| s0241 | 76 | 0.816 | 0.816 | 0.9432 | 0.9432 | 1.0 |
| s0245 | 54 | 0.8046 | 0.8046 | 0.8623 | 0.8623 | 1.0 |
