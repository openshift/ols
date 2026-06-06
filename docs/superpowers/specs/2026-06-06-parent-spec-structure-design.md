# Parent Spec Structure Design

## Goal

Create a parent-level `.ai/spec/` that enables an AI agent working from the `/ols` root to:
1. Quickly route "update the spec for feature X" to the correct repo(s) and file(s)
2. Understand cross-repo features end-to-end without reading every child spec
3. Know which repos exist, what they do, and where their specs live

## Context

The `/ols` workspace contains 10 git repos. Six already have `.ai/spec/` with what/how structures. Four have AGENTS.md only. The parent repo is a lightweight orchestration layer — it does not contain application code.

## Structure

```
.ai/spec/
├── README.md                    # Entry point, quick-start routing table
├── constraints.md               # Cross-repo invariants
├── what/
│   ├── system-overview.md       # Full product: classic + agentic layers, all 10 repos
│   ├── agentic-proposals.md     # Cross-repo: alert → adapter → operator → sandbox → console
│   ├── rag-pipeline.md          # Cross-repo: rag-content builds → service consumes
│   ├── deployment-lifecycle.md  # Cross-repo: operator deploys service + console + postgres
│   └── query-pipeline.md        # Cross-repo: console → service → LLM/RAG → response
└── how/
    └── repo-map.md              # Flat lookup: concern → repo(s) → spec file(s)
```

## Design Decisions

### Cross-repo what/ files over routing-only index
A routing table alone forces the agent to read multiple child specs and mentally stitch together cross-repo flows. Cross-repo what/ files describe end-to-end behavior, integration contracts (CRDs, APIs, shared data), and repo ownership per slice. The routing index (`how/repo-map.md`) remains for fast lookups.

### No how/ files beyond repo-map
The parent repo has no application code. Implementation details live in child repo specs. The repo-map is the only how/ file needed.

### constraints.md for cross-repo invariants
Rules that apply across all repos (fork workflow, Jira prefix, namespace, CRD API groups, embedding model invariant). Violating these means something is wrong, not just lower quality.

### AGENTS.md gets a spec pointer
Existing content stays. A `## Specs` section points to `.ai/spec/README.md`.

## Four Cross-Repo Features

### 1. Agentic Proposals
Repos: alerts-adapter, agentic-operator, agentic-sandbox, agentic-console
Flow: AlertManager → adapter creates Proposal CR → operator reconciles through Analysis/Approval/Execution/Verification/Escalation → sandbox runs agents → console shows status and approval UI

### 2. RAG Pipeline
Repos: rag-content, service, operator
Flow: rag-content acquires docs → chunks and embeds → packages as OCI image → operator mounts volume → service loads FAISS indexes at startup → retrieves chunks at query time

### 3. Deployment Lifecycle
Repos: operator, service, console
Flow: User creates OLSConfig CR → operator validates → generates ConfigMaps/Secrets/RBAC → deploys service, console, postgres → watches external resources for changes → reports status

### 4. Query Pipeline
Repos: console, service, rag-content (runtime), operator (config)
Flow: Console submits query → service validates/redacts → retrieves RAG chunks → fetches history → selects skills → composes prompt → LLM generation with tool-calling loop → streams response back
