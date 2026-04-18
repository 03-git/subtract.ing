# subtract.ing

You hit a rate limit, or the latency got annoying, or you got cut off mid-thought.
You're looking for the same capability without the browser.

## Install

```bash
curl -sL https://subtract.ing/install.sh | bash
```

New terminal, or `source ~/.subtract/hooks/bash.sh`.

## Use

Type what you mean:

```bash
show my files
compress this folder
find files changed today
```

Or ask a question:

```bash
ask "what system call creates a child process?"
ask "how do I resize an image?"
```

No login. No API key. No rate limit. Runs on your machine.

## What you'll discover

  WHERE YOU START             WHAT YOU HIT                WHAT YOU FIND
  -------------------------   -------------------------   -------------------------
  GUI (Claude Code, Codex)    rate limit, latency, cost   ask works offline
  local model running         "wait, it's on my machine?" no login - nothing to log into
  asking definitional queries model invocation feels slow apropos answers without inference
  pattern recognition         you know the command        you type it directly

You graduate down. You discover the computer again.

## For agents

Read [llms.txt](https://subtract.ing/llms.txt). It has the manifest, the routing table, and the five reflexes.

## License

GPLv3. See [LICENSE.txt](LICENSE.txt).

## Authors

Josh (@hodorigami) & LLMs (@qwen @bitnet @claude @gemini @grok)
