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
//     names.
//   - Runs .claude/hooks/vault-lint.sh on every file a write or edit changes.
//   - Records each compaction with .claude/hooks/postcompact-wrap-up.sh.
//
// Both scripts are advisory: their failures never fail the tool call. When one
// cannot run, the extension says so once instead of going quiet.

import { spawn } from "node:child_process"
import { existsSync, readFileSync, realpathSync } from "node:fs"
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
const UNICODE_SPACES = /[  -   　]/g

function windowsShellPath(path) {
  if (!path.startsWith("/") || path.startsWith("//") || path.includes("\\")) return path
  const match = path.match(/^\/(?:mnt\/|cygdrive\/)?([a-z])(?:\/(.*))?$/i)
  if (!match) return path
  const suffix = match[2]?.replaceAll("/", "\\")
  return `${match[1].toUpperCase()}:\\${suffix ?? ""}`
}

function expandTilde(path) {
  if (path === "~") return homedir()
  if (path.startsWith("~/") || (process.platform === "win32" && path.startsWith("~\\"))) {
    return join(homedir(), path.slice(2))
  }
  return null
}

function resolveLikePi(raw, cwd) {
  let path = raw.replace(UNICODE_SPACES, " ")
  if (path.startsWith("@")) path = path.slice(1)
  if (process.platform === "win32") path = windowsShellPath(path)
  const home = expandTilde(path)
  if (home !== null) path = home
  else if (/^file:\/\//.test(path)) path = fileURLToPath(path)
  return isAbsolute(path) ? resolve(path) : resolve(cwd, path)
}

// The part of path below root, or all of it when it lies outside root. Only
// that part is tested, so a vault kept inside a folder named secrets still works.
function below(root, path) {
  const rel = relative(root, path)
  const inside = rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
  return inside ? rel : path
}

// The real path of the nearest part of path that exists, with the rest put
// back, so a link to .env, or a new file inside a linked secrets folder, is
// seen for what it is.
function realPath(path) {
  const tail = []
  for (let head = path; ; ) {
    try {
      return join(realpathSync.native(head), ...tail)
    } catch {
      const up = dirname(head)
      if (up === head) return path
      tail.unshift(basename(head))
      head = up
    }
  }
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

function isSecret(raw, cwd, root) {
  const path = resolveLikePi(raw, cwd)
  const top = root ?? cwd
  return namesSecret(below(top, path)) || namesSecret(below(realPath(top), realPath(path)))
}

// ---------------------------------------------------------------- vault --
// The vault is the nearest folder above this file that holds the lint and the
// checker, so starting Pi inside some other tree never runs that tree's
// scripts. Only when the loader gives no file location is Pi's cwd used.
function vaultAbove(start) {
  for (let dir = resolve(start); ; ) {
    if (existsSync(join(dir, LINT)) && existsSync(join(dir, CHECK))) return dir
    const up = dirname(dir)
    if (up === dir) return null
    dir = up
  }
}

// Relative to the vault with forward slashes when the file is inside it.
function lintArg(vault, file) {
  return below(vault, file).split(sep).join("/")
}

// ----------------------------------------------------------------- bash --
// The scripts need bash. On Windows this is the one Pi's own bash tool would
// pick (shellPath in Pi's global settings, then Git under Program Files, then
// bash.exe on PATH), except that WSL's launcher in System32 is passed over,
// because the scripts are written for Git Bash. Only absolute candidates are
// tried, so a bash.exe in the vault or the current folder is never run.
function isWslLauncher(path) {
  return /^[a-z]:\\windows\\(?:system32|sysnative)\\bash\.exe$/i.test(path.replace(/\//g, "\\"))
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
  if (process.platform !== "win32") return existsSync("/bin/bash") ? "/bin/bash" : "bash"
  const candidates = []
  const custom = piShellPath()
  if (custom !== null) candidates.push(custom)
  for (const programs of [process.env.ProgramFiles, process.env["ProgramFiles(x86)"]]) {
    if (programs) candidates.push(join(programs, "Git", "bin", "bash.exe"))
  }
  for (const dir of (process.env.PATH ?? "").split(";")) {
    if (dir !== "" && isAbsolute(dir)) candidates.push(join(dir, "bash.exe"))
  }
  return candidates.find((path) => isAbsolute(path) && !isWslLauncher(path) && existsSync(path)) ?? null
}

// Runs one hook script from the vault root and resolves to null when it exited
// 0, or to what went wrong. Both scripts always exit 0 by design, so anything
// else is a setup problem worth saying out loud.
function runHook(bash, vault, script, args, input) {
  return new Promise((done) => {
    let child
    try {
      child = spawn(bash, [script, ...args], {
        cwd: vault,
        stdio: ["pipe", "ignore", "ignore"],
        windowsHide: true,
        timeout: 15000,
      })
    } catch (error) {
      done(`could not start ${bash} (${error.message})`)
      return
    }
    child.once("error", (error) => done(`could not start ${bash} (${error.code ?? error.message})`))
    child.once("close", (code, signal) => {
      if (code === 0) done(null)
      else if (signal) done(`was stopped by ${signal}, after the 15 s limit or from outside`)
      else done(`exited ${code} under ${bash}`)
    })
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
  const vaultFor = (ctx) => ownVault ?? (HERE === null ? vaultAbove(ctx.cwd) : null)

  const runScript = async (ctx, script, argsFor, input) => {
    const vault = vaultFor(ctx)
    if (vault === null) {
      warn(ctx, "vault", `vault: no vault holds ${HERE ?? ctx.cwd}, so written notes are not linted and compactions are not recorded. See docs/harnesses/pi.md`)
      return
    }
    const bash = findBash()
    if (bash === null) {
      warn(ctx, "bash", `vault: no Git Bash found, so ${script} did not run. See docs/harnesses/pi.md`)
      return
    }
    const problem = await runHook(bash, vault, script, argsFor(vault), input)
    if (problem !== null) warn(ctx, script, `vault: ${script} ${problem}. See docs/harnesses/pi.md`)
  }

  pi.on("tool_call", async (event, ctx) => {
    if (!PATH_TOOLS.has(event?.toolName)) return undefined
    try {
      const input = event.input ?? {}
      if (typeof input.path === "string") {
        if (isSecret(input.path, ctx.cwd, vaultFor(ctx) ?? undefined)) return { block: true, reason: DENIED }
      } else if (PATH_REQUIRED.has(event.toolName)) {
        // Fail closed: Pi's schema requires a path here, so its absence means the
        // tool changed shape and this guard can no longer see what it opens.
        return { block: true, reason: NO_PATH }
      }
      if (event.toolName === "grep" && typeof input.glob === "string" && namesSecret(input.glob)) {
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
      await runScript(ctx, LINT, (vault) => ["--", lintArg(vault, file)], "")
    } catch (error) {
      warn(ctx, "lint-failed", `vault: the lint step failed (${error.message})`)
    }
    return undefined
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
