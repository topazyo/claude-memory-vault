// .claude/adapters/omp/vault.js
// Oh My Pi (omp) extension for this vault. Setup and verification: docs/harnesses/omp.md.
//
// OPT-IN. omp runs every extension in .omp/extensions/ and every hook in
// .omp/hooks/ of the folder it starts in, with no project trust gate at all
// (its extension API answers that every project is trusted), so a file shipped
// there would run on every clone of the vault. This file ships where omp does
// not look. Load it with `omp -e .claude/adapters/omp/vault.js`, or copy it to
// .omp/extensions/vault.js, once you have read it. Not both, or it runs twice.
//
// Written against omp 18.18.9 (github.com/can1357/oh-my-pi, commit 50da2d3,
// read 2026-11-12). It derives from .claude/adapters/pi/vault.js, whose path
// and glob tests it keeps, and differs where omp's tools differ.
//
//   - Refuses a file-tool call whose path names .env or .env.*, or passes
//     through or ends at a part named secrets, the three paths
//     .claude/rules/security.md has Claude Code deny. It reads every path field
//     of omp's file tools, each part of a ";" list, the file names inside an
//     edit's patch text, and a grep or glob pattern, and it refuses a read of a
//     path that does not exist when omp's search for it below the folder would
//     open a secret. omp's bash and eval tools can still read them, so this
//     keeps the file tools from doing it by accident.
//   - Runs .claude/hooks/vault-lint.sh on every file a write, edit or applied
//     ast_edit changed, and adds what it reports to the tool's result.
//   - Records each compaction with .claude/hooks/postcompact-wrap-up.sh, as
//     manual or auto.
//
// Both scripts are advisory: their failures never fail the tool call. When one
// cannot run, the extension says so once instead of going quiet.

import { spawn } from "node:child_process"
import { existsSync, lstatSync, readdirSync, readlinkSync, realpathSync } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path"
import { fileURLToPath } from "node:url"

const LINT = ".claude/hooks/vault-lint.sh"
const STUB = ".claude/hooks/postcompact-wrap-up.sh"
const CHECK = ".claude/scripts/vault-check.sh"
const DENIED = "vault: .env, .env.* and secrets/ are off limits (.claude/rules/security.md)"
const NO_PATH = "vault: the secrets guard found no path in this call, so it is refused. omp's tool input may have changed shape: see docs/harnesses/omp.md"
const NOT_TEXT = "vault: the secrets guard cannot read a path in this call, so it is refused. omp's tool input may have changed shape: see docs/harnesses/omp.md"
const NO_GITIGNORE = "vault: a grep that ignores .gitignore would read .env and secrets/, so it is refused (.claude/rules/security.md)"
const WINDOWS = process.platform === "win32"
const CASE_BLIND = WINDOWS || process.platform === "darwin"

// The folder this file is in. omp imports an extension by its real path with a
// query string added, so the URL is read without it.
let HERE = null
try {
  HERE = fileURLToPath(new URL(".", import.meta.url)).replace(/[\\/]+$/, "")
} catch {
  HERE = null
}

// ---------------------------------------------------------------- paths --
// Where omp's file tools will look for a path the model gave them. This follows
// expandPath, normalizeAtPrefix and normalizeWindowsDriveAliasPath in omp's
// src/tools/path-utils.ts at 18.18.9, and where omp reads one string in more
// than one way, every way is tested, because the guard has to test the file omp
// is about to open, not the string it got.
const UNICODE_SPACES = /[\u{A0}\u{2000}-\u{200A}\u{202F}\u{205F}\u{3000}]/gu
const URL_SCHEME = /^([a-z][a-z0-9+.-]*):\/\//i

