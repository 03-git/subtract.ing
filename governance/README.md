# Governance

State tracking and human attestation for subtract.

## Why

When you run T4 (full AI agent), the agent modifies your system. Without governance, you trust the agent by default. With governance:

1. Agent does the work
2. Ledger surfaces what changed
3. You sign to authorize
4. Unsigned drift is the anomaly

The signature is Ed25519 cryptography. The agent cannot forge your authorization.

## Files

```
governance/
├── ledger.sh     # state tracking (init, status, verify)
├── sign.sh       # signing wrapper (creates key on first run)
├── boot.sh       # startup check (surfaces drift before proceeding)
├── exit.sh       # session end (signs new state)
└── ignore        # patterns to exclude from tracking
```

## Usage

**On install:** `governance/ledger.sh init && governance/sign.sh`

**On boot:** `governance/boot.sh` (handler calls this)

**On exit:** `governance/exit.sh` (or handler exit trap)

**Manual check:** `governance/ledger.sh status`

## The pattern

```
boot                              exit
  │                                 │
  ├─ ledger.sh status               ├─ ledger.sh init
  ├─ signature valid?               └─ sign.sh
  └─ drift? surface it
```

- **Clean + signed:** proceed
- **Drift + signed:** you made changes since last session
- **Unsigned drift:** changes exist that you didn't sign (anomaly)

## Learning path

Day 1: You need T4. Governance protects you. You sign without understanding.

Day 30: You notice drift caught something. You read the diff.

Day 90: You understand what the agent is doing by reading diffs at signoff.

Day 365: You can rebuild the governance from primitives. You are sovereign.

The governance layer teaches sovereignty the same way subtract teaches bash: by surfacing the primitive until you internalize it.
