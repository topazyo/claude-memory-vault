// .claude/adapters/pi/vault.js
// Pi extension for this vault. Setup and verification: docs/harnesses/pi.md.
//
// OPT-IN. Pi runs the extensions in .pi/extensions/ once a project is trusted,
// and a trust decision saved for a folder covers every folder below it, so a
// vault cloned into a trusted folder would run a shipped extension without
// asking. This file ships where Pi does not look. Load it with
// `pi -e .claude/adapters/pi/vault.js`, or copy it to .pi/extensions/vault.js,
// once you have read it. Not both, or it runs twice.
//
//   - Refuses a read, write, edit, grep, find or ls call that names .env,
//     .env.* or anything under secrets/, the set .claude/rules/security.md
//     names, and a grep whose glob names one. Pi's bash tool can still read
//     them, so this keeps the file tools from doing it by accident.
//   - Runs .claude/hooks/vault-lint.sh on every file a write or edit changes,
//     and adds what it reports to the tool's result.
//   - Records each compaction with .claude/hooks/postcompact-wrap-up.sh.
//
// Both scripts are advisory: their failures never fail the tool call. When one
// cannot run, the extension says so once instead of going quiet.

import { spawn } from "node:child_process"
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path"
import { fileURLToPath } from "node:url"

const LINT = ".claude/hooks/vault-lint.sh"
const STUB = ".claude/hooks/postcompact-wrap-up.sh"
const CHECK = ".claude/scripts/vault-check.sh"
const PATH_TOOLS = new Set(["read", "write", "edit", "grep", "find", "ls"])
const PATH_REQUIRED = new Set(["read", "write", "edit"])
const WRITE_TOOLS = new Set(["write", "edit"])
const DENIED = "vault: .env, .env.* and secrets/ are off limits (.claude/rules/security.md)"
const NO_PATH = "vault: the secrets guard found no path in this call, so it is refused. Pi's tool input may have changed shape: see docs/harnesses/pi.md"
const WINDOWS = process.platform === "win32"

// The folder this file is in, when the loader provides import.meta.url.
let HERE = null
try {
  HERE = dirname(fileURLToPath(import.meta.url))
} catch {
  HERE = null
}

// ---------------------------------------------------------------- paths --
// Where Pi's file tools will look for a path the model gave them. This follows
// resolveToCwd, normalizePath and normalizeWindowsShellPath in Pi's
// src/core/tools/path-utils.ts and src/utils/paths.ts as of v0.87.1, because
// the guard has to test the file Pi is about to open, not the string it got.
const UNICODE_SPACES = /[\u{A0}\u{2000}-\u{200A}\u{202F}\u{205F}\u{3000}]/gu

function windowsShellPath(path) {
  if (!path.startsWith("/") || path.startsWith("//") || path.includes("\\")) return path
  const match = path.match(/^\/(?:mnt\/|cygdrive\/)?([a-z])(?:\/(.*))?$/i)
  if (!match) return path
  const suffix = match[2]?.replaceAll("/", "\\")
  return `${match[1].toUpperCase()}:\\${suffix ?? ""}`
}

function expandTilde(path) {
  if (path === "~") return homedir()
  if (path.startsWith("~/") || (WINDOWS && path.startsWith("~\\"))) return join(homedir(), path.slice(2))
  return null
}

