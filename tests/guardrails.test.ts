import test from "node:test";
import assert from "node:assert";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execSync } from "node:child_process";

import { isProtectedPath, isValidReviewMarker, getChangedPaths, sanitizeForGitDetection } from "../extensions/guardrails.ts";

function setupRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "guardrails-test-"));
  execSync("git init", { cwd: dir, stdio: "ignore" });
  execSync("git config user.email 'test@example.com'", { cwd: dir, stdio: "ignore" });
  execSync("git config user.name 'Test'", { cwd: dir, stdio: "ignore" });
  return dir;
}

test("isValidReviewMarker", () => {
  assert.strictEqual(isValidReviewMarker("Reviewed-by: reviewer/abcdef12"), true);
  assert.strictEqual(isValidReviewMarker("reviewed-by: reviewer/1234567890abcdef"), true);
  
  // invalid
  assert.strictEqual(isValidReviewMarker("Reviewed-by: worker"), false);
  assert.strictEqual(isValidReviewMarker("Reviewed-by:"), false);
  assert.strictEqual(isValidReviewMarker("Reviewed-by: reviewer/abc"), false); // < 8 chars
  assert.strictEqual(isValidReviewMarker("Reviewed-by: reviewer/ABCDEF12"), false); // must be lowercase hex
  assert.strictEqual(isValidReviewMarker("Reviewed-by: reviewer/1234567g"), false); // not hex
});

test("isProtectedPath", () => {
  assert.strictEqual(isProtectedPath("scripts/ntv-rpi-prep"), true);
  assert.strictEqual(isProtectedPath("something-prep.sh"), true);
  assert.strictEqual(isProtectedPath("player-scripts/main.sh"), true);
  
  assert.strictEqual(isProtectedPath("README.md"), false);
  assert.strictEqual(isProtectedPath("docs/deploy.md"), false);
});

test("getChangedPaths - commit with unrelated staged docs in repo with protected scripts", () => {
  const cwd = setupRepo();
  
  // Create a protected script but don't stage it, or commit it earlier
  fs.writeFileSync(path.join(cwd, "ntv-rpi-prep"), "echo prep");
  execSync("git add ntv-rpi-prep", { cwd: cwd, stdio: "ignore" });
  execSync("git commit -m 'initial protected script'", { cwd: cwd, stdio: "ignore" });
  
  // Stage an unrelated doc
  fs.writeFileSync(path.join(cwd, "README.md"), "docs");
  execSync("git add README.md", { cwd: cwd, stdio: "ignore" });
  
  const changed = getChangedPaths("commit", cwd);
  assert.notStrictEqual(changed, null);
  assert.deepStrictEqual(changed, ["README.md"]);
  assert.strictEqual(changed!.some(isProtectedPath), false);
});

test("getChangedPaths - commit with newly added protected paths", () => {
  const cwd = setupRepo();
  fs.writeFileSync(path.join(cwd, "new-prep.sh"), "echo prep");
  execSync("git add new-prep.sh", { cwd: cwd, stdio: "ignore" });
  
  const changed = getChangedPaths("commit", cwd);
  assert.notStrictEqual(changed, null);
  assert.deepStrictEqual(changed, ["new-prep.sh"]);
  assert.strictEqual(changed!.some(isProtectedPath), true);
});

test("getChangedPaths - commit with renamed protected paths", () => {
  const cwd = setupRepo();
  fs.writeFileSync(path.join(cwd, "old.sh"), "echo old");
  execSync("git add old.sh", { cwd: cwd, stdio: "ignore" });
  execSync("git commit -m 'initial'", { cwd: cwd, stdio: "ignore" });
  
  execSync("git mv old.sh player-scripts.sh", { cwd: cwd, stdio: "ignore" });
  
  const changed = getChangedPaths("commit", cwd);
  assert.notStrictEqual(changed, null);
  assert.strictEqual(changed!.includes("player-scripts.sh"), true);
  assert.strictEqual(changed!.some(isProtectedPath), true);
});

