// .claude/adapters/opencode/vault.js
// OpenCode adapter for this vault. Setup and verification: docs/harnesses/opencode.md.
//
// OPT-IN. OpenCode runs every file in .opencode/plugins/ at startup without
// asking, so this plugin ships outside that folder. Copy it to
// .opencode/plugins/vault.js once you have read it.
//
//   - Denies reads of .env, .env.* and anything under secrets/, the same set
//     .claude/rules/security.md names. (OpenCode already denies *.env reads.)
//   - Runs .claude/hooks/vault-lint.sh on every file the agent writes.
//   - Records each compaction with .claude/hooks/postcompact-wrap-up.sh.
//
// Both scripts are advisory: their failures never fail the tool call.

const EDIT_TOOLS = new Set(["write", "edit", "apply_patch"])

// Case-insensitive: Windows and macOS file systems ignore case, so ".ENV" and
// "Secrets/" open the same files as ".env" and "secrets/".
function isSecret(path) {
  const parts = String(path ?? "").toLowerCase().split(/[\\/]/)
  const base = parts[parts.length - 1]
  return base === ".env" || base.startsWith(".env.") || parts.includes("secrets")
}

// A patch names each file it writes in an "*** Add File:", "*** Update File:"
// or "*** Move to:" header.
function patchedFiles(text) {
  if (typeof text !== "string") return []
  const files = []
  for (const line of text.split(/\r?\n/)) {
    const match = /^\*\*\* (?:Add File|Update File|Move to): (.+)$/.exec(line)
    if (match) files.push(match[1].trim())
  }
  return files
}

export const VaultPlugin = async ({ $, worktree, directory }) => {
  const root = worktree || directory
  const hooks = `${root}/.claude/hooks`
  // Arguments are recorded before the tool runs and read back afterwards, keyed
  // by call id, so the after-hook does not depend on where OpenCode puts them.
  const pending = new Map()

  return {
    "tool.execute.before": async (input, output) => {
      const args = output?.args ?? {}
      if (input.tool === "read" && isSecret(args.filePath)) {
        throw new Error("vault: reading .env, .env.* and secrets/ is denied by .claude/rules/security.md")
      }
      if (EDIT_TOOLS.has(input.tool)) pending.set(input.callID, args)
    },

    "tool.execute.after": async (input) => {
      if (!EDIT_TOOLS.has(input.tool)) return
      const args = pending.get(input.callID) ?? {}
      pending.delete(input.callID)
      const files = [args.filePath, ...patchedFiles(args.patchText)].filter(Boolean)
      if (files.length === 0) return
      await $`bash ${hooks}/vault-lint.sh -- ${files}`.cwd(root).quiet().nothrow()
    },

    event: async ({ event }) => {
      if (event?.type !== "session.compacted") return
      const payload = JSON.stringify({ session_id: event.properties?.sessionID ?? "", trigger: "auto" })
      await $`bash ${hooks}/postcompact-wrap-up.sh < ${new Response(payload)}`.cwd(root).quiet().nothrow()
    },
  }
}
