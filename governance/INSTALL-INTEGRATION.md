# Install Integration

Add to install.sh after copying files:

```bash
# Initialize governance
echo "initializing governance..."
cp -r governance/ "$SUBTRACT_HOME/governance/"
"$SUBTRACT_HOME/governance/ledger.sh" init
"$SUBTRACT_HOME/governance/sign.sh"
```

## Handler Integration

At handler.sh startup:

```bash
# Governance check
if ! "$SUBTRACT_HOME/governance/boot.sh"; then
    echo "governance check failed - exiting"
    exit 1
fi
```

At handler.sh exit (trap):

```bash
trap '"$SUBTRACT_HOME/governance/exit.sh"' EXIT
```

Or as explicit command:

```bash
# In command routing
signoff|sign)
    "$SUBTRACT_HOME/governance/exit.sh"
    ;;
```

## First Run Flow

1. User runs install.sh
2. install.sh copies governance/
3. install.sh runs ledger.sh init + sign.sh
4. Signing key created, baseline signed
5. User starts handler.sh
6. boot.sh verifies signature, clean state
7. User works with T4
8. User types "signoff" or exits
9. exit.sh updates manifest + signs
10. Next session starts with signed baseline

## Drift Detection

If user modifies subtract files outside a session, or if T4 modifies files and crashes before signoff:

1. Next boot runs boot.sh
2. ledger.sh status shows drift
3. boot.sh surfaces: "unsigned changes detected"
4. User reviews, chooses: continue/sign/abort
5. If sign: new state authorized
6. If continue: proceed with acknowledged unsigned state
7. If abort: exit, nothing runs