function resolveLikePi(raw, cwd) {
  let path = raw.replace(UNICODE_SPACES, " ")
  if (path.startsWith("@")) path = path.slice(1)
  if (WINDOWS) path = windowsShellPath(path)
  const home = expandTilde(path)
  if (home !== null) path = home
  else if (/^file:\/\//.test(path)) path = fileURLToPath(path)
  return isAbsolute(path) ? resolve(path) : resolve(cwd, path)
}

// The real path: every link on the way followed, including one whose target
// does not exist yet, because writing through such a link creates the target.
// Throws when a chain of links does not end.
function realPath(path) {
  let current = resolve(path)
  for (let hops = 0; hops <= 40; hops++) {
    const tail = []
    let head = current
    let next = null
    while (next === null) {
      try {
        return join(realpathSync.native(head), ...tail)
      } catch {
        let link = null
        try {
          if (lstatSync(head).isSymbolicLink()) link = readlinkSync(head)
        } catch {
          link = null
        }
        if (link !== null) {
          // A relative target is read from the folder the link really sits
          // in, which is not the folder its spelling names when a link on the
          // way points elsewhere.
          let parent = dirname(head)
          try {
            parent = realpathSync.native(parent)
          } catch {
            // the spelling is the best there is
          }
          next = join(resolve(parent, link), ...tail)
        } else {
          const up = dirname(head)
          if (up === head) return current
          tail.unshift(basename(head))
          head = up
        }
      }
    }
    current = next
  }
  throw new Error("a chain of symbolic links in this path does not end")
}

function isInside(rel) {
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
}

// The part of path below the first root that holds it, or all of it. Only
// that part is tested, so a vault kept inside a folder named secrets works.
function below(roots, path) {
  for (const root of roots) {
    const rel = relative(root, path)
    if (isInside(rel)) return rel
  }
  return path
}

// The vault root in every spelling a path can arrive in. Pi resolves paths
// against its cwd, while the loader names this file by its real path, so on
// macOS, where /var is a link to /private/var, one vault has two spellings. The
// cwd's spelling is the nearest folder on its way up that really is the vault.
function rootsFor(vault, cwd) {
  const roots = [vault]
  const realVault = realPath(vault)
  if (!roots.includes(realVault)) roots.push(realVault)
  for (let dir = resolve(cwd); ; ) {
    if (relative(realPath(dir), realVault) === "") {
      if (!roots.includes(dir)) roots.push(dir)
      break
    }
    const up = dirname(dir)
    if (up === dir) break
    dir = up
  }
  return roots
}

// NTFS compares names by upper-casing them, which is why "ſecrets" opens
// SECRETS there, so the comparison upper-cases too. Windows also opens ".env "
// and ".env::$DATA" as ".env", so each part loses an NTFS stream suffix and its
// trailing dots and spaces before it is compared.
function namesSecret(path) {
  const parts = path
    .split(/[\\/]/)
    .map((part) => part.replace(/:.*$/s, "").replace(/[. ]+$/, "").toUpperCase())
  const base = parts[parts.length - 1]
  return base === ".ENV" || base.startsWith(".ENV.") || parts.includes("SECRETS")
}

// Tested twice: as named below the vault, which catches secrets/ even when it
// is a link to somewhere else, and as the real path, which catches a note that
// is a link to .env. Outside any vault the whole path is tested.
function isSecret(raw, cwd, vault) {
  const path = resolveLikePi(raw, cwd)
  if (vault === null) return namesSecret(path) || namesSecret(realPath(path))
  return namesSecret(below(rootsFor(vault, cwd), path)) || namesSecret(below([realPath(vault)], realPath(path)))
}

// ripgrep lets a glob that matches a file override .gitignore, so a grep glob
// that names a secret is refused: one whose text holds .env or secret in any
// case, and one that matches any of a few secret names and paths, read the way
// ripgrep reads a glob (* and ? stay within a name, ** crosses folders, [...]
// and {a,b} are sets, and a glob with no slash is matched against names). A
// glob can still reach a secret through wildcards alone, such as *.production
// for .env.production, and that is not refused: refusing every glob that could
// would refuse *.md too. A glob that only excludes (!...) widens nothing.
const SECRET_NAMES = [".ENV", ".ENV.LOCAL", "SECRETS"]
const SECRET_PATHS = [".ENV", "A/.ENV", "A/B/.ENV", ".ENV.LOCAL", "A/.ENV.LOCAL", "SECRETS", "SECRETS/X", "A/SECRETS",
  "A/SECRETS/X", "A/B/SECRETS/X"]
const MAX_GLOB = 256
const MAX_ALTERNATIVES = 32

// The alternatives a glob's {a,b} sets spell out, or null past MAX_ALTERNATIVES.
function braceAlternatives(glob) {
  let open = -1
  for (let i = 0; i < glob.length && open === -1; i++) {
    if (glob[i] === "\\") i++
    else if (glob[i] === "{") open = i
  }
  if (open === -1) return [glob]
  const parts = []
  let depth = 0
  let start = open + 1
  for (let i = open; i < glob.length; i++) {
    const c = glob[i]
    if (c === "\\") {
      i++
    } else if (c === "{") {
      depth++
    } else if (c === "," && depth === 1) {
      parts.push(glob.slice(start, i))
      start = i + 1
    } else if (c === "}" && --depth === 0) {
      parts.push(glob.slice(start, i))
      const out = []
      for (const part of parts) {
        const more = braceAlternatives(glob.slice(0, open) + part + glob.slice(i + 1))
        if (more === null || out.length + more.length > MAX_ALTERNATIVES) return null
        out.push(...more)
      }
      return out
    }
  }
  throw new Error("the glob has a { with no }")
}

// A [...] set at glob[p]: its test and where it ends, or null with no ].
function classAt(glob, p) {
  let i = p + 1
  const negated = glob[i] === "!" || glob[i] === "^"
  if (negated) i++
  const first = i
  if (glob[i] === "]") i++
  while (i < glob.length && glob[i] !== "]") i++
  if (i >= glob.length) return null
  const body = glob.slice(first, i)
  const test = (c) => {
    let inside = false
    for (let k = 0; k < body.length; k++) {
      if (body[k + 1] === "-" && k + 2 < body.length) {
        if (c >= body[k] && c <= body[k + 2]) inside = true
        k += 2
      } else if (body[k] === c) {
        inside = true
      }
    }
    return inside !== negated
  }
  return { test, end: i + 1 }
}

// Whether a glob with no braces matches all of text. Memoised over the two
// positions, so its time grows with their lengths multiplied, never
// exponentially the way a backtracking regex can with many stars.
function globMatches(glob, text) {
  const memo = new Map()
  const at = (p, s) => {
    const key = p * (text.length + 1) + s
    if (memo.has(key)) return memo.get(key)
    let hit = false
    const c = glob[p]
    if (p === glob.length) {
      hit = s === text.length
    } else if (c === "*") {
      let q = p
      while (glob[q] === "*") q++
      if (q - p >= 2 && glob[q] === "/") {
        hit = at(q + 1, s)
        for (let k = s; !hit && k < text.length; k++) if (text[k] === "/") hit = at(q + 1, k + 1)
      } else if (q - p >= 2) {
        for (let k = s; !hit && k <= text.length; k++) hit = at(q, k)
      } else {
        for (let k = s; !hit && k <= text.length; k++) {
          hit = at(q, k)
          if (text[k] === "/") break
        }
      }
    } else if (c === "?") {
      hit = s < text.length && text[s] !== "/" && at(p + 1, s + 1)
    } else if (c === "[" && classAt(glob, p) !== null) {
      const set = classAt(glob, p)
      hit = s < text.length && text[s] !== "/" && set.test(text[s]) && at(set.end, s + 1)
    } else {
      const escaped = c === "\\" && p + 1 < glob.length ? 1 : 0
      hit = s < text.length && text[s] === glob[p + escaped] && at(p + 1 + escaped, s + 1)
    }
    memo.set(key, hit)
    return hit
  }
  return at(0, 0)
}

// Windows ripgrep reads a backslash in a glob as a folder separator.
function globMaySeeSecret(raw) {
  if (raw.length > MAX_GLOB) throw new Error(`the glob is longer than ${MAX_GLOB} characters`)
  if (raw.startsWith("!")) return false
  const glob = (WINDOWS ? raw.replace(/\\/g, "/") : raw).replace(/^\/+/, "").toUpperCase()
  if (glob.includes(".ENV") || glob.includes("SECRET")) return true
  const alternatives = braceAlternatives(glob)
  if (alternatives === null) throw new Error(`the glob spells out more than ${MAX_ALTERNATIVES} alternatives`)
  return alternatives.some((alt) => (alt.includes("/") ? SECRET_PATHS : SECRET_NAMES).some((probe) => globMatches(alt, probe)))
}

// ---------------------------------------------------------------- vault --
// The vault is the nearest folder above this file that holds the lint and the
// checker, so starting Pi inside some other tree never runs that tree's
// scripts. When the loader does not say where this file is, no script runs.
function vaultAbove(start) {
  for (let dir = resolve(start); ; ) {
    if (existsSync(join(dir, LINT)) && existsSync(join(dir, CHECK))) return dir
    const up = dirname(dir)
    if (up === dir) return null
    dir = up
  }
}

// ----------------------------------------------------------------- bash --
// The scripts need bash. On Windows this is the one Pi's own bash tool would
// pick (shellPath in Pi's global settings, then Git under Program Files, then
// bash.exe on PATH), except that WSL's launcher is passed over, because the
// scripts are written for Git Bash. Elsewhere it is /bin/bash, then bash in a
// folder on PATH. Only absolute candidates are tried, so a bash in the vault or
// the current folder is never run.
function isWslLauncher(path) {
  const lower = resolve(path).toLowerCase()
  if (/^[a-z]:\\windows\\(?:system32|sysnative)\\bash\.exe$/.test(lower)) return true
  return [process.env.SystemRoot, process.env.windir]
    .filter((root) => typeof root === "string" && root !== "")
    .some((root) => ["System32", "Sysnative"].some((dir) => lower === join(root, dir, "bash.exe").toLowerCase()))
}

function piShellPath() {
  const env = process.env.PI_CODING_AGENT_DIR
  const agentDir = env ? expandTilde(env) ?? env : join(homedir(), ".pi", "agent")
  try {
    const value = JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8")).shellPath
    return typeof value === "string" && value !== "" ? expandTilde(value) ?? value : null
  } catch {
    return null
  }
}

function findBash() {
  const pathDirs = (process.env.PATH ?? "")
    .split(WINDOWS ? ";" : ":")
    .map((dir) => (WINDOWS ? dir.replace(/^"(.*)"$/, "$1") : dir))
    .filter((dir) => dir !== "" && isAbsolute(dir))
  if (!WINDOWS) {
    const candidates = ["/bin/bash", ...pathDirs.map((dir) => join(dir, "bash"))]
    return candidates.find((path) => existsSync(path)) ?? null
  }
  const candidates = []
  const custom = piShellPath()
  if (custom !== null) candidates.push(custom)
  for (const programs of [process.env.ProgramFiles, process.env["ProgramFiles(x86)"]]) {
    if (programs) candidates.push(join(programs, "Git", "bin", "bash.exe"))
  }
  for (const dir of pathDirs) candidates.push(join(dir, "bash.exe"))
  return candidates.find((path) => isAbsolute(path) && !isWslLauncher(path) && existsSync(path)) ?? null
}

const HOOK_TIMEOUT_MS = 15000
const REPORT_LIMIT = 4000

// Runs one hook script from the vault root, with CLAUDE_PROJECT_DIR naming the
// vault so an inherited one cannot send the scripts elsewhere. Resolves to
// { problem, report }: problem is null when the script exited 0, and report is
// what it wrote on stderr. On Windows every argument is quoted and passed as
// written, because Git Bash's runtime otherwise reads a ' as a quote, globs
// [ ] { } * ?, and treats @name as a file of arguments. It always settles:
// after HOOK_TIMEOUT_MS bash is stopped, and a second later the answer is
// given even if a process bash left behind still holds its stderr open.
function runHook(bash, vault, script, args, input) {
  return new Promise((done) => {
    const argv = [script, ...args]
    if (WINDOWS && argv.some((arg) => arg.includes('"'))) {
      done({ problem: "was given a path holding a double quote, which no Windows path can", report: "" })
      return
    }
    let report = ""
    let settled = false
    let child = null
    const timers = []
    const settle = (problem) => {
      if (settled) return
      settled = true
      for (const timer of timers) clearTimeout(timer)
      try {
        child?.stderr?.destroy()
      } catch {
        // already closed
      }
      const cut = report.length > REPORT_LIMIT
      done({ problem, report: cut ? `${report.slice(0, REPORT_LIMIT)}\n(cut off at ${REPORT_LIMIT} characters)` : report })
    }
    try {
      child = spawn(bash, WINDOWS ? argv.map((arg) => `"${arg}"`) : argv, {
        cwd: vault,
        env: { ...process.env, CLAUDE_PROJECT_DIR: vault },
        stdio: ["pipe", "ignore", "pipe"],
        windowsHide: true,
        timeout: HOOK_TIMEOUT_MS,
        ...(WINDOWS ? { windowsVerbatimArguments: true, argv0: `"${bash}"` } : {}),
      })
    } catch (error) {
      settle(`could not start ${bash} (${error.message})`)
      return
    }
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk) => {
      if (report.length <= REPORT_LIMIT) report += chunk
    })
    child.stderr.on("error", () => {})
    const verdict = (code, signal) => {
      if (code === 0) return null
      if (signal) return `was stopped by ${signal}, after the ${HOOK_TIMEOUT_MS / 1000} s limit or from outside`
      return `exited ${code} under ${bash}`
    }
    child.once("error", (error) => settle(`could not start ${bash} (${error.code ?? error.message})`))
    child.once("close", (code, signal) => settle(verdict(code, signal)))
    child.once("exit", (code, signal) => {
      timers.push(setTimeout(() => settle(verdict(code, signal)), 1000))
    })
    timers.push(setTimeout(() => {
      try {
        child.kill()
      } catch {
        // gone already
      }
      settle(`did not finish within ${HOOK_TIMEOUT_MS / 1000} s`)
    }, HOOK_TIMEOUT_MS + 1000))
    child.stdin.once("error", () => {})
    child.stdin.end(input)
  })
}