function windowsDriveAlias(path) {
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

// Every absolute path omp could read the string as: with and without a
// leading : or @ (omp drops @ only before some forms, and testing both costs
// nothing), and with a \\?\ prefix dropped.
function candidatesLikeOmp(raw, cwd) {
  const spaced = raw.replace(UNICODE_SPACES, " ")
  const forms = new Set([spaced])
  for (const form of [...forms]) {
    if (form.startsWith(":")) forms.add(form.slice(1))
  }
  for (const form of [...forms]) {
    // write unwraps a hashline header, [PATH#TAG], and edits name files as ¶PATH.
    const header = form.match(/^\[(.+?)(?:#[0-9A-Fa-f]{4})?\]$/)
    if (header !== null) forms.add(header[1])
    if (form.startsWith("¶")) forms.add(form.slice(1).trim())
  }
  for (const form of [...forms]) {
    if (form.startsWith("@")) forms.add(form.slice(1))
  }
  const out = []
  for (let path of forms) {
    if (path.startsWith("\\\\?\\")) path = path.slice(4)
    if (/^file:\/\//i.test(path)) {
      try {
        path = fileURLToPath(path)
      } catch {
        // not a file URL omp could read either; tested as written below
      }
    }
    if (WINDOWS) path = windowsDriveAlias(path)
    const home = expandTilde(path)
    if (home !== null) path = home
    out.push(isAbsolute(path) ? resolve(path) : resolve(cwd, path))
  }
  return out
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

// The vault root in every spelling a path can arrive in. omp resolves paths
// against its cwd, while the loader names this file by its real path, so on
// macOS, where /var is a link to /private/var, one vault has two spellings. The
// cwd's spelling is the nearest folder on its way up that really is the vault.
const rootsCache = new Map()

function rootsFor(vault, cwd) {
  const key = `${vault}\u{0}${cwd}`
  if (!rootsCache.has(key)) rootsCache.set(key, findRoots(vault, cwd))
  return rootsCache.get(key)
}

function findRoots(vault, cwd) {
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

// Tested twice for each way omp could read the string: as named below the
// vault, which catches secrets/ even when it is a link to somewhere else, and as
// the real path, which catches a note that is a link to .env. Outside any vault
// the whole path is tested. A URL other than file:// is tested as written: its
// text may still name a secret in an omp scheme that reads files.
function isSecret(raw, cwd, vault) {
  const scheme = raw.match(URL_SCHEME)
  if (scheme !== null && scheme[1].toLowerCase() !== "file") return namesSecret(raw)
  return candidatesLikeOmp(raw, cwd).some((path) => {
    if (vault === null) return namesSecret(path) || namesSecret(realPath(path))
    return namesSecret(below(rootsFor(vault, cwd), path)) || namesSecret(below([realPath(vault)], realPath(path)))
  })
}

// omp's read, ast_grep and ast_edit take ";" lists of paths. The whole string
// is tested as well as each part, so a name holding a ";" is tested either way.
function listParts(raw) {
  const parts = raw.split(";").map((part) => part.trim()).filter((part) => part !== "")
  return parts.includes(raw) ? parts : [raw, ...parts]
}

// --------------------------------------------------------- read fallback --
// When a read names a file that does not exist, omp searches the folder it was
// started in for **/<path>, hidden files included, and opens the match when
// there is one, so `read api.key` can open secrets/api.key. For such a path
// the guard looks for a secret whose path ends in it, by walking the folder the
// way that search would, and refuses the read when one does or when the walk
// is cut short. A path that exists, or that is a URL, never reaches this.
const WALK_LIMIT = 20000
const WALK_SKIP = new Set([".git", "node_modules"])

function missingLocally(raw, cwd) {
  if (URL_SCHEME.test(raw)) return false
  return candidatesLikeOmp(raw, cwd).every((path) => {
    // A ":" tail may be a line selector, so the path before it counts too.
    const plain = path.replace(/(.):[^\\/:]*$/, "$1")
    return !existsSync(path) && !existsSync(plain)
  })
}

function fallbackOpensSecret(raw, cwd) {
  const want = raw.replace(UNICODE_SPACES, " ").replace(/^[:@]+/, "").replace(/\\/g, "/").replace(/^\.\//, "").replace(/:[^/:]*$/, "")
  if (want === "" || isAbsolute(want) || want.startsWith("~") || want.split("/").includes("..")) return false
  const fold = (text) => (CASE_BLIND ? text.toUpperCase() : text)
  const tail = fold(`/${want}`)
  let seen = 0
  const walk = (dir, rel) => {
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return false
    }
    for (const entry of entries) {
      if (++seen > WALK_LIMIT) throw new Error(`the folder holds more than ${WALK_LIMIT} entries`)
      if (WALK_SKIP.has(entry.name)) continue
      const path = rel === "" ? entry.name : `${rel}/${entry.name}`
      if (namesSecret(path) && fold(`/${path}`).endsWith(tail)) return true
      if (entry.isDirectory() && walk(join(dir, entry.name), path)) return true
    }
    return false
  }
  return walk(resolve(cwd), "")
}

// ----------------------------------------------------------- tool inputs --
// The strings each file tool reads as a path or a pattern, from omp 18.18.9's
// tool schemas: kind "path" is tested as a path, "pattern" as a glob over the
// folder, "names" as a glob that only lists names. A field holding anything
// but text, or a required one missing, fails the call closed.
const IS_GLOB = /[*?[{]/

function textOf(value) {
  if (value === undefined || value === null) return []
  if (typeof value === "string") return [value]
  if (Array.isArray(value) && value.every((item) => typeof item === "string")) return value
  throw new Error(NOT_TEXT)
}

// The files an edit's text names: apply_patch's *** Add/Update/Delete File:
// and *** Move to: lines, the hashline [PATH#TAG] and legacy ¶PATH headers, and
// a hashline MV destination. omp derives a path only from the hashline headers.
function patchPaths(text) {
  const out = []
  for (const line of text.split(/\r?\n/)) {
    let match = line.match(/^\*\*\* (?:Add|Update|Delete) File:\s*(.+?)\s*$/) ?? line.match(/^\*\*\* Move to:\s*(.+?)\s*$/)
    if (match === null) match = line.match(/^\[(.+)#[0-9A-Fa-f]{4}\]\s*$/) ?? line.match(/^\[(.+)\]\s*$/)
    if (match === null) match = line.match(/^¶\s*(.+?)\s*$/) ?? line.match(/^MV\s+(.+?)\s*$/)
    if (match !== null) out.push(match[1])
  }
  return out
}

// What a call reads or writes, as [kind, text] pairs, or null when the tool is
// none of omp's file tools.
function targetsOf(toolName, input) {
  const pairs = (kind, value) => textOf(value).map((text) => [kind, text])
  switch (toolName) {
    case "read":
    case "write": {
      const paths = textOf(input.path)
      if (paths.length === 0) throw new Error(NO_PATH)
      return paths.map((text) => ["path", text])
    }
    case "edit": {
      const out = [...pairs("path", input.path), ...pairs("path", input.paths)]
      if (typeof input.input === "string") out.push(...patchPaths(input.input).map((text) => ["path", text]))
      else if (input.input !== undefined) throw new Error(NOT_TEXT)
      if (Array.isArray(input.edits)) for (const edit of input.edits) out.push(...pairs("path", edit?.rename))
      if (out.length === 0) throw new Error(NO_PATH)
      return out
    }
    case "grep":
    case "search":
    case "ast_grep":
      return input.path === undefined || input.path === null ? [["path", "."]] : pairs("pattern", input.path)
    case "ast_edit":
      return input.paths === undefined || input.paths === null ? [["path", "."]] : pairs("pattern", input.paths)
    case "glob":
      return input.path === undefined || input.path === null ? [["path", "."]] : pairs("names", input.path)
    case "find":
      return input.path === undefined || input.path === null ? [["path", "."]] : pairs("path", input.path)
    case "lsp":
      return pairs("path", input.file)
    case "debug":
      return [...pairs("path", input.program), ...pairs("path", input.file), ...pairs("path", input.cwd)]
    case "security_scan":
      return [...pairs("path", input.include_paths), ...pairs("path", input.knowledge_base_paths), ...pairs("path", input.output_root)]
    default:
      return null
  }
}

// Whether one target may reach a secret. A pattern holding no glob character
// is a path. A glob is tested by its text and by the folder it starts in, and
// a pattern glob that searches contents also by what its parts can match.
function targetMaySeeSecret(kind, text, cwd, vault, toolName) {
  for (const part of kind === "path" && toolName !== "read" && toolName !== "ast_grep" ? [text] : listParts(text)) {
    if (kind === "path" || !IS_GLOB.test(part)) {
      if (isSecret(part, cwd, vault)) return true
      if (toolName === "read" && missingLocally(part, cwd) && fallbackOpensSecret(part, cwd)) return true
      continue
    }
    const folded = part.toUpperCase()
    if (folded.includes(".ENV") || folded.includes("SECRET")) return true
    const literal = part.slice(0, part.search(IS_GLOB)).replace(/[^\\/]*$/, "")
    if (literal !== "" && isSecret(literal, cwd, vault)) return true
    if (kind === "pattern" && globMaySeeSecret(part)) return true
  }
  return false
}

// ripgrep lets a glob that matches a file override .gitignore, so a grep glob
// that names a secret is refused. Read the way ripgrep reads a glob (* and ?
// stay within a name, ** crosses folders, [...] and {a,b} are sets), it is
// refused when:
//   - its text holds .env or secret in any case;
//   - its last part matches .env, .env.local or secrets, or spells a name
//     starting .env. with ?, [...] or {...} standing in for letters of .env;
//   - or a folder part other than * or ** matches secrets.
// The parts are split at each / outside a [...] set, and at an escaped \/ as
// well, which ripgrep reads as a /. A set that could match a / (one holding
// /, a negated one that does not exclude /, or a range across /) is tried both
// as one character and as a /, so no set can hide where one folder ends; a
// glob with more than MAX_SLASH_SETS such sets is not decided.
// Letters are compared without regard to case, and a [...] set is tried with
// both cases of a letter, because ripgrep compares case as written while the
// file on disk may be spelled either way. A glob that reaches a .env.* name
// other than .env.local only through a * standing in for some or all of .env,
// such as *.production for .env.production, is let through: refusing it would
// refuse *.md too. * and *.local still match .env and .env.local themselves.
// A glob that only excludes (!...) widens nothing.
const SECRET_NAMES = [".env", ".env.local", "secrets"]
const MAX_GLOB = 256
const MAX_ALTERNATIVES = 32
const MAX_SLASH_SETS = 4

// The alternatives a glob's {a,b} sets spell out, or null past MAX_ALTERNATIVES.
// A [...] set is one character, so a { , or } inside one is not a brace.
function braceAlternatives(glob) {
  let open = -1
  for (let i = 0; i < glob.length && open === -1; i++) {
    if (glob[i] === "\\") i++
    else if (glob[i] === "[" && classAt(glob, i) !== null) i = classAt(glob, i).end - 1
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
    } else if (c === "[" && classAt(glob, i) !== null) {
      i = classAt(glob, i).end - 1
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

// A [...] set at glob[p]: its test and where it ends, or null with no ]. It is
// read as ripgrep's globset reads it: a ] or - that comes first is itself, and
// a - with a character after it, following a range, moves that range's end, so
// [a-b-z] is a to z. A range that runs backwards is an error to ripgrep, which
// then reads nothing, and here it matches nothing.
function classAt(glob, p) {
  let i = p + 1
  const negated = glob[i] === "!" || glob[i] === "^"
  if (negated) i++
  const ranges = []
  let first = true
  let inRange = false
  for (; i < glob.length; i++) {
    const c = glob[i]
    if (c === "]" && !first) break
    if (inRange) {
      ranges[ranges.length - 1][1] = c
      inRange = false
    } else if (c === "-" && !first) {
      inRange = true
    } else {
      ranges.push([c, c])
    }
    first = false
  }
  if (i >= glob.length) return null
  if (inRange) ranges.push(["-", "-"])
  const one = (c) => ranges.some(([low, high]) => c >= low && c <= high) !== negated
  // Either case of the letter will do, since the name on disk may be either.
  const test = (c) => one(c) || one(c.toLowerCase()) || one(c.toUpperCase())
  return { test, end: i + 1 }
}

function sameLetter(a, b) {
  return a === b || a.toLowerCase() === b.toLowerCase() || a.toUpperCase() === b.toUpperCase()
}

// Whether a glob with no braces matches all of text, or with prefix set only
// its start (whatever follows can always be matched by something). A * may not
// consume any of the first starFrom characters of text. Memoised over the two
// positions, so its time grows with their lengths multiplied, never
// exponentially the way a backtracking regex can with many stars.
function globMatches(glob, text, prefix = false, starFrom = 0) {
  const memo = new Map()
  const at = (p, s) => {
    const key = p * (text.length + 1) + s
    if (memo.has(key)) return memo.get(key)
    let hit = false
    const c = glob[p]
    const reach = s < starFrom ? s : text.length
    if (prefix && s === text.length) {
      hit = true
    } else if (p === glob.length) {
      hit = s === text.length
    } else if (c === "*") {
      let q = p
      while (glob[q] === "*") q++
      if (q - p >= 2 && glob[q] === "/") {
        hit = at(q + 1, s)
        for (let k = s; !hit && k < reach; k++) if (text[k] === "/") hit = at(q + 1, k + 1)
      } else if (q - p >= 2) {
        for (let k = s; !hit && k <= reach; k++) hit = at(q, k)
      } else {
        for (let k = s; !hit && k <= reach; k++) {
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
      hit = s < text.length && sameLetter(text[s], glob[p + escaped]) && at(p + 1 + escaped, s + 1)
    }
    memo.set(key, hit)
    return hit
  }
  return at(0, 0)
}

// Where a glob's [...] sets that could match a / start.
function slashSets(glob) {
  const starts = []
  for (let i = 0; i < glob.length; i++) {
    const set = glob[i] === "[" ? classAt(glob, i) : null
    if (glob[i] === "\\") {
      i++
    } else if (set !== null) {
      if (set.test("/")) starts.push(i)
      i = set.end - 1
    }
  }
  return starts
}

// A glob's parts, split at each / that ends a folder: never one inside a
// [...] set, but an escaped \/, and each set whose start is in asSlash.
function globParts(glob, asSlash) {
  const parts = [""]
  for (let i = 0; i < glob.length; i++) {
    const set = glob[i] === "[" ? classAt(glob, i) : null
    if (glob[i] === "\\" && i + 1 < glob.length) {
      if (glob[i + 1] === "/") parts.push("")
      else parts[parts.length - 1] += glob.slice(i, i + 2)
      i++
    } else if (set !== null) {
      if (asSlash.has(i)) parts.push("")
      else parts[parts.length - 1] += glob.slice(i, set.end)
      i = set.end - 1
    } else if (glob[i] === "/") {
      parts.push("")
    } else {
      parts[parts.length - 1] += glob[i]
    }
  }
  return parts
}

function partsMaySeeSecret(parts) {
  const name = parts[parts.length - 1]
  if (SECRET_NAMES.some((probe) => globMatches(name, probe))) return true
  if (globMatches(name, ".env.", true, 4)) return true
  return parts.slice(0, -1).some((part) => part !== "*" && part !== "**" && globMatches(part, "secrets"))
}

// ripgrep's ignore crate builds each glob with backslash_escape, and this test
// reads a backslash as that escape. On Windows, where a backslash also
// separates folders in a path, a glob holding one is not decided at all: it is
// refused, and / works there instead. Like a .gitignore line, the glob first
// loses its trailing white space, unless it ends in an escaped space. ripgrep
// trims what Rust calls white space, which includes U+0085 where JavaScript's
// \s does not, so both sets are trimmed.
function globMaySeeSecret(raw) {
  if (raw.length > MAX_GLOB) throw new Error(`the glob is longer than ${MAX_GLOB} characters`)
  const line = raw.endsWith("\\ ") ? raw : raw.replace(/[\s\u{85}]+$/u, "")
  if (line.startsWith("!")) return false
  if (WINDOWS && line.includes("\\")) throw new Error("on Windows the glob holds a backslash; write / instead")
  const glob = line.replace(/^\/+/, "")
  const folded = glob.toUpperCase()
  if (folded.includes(".ENV") || folded.includes("SECRET")) return true
  const alternatives = braceAlternatives(glob)
  if (alternatives === null) throw new Error(`the glob spells out more than ${MAX_ALTERNATIVES} alternatives`)
  return alternatives.some((alt) => {
    const sets = slashSets(alt)
    if (sets.length > MAX_SLASH_SETS) throw new Error(`the glob has more than ${MAX_SLASH_SETS} [...] sets that could match a /`)
    // Every way of reading those sets, each as one character or as a /.
    for (let mask = 0; mask < 2 ** sets.length; mask++) {
      const asSlash = new Set(sets.filter((_, k) => (mask >> k) & 1))
      if (partsMaySeeSecret(globParts(alt, asSlash))) return true
    }
    return false
  })
}

// ---------------------------------------------------------------- vault --
// The vault is the nearest folder above this file that holds the lint and the
// checker, so starting omp inside some other tree never runs that tree's
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
// The scripts need bash. On Windows that is Git Bash under Program Files, then
// bash.exe in a folder on PATH, except WSL's launcher, because the scripts are
// written for Git Bash. Elsewhere it is /bin/bash, then bash in a folder on
// PATH. Only absolute candidates are tried, so a bash in the vault or the
// current folder is never run.
function isWslLauncher(path) {
  const lower = resolve(path).toLowerCase()
  if (/^[a-z]:\\windows\\(?:system32|sysnative)\\bash\.exe$/.test(lower)) return true
  return [process.env.SystemRoot, process.env.windir]
    .filter((root) => typeof root === "string" && root !== "")
    .some((root) => ["System32", "Sysnative"].some((dir) => lower === join(root, dir, "bash.exe").toLowerCase()))
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
    // First, before anything touches its pipes: Node reports some start
    // failures, such as running out of file handles, as a later error event on
    // a child that has no pipes at all. The listener stays for good, because an
    // error event nobody listens for would be thrown inside the harness.
    child.on("error", (error) => settle(`could not start ${bash} (${error.code ?? error.message})`))
    if (!child.stdin || !child.stderr) {
      settle(`could not start ${bash} (no pipes to it)`)
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
    child.once("close", (code, signal) => settle(verdict(code, signal)))
    child.once("exit", (code, signal) => {
      if (!settled) timers.push(setTimeout(() => settle(verdict(code, signal)), 1000))
    })
    timers.push(setTimeout(() => {
      try {
        child.kill("SIGKILL")
      } catch {
        // gone already
      }
      settle(`did not finish within ${HOOK_TIMEOUT_MS / 1000} s`)
    }, HOOK_TIMEOUT_MS + 1000))
    child.stdin.on("error", () => {})
    child.stdin.end(input)
  })
}

// The files a successful write, edit or applied ast_edit changed, from the
// result where omp reports them (an edit's per-file results carry the path
// after a move) and from the call's own input otherwise.
function changedFiles(event, cwd) {
  const details = event.details ?? {}
  const input = event.input ?? {}
  const out = []
  const add = (value, base = cwd) => {
    if (typeof value === "string" && value !== "") out.push(candidatesLikeOmp(value, base)[0])
  }
  if (event.toolName === "write") {
    add(input.path)
  } else if (event.toolName === "edit") {
    if (Array.isArray(details.perFileResults) && details.perFileResults.length > 0) {
      for (const result of details.perFileResults) add(result?.path)
    } else if (typeof details.path === "string" && details.path !== "") {
      add(details.move ?? details.path)
    } else {
      add(input.path)
      if (Array.isArray(input.paths)) for (const path of input.paths) add(path)
    }
  } else if (event.toolName === "ast_edit" && details.applied === true && Array.isArray(details.fileReplacements)) {
    const base = typeof details.searchPath === "string" && details.searchPath !== "" ? details.searchPath : cwd
    for (const replacement of details.fileReplacements) add(replacement?.path, base)
  }
  return [...new Set(out)]
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
      const where = HERE === null ? "omp did not say where this extension's file is" : `no vault holds ${HERE}`
      warn(ctx, "vault", `vault: ${where}, so written notes are not linted and compactions are not recorded. See docs/harnesses/omp.md`)
      return ""
    }
    if (bash === undefined) bash = findBash()
    if (bash === null) {
      warn(ctx, "bash", `vault: no ${WINDOWS ? "Git Bash" : "bash"} found, so ${script} did not run. See docs/harnesses/omp.md`)
      return ""
    }
    const { problem, report } = await runHook(bash, ownVault, script, argsFor(ownVault), input)
    if (problem !== null) warn(ctx, script, `vault: ${script} ${problem}. See docs/harnesses/omp.md`)
    return report
  }

  // A block is a refusal of one call, the only answer this extension gives
  // omp's tool_call event. It never changes a call's input and never answers an
  // approval, so it can only make omp do less.
  pi.on("tool_call", async (event, ctx) => {
    try {
      const input = event?.input ?? {}
      const targets = targetsOf(event?.toolName, input)
      if (targets === null) return undefined
      const cwd = typeof ctx?.cwd === "string" && ctx.cwd !== "" ? ctx.cwd : process.cwd()
      // The guard only reads, so outside this extension's vault it may use the
      // vault omp was started in, whose scripts it never runs.
      const vault = guardVault(cwd)
      if ((event.toolName === "grep" || event.toolName === "search") && input.gitignore === false) {
        return { block: true, reason: NO_GITIGNORE }
      }
      for (const [kind, text] of targets) {
        if (targetMaySeeSecret(kind, text, cwd, vault, event.toolName)) return { block: true, reason: DENIED }
      }
      return undefined
    } catch (error) {
      const reason = error.message === NO_PATH || error.message === NOT_TEXT ? error.message : `vault: the secrets guard failed on this call (${error.message}), so it is refused`
      return { block: true, reason }
    }
  })

  pi.on("tool_result", async (event, ctx) => {
    if (!["write", "edit", "ast_edit"].includes(event?.toolName) || event.isError) return undefined
    try {
      const cwd = typeof ctx?.cwd === "string" && ctx.cwd !== "" ? ctx.cwd : process.cwd()
      const files = changedFiles(event, cwd)
      if (files.length === 0) {
        if (event.toolName !== "ast_edit") warn(ctx, "no-path", `vault: a ${event.toolName} result carried no path, so the note was not linted`)
        return undefined
      }
      const report = await runScript(
        ctx,
        LINT,
        (vault) => ["--", ...files.map((file) => below(rootsFor(vault, cwd), file).split(sep).join("/"))],
        "",
      )
      if (report.trim() === "") return undefined
      const content = Array.isArray(event.content) ? event.content : []
      return { content: [...content, { type: "text", text: `vault-lint (advisory):\n${report.trim()}` }] }
    } catch (error) {
      warn(ctx, "lint-failed", `vault: the lint step failed (${error.message})`)
      return undefined
    }
  })

  // omp's session_compact does not say why it ran. Automatic compaction is
  // bracketed by auto_compaction_start and auto_compaction_end, and /compact is
  // not, so a compaction inside that bracket is recorded as auto and any other
  // as manual (omp 18.18.9, src/session/session-maintenance.ts).
  let autoCompacting = false
  pi.on("auto_compaction_start", async () => {
    autoCompacting = true
  })
  pi.on("auto_compaction_end", async () => {
    autoCompacting = false
  })
  pi.on("session_compact", async (event, ctx) => {
    const trigger = autoCompacting ? "auto" : "manual"
    try {
      const session = ctx?.sessionManager
      const payload = { session_id: session?.getSessionId?.() ?? "", trigger }
      const transcript = session?.getSessionFile?.()
      if (typeof transcript === "string" && transcript !== "") payload.transcript_path = transcript
      await runScript(ctx, STUB, () => [], JSON.stringify(payload))
    } catch (error) {
      warn(ctx, "stub-failed", `vault: recording the compaction failed (${error.message})`)
    }
  })
}
