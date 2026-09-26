import { test } from "node:test";
import * as assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { prepareProfilePrompt } from "../extensions/context-resolver.ts";

function fixture(profiles: string[]) {
  const agentDir = mkdtempSync(join(tmpdir(), "context-resolver-"));
  mkdirSync(join(agentDir, "profiles"));
  for (const profile of profiles) writeFileSync(join(agentDir, "profiles", `${profile}.md`), `# ${profile}`);
  return agentDir;
}

function count(text: string, needle: string) {
  return text.split(needle).length - 1;
}

test("default profile is injected when AGENTS.md has no sentinel", () => {
  const agentDir = fixture(["default"]);
  const result = prepareProfilePrompt("# core", agentDir, "default");
  assert.equal(result.prompt, "@~/.pi/agent/profiles/default.md\n# core");
});

test("selected non-default profile is injected without a sentinel", () => {
  const agentDir = fixture(["default", "ntv"]);
  const result = prepareProfilePrompt("# core", agentDir, "ntv");
  assert.equal(result.prompt, "@~/.pi/agent/profiles/ntv.md\n# core");
});

test("legacy default sentinel is replaced for compatibility", () => {
  const agentDir = fixture(["default", "ntv"]);
  const result = prepareProfilePrompt("before\n@~/.pi/agent/profiles/default.md\nafter", agentDir, "ntv");
  assert.equal(result.prompt, "before\n@~/.pi/agent/profiles/ntv.md\nafter");
});

test("missing selected profile falls back to default with a warning", () => {
  const agentDir = fixture(["default"]);
  const result = prepareProfilePrompt("# core", agentDir, "ntv");
  assert.equal(result.profile, "default");
  assert.match(result.warning ?? "", /profile \"ntv\" file missing/);
  assert.equal(count(result.prompt, "@~/.pi/agent/profiles/default.md"), 1);
});

test("profile injection is not duplicated", () => {
  const agentDir = fixture(["default", "ntv"]);
  const prompt = "@~/.pi/agent/profiles/ntv.md\nbody\n@~/.pi/agent/profiles/ntv.md";
  const result = prepareProfilePrompt(prompt, agentDir, "ntv");
  assert.equal(count(result.prompt, "@~/.pi/agent/profiles/ntv.md"), 1);
});

test("replaces a stale different-profile include", () => {
  const agentDir = fixture(["default", "ntv", "desktop"]);
  const prompt = "core\n@~/.pi/agent/profiles/ntv.md\nother\n@~/.pi/agent/profiles/desktop.md";
  const result = prepareProfilePrompt(prompt, agentDir, "default");
  assert.equal(count(result.prompt, "@~/.pi/agent/profiles/default.md"), 1);
  assert.equal(count(result.prompt, "@~/.pi/agent/profiles/ntv.md"), 0);
  assert.equal(count(result.prompt, "@~/.pi/agent/profiles/desktop.md"), 0);
  assert.match(result.prompt, /core\n@~\/\.pi\/agent\/profiles\/default\.md\nother/);
});

test("missing selected profile removes its stale include before default fallback", () => {
  const agentDir = fixture(["default"]);
  const prompt = "before\n@~/.pi/agent/profiles/ntv.md\nafter";
  const result = prepareProfilePrompt(prompt, agentDir, "ntv");
  assert.equal(result.profile, "default");
  assert.equal(count(result.prompt, "@~/.pi/agent/profiles/ntv.md"), 0);
  assert.equal(count(result.prompt, "@~/.pi/agent/profiles/default.md"), 1);
  assert.equal(result.prompt, "before\n@~/.pi/agent/profiles/default.md\nafter");
});
