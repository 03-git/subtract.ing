# subtract.ing

Source for subtract.ing. Agent-first documentation site.

## What this is

Shell translation infrastructure. The site documents the project.
Agents read llms.txt. Humans see an inventory.

## Structure

```
root/                       interface (GitHub Pages serves from here)
├── index.html              landing
├── llms.txt                agent boot path
├── subtract.7              man(7) frame
├── lookup.tsv.universal    concept → man page
├── governance.conf.universal  reflexes, authority, loop
├── *.txt                   boot, why, lineage, signoff
├── install.sh              entry point
│
├── runtime/                installed to ~/.subtract
├── governance/             signing scripts
└── skills/                 procedural knowledge
```

## Replicate this pattern

Any domain can be agent-first:

```
yourdomain.com/
├── index.html      trust signal
├── llms.txt        manifest for agents
└── [topic].txt     depth as needed
```

## Existing site?

llms.txt is the machine-readable version. Plain text of what matters, one file.

## License

GPLv3. See [LICENSE.txt](LICENSE.txt).

## Authors

Josh (@hodorigami) & LLMs (@qwen @bitnet @claude @gemini)
