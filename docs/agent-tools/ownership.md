# Agent tools v2: file ownership

Base: `claude/agenttools-base`. Every work package branches off it. A WP edits only the files in its row. Any other
change is requested through the integrator.

The shared interface is `Sources/MemoryCore/AgentShare/AgentShareModel.swift` (abbreviated below as `AgentShare/`).
It is frozen for A–D, and only the integrator changes it. Its `...API` protocols pin each WP's signatures, so a
changed signature fails the build on the WP's own branch.

WP-0 created stub files that let the project compile in both lanes. Each WP **replaces its stubs wholesale**; it does
not add a second declaration next to them. The stubs are safe: no typed words are shared and no owner preview is
allowed.

| WP | Owns (creates, or replaces the WP-0 stub) | Edits (shared files, this WP only) |
|---|---|---|
| **0: integrator** | `AgentShare/AgentShareModel.swift`, this file | Merges; adds `extension MemoryStore: DayReviewHeadlineSource {}` when the day-summary accessor lands |
| **A: policy and typed words** | `AgentShare/AgentSharePolicy.swift` (stub)<br>`AgentShare/AgentBridgeSource.swift` (stub: bridge client and `AgentOwnerPreview.permits`)<br>NEW `Checks/AgentSharePolicyChecks.swift` | `AssistantTypedRead.swift`, `AIReadsTypedSetting.swift`, `AssistantReadiness.swift` |
| **B: read-time model** | `AgentShare/AgentTitles.swift`, `AgentEntities.swift` (including `AgentEntity.key`), `AgentItems.swift`, `AgentRank.swift` (all stubs)<br>NEW `Checks/AgentModelChecks.swift` | none |
| **C: tools, render, search, server** | `AgentShare/AgentTools.swift`, `AgentRender.swift` (stubs)<br>NEW `AgentShare/AgentSearch.swift` | `AssistantCatalog.swift`, `Sources/MacMemCLI/main.swift`, `skills/daydream/SKILL.md`, `skills/daydream/reference/tools.md`, `scripts/check_interfaces.py`, `scripts/mcp-tool-hint-checks.py` |
| **D: evals and fixture** | NEW `Checks/AgentToolsFixture.swift`, `Checks/AgentToolsChecks.swift`, `scripts/agent-tools-evals.py`, `scripts/agent-tools-private-run.py` | `Checks/main.swift` (one line per checks file, A's and B's included) |

Nobody in A–D touches these files:
- `DayReview*.swift`, `WriterBackend/**`, `LevelNotes.swift` and `NoteFiller.swift`. They belong to the day-summary
  agent. Reading them (for example `NoteFiller.isFiller`) is fine.
- `TypedSecretScrubber.swift`: it is wrapped, not edited.
- `MemorySearch.swift`. C reaches it from `AgentSearch.swift`, at most through one `extension MemoryStore`.

Merge order: A and B in either order, then C, then D.

## Local-owner preview (owner decision 10/04)

- **Contract.** `AgentBridgeRequest.ownerPreview`, `AgentOwnerPreview.cliFlag` (`--owner-preview`) and
  `AgentOwnerPreviewAPI.permits` are in the model.
- **A.** A implements the gate. It must hold all of the following:
  - the request comes over the local socket from the same user;
  - the owner passed the explicit flag;
  - all grant fields are empty;
  - the request is not from `mac-mem mcp`;
  - the setting is on.

  The text still goes through `shareable`.
- **C.** C sets the flag only in `mac-mem --local agent-preview` when the owner passes it, and never in the MCP
  server.
- **D.** D's private-run script passes the flag. It writes only under the owner's private folder and refuses any path
  inside a git worktree.
- **Who runs it.** The owner runs the script. Agents never write real replies anywhere.

## Lanes

Both lanes must build:
- public: plain `swift build`;
- owner: `-Xswiftc -DDAYDREAM_OWNER_TYPING -Xswiftc -DDAYDREAM_CHROME_TYPING`.

`MacMemChecks` must pass in both lanes. Run it from the worktree root, with `HOME` and `TMPDIR` set to scratch
folders, the same way the runner does.

Every fixture is synthetic.