test("sanitizeForGitDetection - false positive: prose mentioning git commit/push inside a python3 -c string is not detected as a real invocation", () => {
  const cmd = `python3 -c 'print("Remember to run git commit and git push after review")'`;
  const sanitized = sanitizeForGitDetection(cmd);
  assert.strictEqual(/git\s+commit/.test(sanitized), false);
  assert.strictEqual(/git\s+push/.test(sanitized), false);
});

test("sanitizeForGitDetection - false positive: multi-line quoted payload (python heredoc-style content) mentioning git commit/push", () => {
  const cmd = `python3 -c '\ncontent = """\nThis change updates the git commit workflow and adds a git push step.\n"""\n'`;
  const sanitized = sanitizeForGitDetection(cmd);
  assert.strictEqual(/git\s+commit/.test(sanitized), false);
  assert.strictEqual(/git\s+push/.test(sanitized), false);
});

test("sanitizeForGitDetection - false positive: heredoc body mentioning git commit/push", () => {
  const cmd = `cat > review.md <<'EOF'\nRun git commit and git push once approved.\nEOF`;
  const sanitized = sanitizeForGitDetection(cmd);
  assert.strictEqual(/git\s+commit/.test(sanitized), false);
  assert.strictEqual(/git\s+push/.test(sanitized), false);
});

test("sanitizeForGitDetection - true positive: real git commit/push invocation still detected", () => {
  const commitCmd = `git commit -m "fix: something"`;
  const pushCmd = `git push origin main`;
  assert.strictEqual(/git\s+commit/.test(sanitizeForGitDetection(commitCmd)), true);
  assert.strictEqual(/git\s+push/.test(sanitizeForGitDetection(pushCmd)), true);
});

test("sanitizeForGitDetection - true positive: real invocation survives even with a quoted commit message", () => {
  const cmd = `git commit -m "docs: mention git push in the changelog"`;
  assert.strictEqual(/git\s+commit/.test(sanitizeForGitDetection(cmd)), true);
});

test("PI_REVIEW_OVERRIDE inline prefix detected in sanitized command text (not just process.env)", () => {
  const cmd = `PI_REVIEW_OVERRIDE=1 git commit -m "hotfix"`;
  const sanitized = sanitizeForGitDetection(cmd);
  assert.strictEqual(/(^|[;&|\s])PI_REVIEW_OVERRIDE=1(\s|$)/.test(sanitized), true);
});

test("PI_REVIEW_OVERRIDE mentioned only inside embedded prose does not forge an override", () => {
  const cmd = `python3 -c 'print("set PI_REVIEW_OVERRIDE=1 for emergencies")'`;
  const sanitized = sanitizeForGitDetection(cmd);
  assert.strictEqual(/(^|[;&|\s])PI_REVIEW_OVERRIDE=1(\s|$)/.test(sanitized), false);
});

test("getChangedPaths - push range fail-closed (indeterminate range)", () => {
  const cwd = setupRepo();
  const changed = getChangedPaths("push", cwd);
  assert.strictEqual(changed, null);
});

test("getChangedPaths - push range success", () => {
  const cwd = setupRepo();
  execSync("git commit --allow-empty -m 'initial'", { cwd: cwd, stdio: "ignore" });
  execSync("git branch -m main", { cwd: cwd, stdio: "ignore" });
  
  const cloneDir = fs.mkdtempSync(path.join(os.tmpdir(), "guardrails-clone-"));
  execSync(`git clone ${cwd} ${cloneDir}`, { stdio: "ignore" });
  execSync("git config user.email 'test@example.com'", { cwd: cloneDir, stdio: "ignore" });
  execSync("git config user.name 'Test'", { cwd: cloneDir, stdio: "ignore" });
  
  fs.writeFileSync(path.join(cloneDir, "ntv-rpi-imager"), "echo imager");
  execSync("git add ntv-rpi-imager", { cwd: cloneDir, stdio: "ignore" });
  execSync("git commit -m 'add imager'", { cwd: cloneDir, stdio: "ignore" });
  
  const changed = getChangedPaths("push", cloneDir);
  assert.notStrictEqual(changed, null);
  assert.deepStrictEqual(changed, ["ntv-rpi-imager"]);
  assert.strictEqual(changed!.some(isProtectedPath), true);
});