# subtract.ing

Source for subtract.ing. Agent-first documentation site.

## What this is

Shell translation infrastructure. The site documents the project.
Agents read llms.txt. Humans see an inventory.

## Structure

```
root/               interface (GitHub Pages serves from here)
├── index.html      landing
├── llms.txt        manifest
├── *.txt           documentation
├── install.sh      entry point
│
├── runtime/        installed to ~/.subtract
├── governance/     signing scripts
└── skills/         procedural knowledge
```

## Replicate this pattern

Any domain can be agent-first:

```
yourdomain.com/
├── index.html      trust signal
├── llms.txt        manifest for agents
└── [topic].txt     depth as needed
```

## Authors

Josh (@jnous.com @hodori @hodorigami) & LLMs (@qwen @bitnet @claude @gemini)