// ------------------------------------------------------------ extension --
export default function vaultExtension(pi) {
  const warned = new Set()
  const warn = (ctx, key, message) => {
    if (warned.has(key)) return
    warned.add(key)
    if (ctx?.hasUI) {
      try {
        ctx.ui.notify(message, "warning")
        return
      } catch {
        // fall through to stderr
      }
    }
    process.stderr.write(`${message}\n`)
  }

  const ownVault = HERE === null ? null : vaultAbove(HERE)
  // Found once, when a script first has to run.
  let bash
  const vaultsByCwd = new Map()
  const guardVault = (cwd) => {
    if (ownVault !== null) return ownVault
    if (!vaultsByCwd.has(cwd)) vaultsByCwd.set(cwd, vaultAbove(cwd))
    return vaultsByCwd.get(cwd)
  }

  // Runs a script of this extension's own vault. Resolves to what it reported.
  const runScript = async (ctx, script, argsFor, input) => {
    if (ownVault === null) {
      const where = HERE === null ? "Pi did not say where this extension's file is" : `no vault holds ${HERE}`
      warn(ctx, "vault", `vault: ${where}, so written notes are not linted and compactions are not recorded. See docs/harnesses/pi.md`)
      return ""
    }
    if (bash === undefined) bash = findBash()
    if (bash === null) {
      warn(ctx, "bash", `vault: no Git Bash found, so ${script} did not run. See docs/harnesses/pi.md`)
      return ""
    }
    const { problem, report } = await runHook(bash, ownVault, script, argsFor(ownVault), input)
    if (problem !== null) warn(ctx, script, `vault: ${script} ${problem}. See docs/harnesses/pi.md`)
    return report
  }

  pi.on("tool_call", async (event, ctx) => {
    if (!PATH_TOOLS.has(event?.toolName)) return undefined
    try {
      const input = event.input ?? {}
      // The guard only reads, so outside this extension's vault it may use
      // the vault Pi was started in, whose scripts it never runs.
      const vault = guardVault(ctx.cwd)
      if (typeof input.path === "string") {
        if (isSecret(input.path, ctx.cwd, vault)) return { block: true, reason: DENIED }
      } else if (PATH_REQUIRED.has(event.toolName)) {
        // Fail closed: Pi's schema requires a path here, so its absence means the
        // tool changed shape and this guard can no longer see what it opens.
        return { block: true, reason: NO_PATH }
      } else if (isSecret(".", ctx.cwd, vault)) {
        // grep, find and ls with no path search the folder Pi was started in.
        return { block: true, reason: DENIED }
      }
      if (event.toolName === "grep" && typeof input.glob === "string" && globMaySeeSecret(input.glob)) {
        return { block: true, reason: DENIED }
      }
      return undefined
    } catch (error) {
      return { block: true, reason: `vault: the secrets guard failed on this call (${error.message}), so it is refused` }
    }
  })

  pi.on("tool_result", async (event, ctx) => {
    if (!WRITE_TOOLS.has(event?.toolName) || event.isError) return undefined
    try {
      const raw = event.input?.path
      if (typeof raw !== "string" || raw === "") {
        warn(ctx, "no-path", `vault: a ${event.toolName} result carried no path, so the note was not linted`)
        return undefined
      }
      const file = resolveLikePi(raw, ctx.cwd)
      const report = await runScript(ctx, LINT, (vault) => ["--", below(rootsFor(vault, ctx.cwd), file).split(sep).join("/")], "")
      if (report.trim() === "") return undefined
      const content = Array.isArray(event.content) ? event.content : []
      return { content: [...content, { type: "text", text: `vault-lint (advisory):\n${report.trim()}` }] }
    } catch (error) {
      warn(ctx, "lint-failed", `vault: the lint step failed (${error.message})`)
      return undefined
    }
  })

  pi.on("session_compact", async (event, ctx) => {
    try {
      const session = ctx.sessionManager
      const payload = {
        session_id: session?.getSessionId?.() ?? "",
        trigger: event?.reason === "manual" ? "manual" : "auto",
      }
      const transcript = session?.getSessionFile?.()
      if (typeof transcript === "string" && transcript !== "") payload.transcript_path = transcript
      await runScript(ctx, STUB, () => [], JSON.stringify(payload))
    } catch (error) {
      warn(ctx, "stub-failed", `vault: recording the compaction failed (${error.message})`)
    }
  })
}
