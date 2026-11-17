#!/usr/bin/env node
// Drives the three sh scripts in ui/Service.qml (launch, installed check, swap)
// with fake omateams binaries on a controlled PATH, and checks the call sites
// pass the arguments the scripts expect ($0 = hostBinary, $1 = version).
const fs = require("fs")
const os = require("os")
const path = require("path")
const assert = require("assert")
const { test } = require("node:test")
const { spawnSync, execFileSync } = require("child_process")

const qml = fs.readFileSync(path.join(__dirname, "..", "ui", "Service.qml"), "utf8")

function script(name) {
  const m = qml.match(new RegExp("readonly property string " + name + ": ('(?:[^'\\\\]|\\\\.)*')"))
  assert(m, name + " not found in ui/Service.qml")
  return Function("return " + m[1])()
}
const launchScript = script("launchScript")
const installedScript = script("installedScript")
const swapScript = script("swapScript")

const has = (re, msg) => assert(re.test(qml), msg)
test("call sites pass the arguments the scripts expect", () => {
  has(/function hostCommand\(args\) \{ return \["sh", "-c", launchScript, hostBinary\]\.concat\(args\) \}/, "hostCommand")
  // Every launch goes through hostCommand: none may start hostBinary directly.
  assert(!/execDetached\(\[hostBinary/.test(qml), "a launch still starts hostBinary directly")
  has(/execDetached\(hostCommand\(\["--hidden"\]\)\)/, "maybeAutostart uses hostCommand")
  has(/execDetached\(hostCommand\(\[name\]\)\)/, "command() uses hostCommand")
  has(/\["sh", "-c", swapScript, hostBinary, wanted\]/, "maybeReplaceHost")
  has(/\["sh", "-c", installedScript, hostBinary\]/, "checkInstalled")
})

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "launch-test-"))
const sh = execFileSync("sh", ["-c", "command -v sh"], { encoding: "utf8" }).trim()
const log = path.join(tmp, "log")

// A fake omateams: appends {"who":..., "argv":[...]} to the log.
function fake(file, who) {
  fs.writeFileSync(file, `#!${sh}
printf '{"who":"${who}","argv":[' >> ${log}; s=""
for a in "$@"; do printf '%s"%s"' "$s" "$a" >> ${log}; s=,; done
printf ']}\\n' >> ${log}
`, { mode: 0o755 })
}

function makeBin(withFake) {
  const dir = fs.mkdtempSync(path.join(tmp, "bin-"))
  for (const t of ["sh", "mkdir", "sleep", "cat"]) {
    const p = execFileSync("sh", ["-c", "command -v " + t], { encoding: "utf8" }).trim()
    fs.symlinkSync(p, path.join(dir, t))
  }
  if (withFake) fake(path.join(dir, "omateams"), "PATH")
  return dir
}

const fallback = path.join(tmp, "fallback-omateams")
fake(fallback, "FALLBACK")
const missing = path.join(tmp, "nonexistent")

function run(scriptText, bin, fb, args, xdg) {
  return spawnSync(sh, ["-c", scriptText, fb, ...args], { env: { PATH: bin, XDG_RUNTIME_DIR: xdg || tmp } })
}
function lines() {
  return fs.existsSync(log) ? fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map(l => JSON.parse(l)) : []
}
const reset = () => fs.rmSync(log, { force: true })

test("launch prefers the PATH omateams", () => {
  reset()
  assert.strictEqual(run(launchScript, makeBin(true), fallback, ["--hidden"]).status, 0)
  assert.deepStrictEqual(lines(), [{ who: "PATH", argv: ["--hidden"] }])
})

test("launch falls back to $0", () => {
  reset()
  assert.strictEqual(run(launchScript, makeBin(false), fallback, ["--hidden"]).status, 0)
  assert.deepStrictEqual(lines(), [{ who: "FALLBACK", argv: ["--hidden"] }])
})

test("launch keeps an argument with a space as one entry", () => {
  reset()
  run(launchScript, makeBin(true), fallback, ["a b"])
  assert.deepStrictEqual(lines(), [{ who: "PATH", argv: ["a b"] }])
})

test("installed check", () => {
  assert.strictEqual(run(installedScript, makeBin(true), missing, []).status, 0)
  assert.strictEqual(run(installedScript, makeBin(false), fallback, []).status, 0)
  assert.notStrictEqual(run(installedScript, makeBin(false), missing, []).status, 0)
})

test("swap runs once per version", () => {
  reset()
  const xdg = fs.mkdtempSync(path.join(tmp, "xdg-"))
  const bin = makeBin(true)
  const quitThenHidden = [{ who: "PATH", argv: ["quit"] }, { who: "PATH", argv: ["--hidden"] }]
  assert.strictEqual(run(swapScript, bin, fallback, ["9.9.9"], xdg).status, 0)
  assert.deepStrictEqual(lines(), quitThenHidden)
  assert(fs.existsSync(path.join(xdg, "omateams", "swapped-9.9.9")))
  assert.strictEqual(run(swapScript, bin, fallback, ["9.9.9"], xdg).status, 0)
  assert.deepStrictEqual(lines(), quitThenHidden)
  run(swapScript, bin, fallback, ["9.9.10"], xdg)
  assert.deepStrictEqual(lines(), quitThenHidden.concat(quitThenHidden))
})

test("swap aborts when the marker can't be written", { skip: process.getuid() === 0 && "root ignores chmod" }, () => {
  reset()
  const xdg = fs.mkdtempSync(path.join(tmp, "ro-"))
  fs.chmodSync(xdg, 0o555)
  const r = run(swapScript, makeBin(true), fallback, ["9.9.9"], xdg)
  fs.chmodSync(xdg, 0o755)
  assert.notStrictEqual(r.status, 0)
  assert.deepStrictEqual(lines(), [])
})
