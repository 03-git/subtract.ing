#!/bin/bash
# Sign your lookup table. Run this after editing lookup.tsv.
ssh-keygen -Y sign -f ~/.ssh/id_ed25519 -n subtract < ~/.subtract/lookup.tsv > ~/.subtract/lookup.tsv.sig
echo "Signed: ~/.subtract/lookup.tsv.sig"
