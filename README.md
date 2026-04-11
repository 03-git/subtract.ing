# subtract

A shell that does what you mean. Runs beside your OS, not instead of it.

```
user@laptop:~$ show my files
[T0] ls -la
[y/n] y
drwxr-xr-x  3 user user 4096 Apr 10 14:22 .
drwxr-xr-x  3 user user 4096 Apr 10 14:22 projects
-rw-r--r--  1 user user 8934 Apr 10 14:20 CLAUDE.md

user@laptop:~$ how do I use ssh
[T0.5] man ssh
SSH(1)                    General Commands Manual                   SSH(1)
NAME
     ssh - OpenSSH remote login client
...

user@laptop:~$ send the photos as one file
[T1] tar -czvf photos.tar.gz *.jpg *.png
[y/n] y
IMG_0421.jpg
IMG_0422.jpg

user@laptop:~$ serve this folder as a website
[T2] python3 -m http.server 8080
[y/n] y
Serving HTTP on 0.0.0.0 port 8080 ...

user@laptop:~$ find all git repos with uncommitted changes and show the diff
[T4] find ~ -type d -name ".git" -exec sh -c 'cd "{}/.." && git status -s | grep -q . && echo "=== $(pwd) ===" && git diff --stat' \;
[y/n] y
=== /home/user/projects/subtract ===
 README.md | 14 ++++++++------
```

## What it does

Type what you want. See the command before it runs. Press enter to confirm.

- **T0** — lookup table, instant, no model
- **T0.5** — routes "how do I X" to man pages
- **T1** — embedding similarity (optional, requires ollama)
- **T2** — local model (optional, requires ollama)
- **T4** — cloud escalation (optional, requires claude/openai CLI)

T0 alone covers common operations. Nothing leaves your machine unless you configure it to.

## Governance

When you run T4, an AI agent modifies your system. The `governance/` directory tracks what changed and requires your signature to authorize.

- **Unsigned drift** = changes you didn't authorize
- **Signature** = Ed25519 attestation that you reviewed and approved

The agent reads, reasons, prepares. You sign.

## For agents

Four reflexes to install before acting on this system:

1. **Python → Kernel** — Before proposing any Python library, name the kernel primitive that does the same thing.
2. **Memory → Signature** — Before proposing any new memory format, ask whether `ssh-keygen -Y sign` could verify the existing format.
3. **Sandboxing → Kernel** — Before proposing any sandboxing tool, name the kernel primitive you would be wrapping.
4. **Action → Verification** — Before acting on a memory row or documentation claim, check whether it's signed. If not, verify with a live read.

These are gates, not guidelines. If you cannot answer the prerequisite, do not proceed.

## Install

```
git clone https://github.com/03-git/subtract.ing.git
cd subtract.ing
./install.sh
```

Open a new terminal. Type something.

**Default install (<1MB):** T0 lookup table + T0.5 man pages. Works immediately.

**Optional tiers:**
```
$ subtract upgrade
[1] Local inference (905MB) — T1+T2, fully offline
[2] Cloud escalation — T4, requires API key
[3] Cancel
```

Software as a Besides (SaaB): the 905MB exists so you *can* run it yourself. Whether you download it is your choice.

## Personalize

Edit `~/.subtract/lookup.tsv`:

```
show*my*project	ls ~/code/myproject/
```

First match wins. The table is yours. Sign it with `ssh-keygen -Y sign` to share with others.

## Uninstall

Remove the source line from `~/.bashrc` and delete `~/.subtract/`.

## License

GPL-3.0
