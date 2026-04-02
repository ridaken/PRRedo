/**
 * =============================================================================
 * restore_402.js  -  402 Wasteland PR Restorer (Node.js Edition)
 *
 * USAGE:
 * node restore_402.js             Normal run
 * node restore_402.js --dry-run   Preview only - no files are modified
 *
 * REQUIREMENTS:
 * - Node.js installed
 * - Run AFTER you have already done: git fetch && git checkout environment/402
 * - GitHub CLI (gh) installed and authenticated
 * =============================================================================
 */

const { execSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const crypto = require('crypto');

const args = process.argv.slice(2);
const isDryRun = args.includes('--dry-run') || args.includes('-DryRun');
const startTime = Date.now();

// ── UI Helpers ───────────────────────────────────────────────────────────────
const colors = {
    reset: "\x1b[0m", cyan: "\x1b[36m", green: "\x1b[32m",
    yellow: "\x1b[33m", red: "\x1b[31m", gray: "\x1b[90m", magenta: "\x1b[35m"
};

const log = {
    ok: (msg) => console.log(`  ${colors.green}[OK]${colors.reset}  ${msg}`),
    warn: (msg) => console.log(`  ${colors.yellow}[!!]${colors.reset}  ${msg}`),
    err: (msg) => console.log(`  ${colors.red}[XX]${colors.reset}  ${msg}`),
    info: (msg) => console.log(`  ${colors.gray}[ ]${colors.reset}   ${msg}`),
    step: (msg) => console.log(`\n${colors.magenta}[ ${msg} ]${colors.reset}`),
    raw: (msg, color = colors.reset) => console.log(`${color}${msg}${colors.reset}`)
};

function askQuestion(query) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    return new Promise(resolve => rl.question(`\n  ${query} `, ans => {
        rl.close();
        resolve(ans.trim());
    }));
}

// ── Core Helpers ─────────────────────────────────────────────────────────────

// Executes a shell command and returns stdout as a string. Throws on error.
function execString(command, ignoreStderr = true) {
    return execSync(command, { encoding: 'utf8', stdio: ['ignore', 'pipe', ignoreStderr ? 'ignore' : 'pipe'] }).trim();
}

// Safely attempts a command. Returns { exitCode, stdout, stderr }
function tryExec(command) {
    try {
        const out = execSync(command, { encoding: 'utf8', stdio: 'pipe' });
        return { exitCode: 0, stdout: out.trim(), stderr: '' };
    } catch (e) {
        return { exitCode: e.status, stdout: e.stdout ? e.stdout.toString() : '', stderr: e.stderr ? e.stderr.toString() : '' };
    }
}

function getSafeTempName(val) {
    return crypto.createHash('sha256').update(val).digest('hex').substring(0, 16);
}

function pathExists(p) {
    try { fs.accessSync(p); return true; } catch { return false; }
}

function rmrf(p) {
    if (pathExists(p)) { fs.rmSync(p, { recursive: true, force: true }); }
}

// Write Git blob directly to disk as raw bytes. Zero encoding mangling.
function writeGitObjectToFile(gitRef, outPath) {
    try {
        rmrf(outPath);
        // We use spawnSync to pipe stdout directly to a buffer
        const result = spawnSync('git', ['show', '--no-textconv', gitRef], { maxBuffer: 1024 * 1024 * 50 }); // 50MB max
        if (result.status !== 0) return false;
        
        fs.writeFileSync(outPath, result.stdout);
        return true;
    } catch (e) {
        return false;
    }
}

function gitObjectExists(gitRef) {
    return tryExec(`git cat-file -e -- "${gitRef}"`).exitCode === 0;
}

// Extracts the hash of the blob from the index to build the conflict state
function getGitIndexInfo(gitRef, filePath, stage) {
    const res = tryExec(`git ls-tree "${gitRef}" "${filePath}"`);
    if (res.exitCode === 0 && res.stdout) {
        const match = res.stdout.match(/^(\d+) blob ([a-f0-9]+)\t/);
        if (match) {
            return `${match[1]} ${match[2]} ${stage}\t${filePath}`;
        }
    }
    return null;
}

// Binary-safe CRLF to LF converter
function convertToLF(filePath) {
    if (!pathExists(filePath)) return;
    const buffer = fs.readFileSync(filePath);
    if (buffer.length === 0) return;

    // Fast binary check (null byte in first 8k)
    for (let i = 0; i < Math.min(buffer.length, 8000); i++) {
        if (buffer[i] === 0) return; // Is binary, skip
    }

    // Replace CRLF (\r\n) with LF (\n). Also catches lone \r
    const result = [];
    for (let i = 0; i < buffer.length; i++) {
        if (buffer[i] === 13) { // \r
            if (i + 1 < buffer.length && buffer[i + 1] === 10) {
                continue; // skip \r, let \n be pushed next iteration
            } else {
                result.push(10); // convert lone \r to \n
                continue;
            }
        }
        result.push(buffer[i]);
    }
    
    if (result.length !== buffer.length) {
        fs.writeFileSync(filePath, Buffer.from(result));
    }
}

// ── Main Script Logic ────────────────────────────────────────────────────────
async function main() {
    console.clear();
    log.raw("");
    log.raw("  +----------------------------------------------+", colors.cyan);
    log.raw("  |      402 Wasteland  -  PR Restorer  v6       |", colors.cyan);
    if (isDryRun) {
        log.raw("  |            *** DRY RUN MODE *** |", colors.yellow);
    }
    log.raw("  +----------------------------------------------+", colors.cyan);
    log.raw("");

    // ── 1. Pre-flight Checks ─────────────────────────────────────────────────
    log.step("Pre-flight Checks");

    const ghCheck = tryExec("gh --version");
    if (ghCheck.exitCode !== 0) {
        log.err("GitHub CLI (gh) not found on PATH.");
        process.exit(1);
    }
    log.ok("GitHub CLI found.");

    let repoPath = await askQuestion("Enter the full path to your local git repository:");
    repoPath = repoPath.replace(/^["']|["']$/g, ''); // strip quotes
    
    if (!pathExists(repoPath)) {
        log.err(`Directory not found: '${repoPath}'`);
        process.exit(1);
    }
    if (!pathExists(path.join(repoPath, '.git'))) {
        log.err(`'${repoPath}' is not a Git repository.`);
        process.exit(1);
    }
    process.chdir(repoPath);
    log.ok(`Repository: ${repoPath}`);

    const dirtyCheck = tryExec("git status --porcelain");
    if (dirtyCheck.stdout.length > 0) {
        log.err("Working tree has uncommitted changes:");
        log.raw(dirtyCheck.stdout, colors.yellow);
        log.warn("Stash or commit these before running the restorer.");
        process.exit(1);
    }
    log.ok("Working tree is clean.");

    // ── 2. PR Details ────────────────────────────────────────────────────────
    log.step("PR Details");
    const url = await askQuestion("Paste the GitHub PR URL (or bare PR number):");
    if (!url) { log.err("No input provided."); process.exit(1); }

    let prNum = url;
    if (!/^\d+$/.test(prNum)) {
        prNum = url.replace(/\/$/, '').split('/').pop();
    }
    if (!/^\d+$/.test(prNum)) {
        log.err(`Could not extract a PR number from: ${url}`);
        process.exit(1);
    }

    log.info(`Fetching PR #${prNum} metadata from GitHub...`);
    const ghRes = tryExec(`gh pr view ${prNum} --json title,state,author,headRefName`);
    if (ghRes.exitCode !== 0) {
        log.err("GitHub CLI failed:");
        log.raw(ghRes.stderr, colors.yellow);
        process.exit(1);
    }

    const prData = JSON.parse(ghRes.stdout);
    log.raw("");
    log.raw(`  PR #${prNum}`, colors.white);
    log.raw(`  Title  : ${prData.title}`, colors.white);
    log.raw(`  Author : ${prData.author.login}   Branch: ${prData.headRefName}   State: ${prData.state}`, colors.gray);

    if (prData.state === "MERGED") {
        log.warn("This PR is already MERGED - its changes may already be in the branch.");
        const confirm = await askQuestion("Type YES to restore it anyway:");
        if (confirm !== "YES") process.exit(0);
    }

    // ── 3. Fetch and Patch Download ──────────────────────────────────────────
    log.step("Fetching PR Head and Diff");
    log.info(`Fetching refs/pull/${prNum}/head ...`);
    
    // Node handles git's stderr warnings natively, so we don't need SilentlyContinue hacks
    const fetchRes = tryExec(`git fetch origin "pull/${prNum}/head"`);
    if (fetchRes.exitCode !== 0) {
        log.err("git fetch failed. Check your remote and network connection.");
        process.exit(1);
    }
    log.ok("PR head fetched into FETCH_HEAD.");

    const patchFile = path.join(repoPath, `pr_${prNum}.patch`);
    rmrf(patchFile);

    log.info(`Downloading diff for PR #${prNum} ...`);
    try {
        const diffOut = execSync(`gh pr diff ${prNum}`, { encoding: 'utf8' });
        fs.writeFileSync(patchFile, diffOut);
    } catch (e) {
        log.err("gh pr diff failed.");
        rmrf(patchFile);
        process.exit(1);
    }

    if (!pathExists(patchFile) || fs.statSync(patchFile).size === 0) {
        log.err("Patch file is empty or missing.");
        process.exit(1);
    }

    const patchContent = fs.readFileSync(patchFile, 'utf8');
    if (!patchContent.startsWith("diff --git")) {
        log.err("Downloaded file does not look like a valid patch.");
        rmrf(patchFile);
        process.exit(1);
    }
    log.ok("Valid patch downloaded.");

    // ── 4. Parse Patch ───────────────────────────────────────────────────────
    log.step("Analysing Patch");
    const affectedFiles = new Set();
    const patchLines = patchContent.split('\n');
    
    for (const line of patchLines) {
        const match = line.match(/^diff --git a\/(.+?) b\/(.+)$/);
        if (match) {
            const chosenPath = match[2] === '/dev/null' ? match[1] : match[2];
            affectedFiles.add(chosenPath);
        }
    }

    if (affectedFiles.size === 0) {
        log.err("Could not find any changed files in the patch.");
        rmrf(patchFile);
        process.exit(1);
    }

    log.raw(`\n  This patch touches ${affectedFiles.size} file(s):`, colors.white);
    affectedFiles.forEach(f => log.raw(`     ${f}`, colors.yellow));

    if (isDryRun) {
        log.warn("\nDRY RUN - no files were modified.");
        log.raw("  Re-run without --dry-run to apply.", colors.cyan);
        rmrf(patchFile);
        process.exit(0);
    }

    const proceed = await askQuestion("\nProceed with restore? (Y/n):");
    if (proceed.toLowerCase() === 'n') {
        log.info("Aborted by user.");
        rmrf(patchFile);
        process.exit(0);
    }

    // ── 5. Apply via git merge-file ──────────────────────────────────────────
    log.step("Applying Changes");
    const tempDir = path.join(repoPath, ".pr_restore_tmp");
    rmrf(tempDir);
    fs.mkdirSync(tempDir);

    const stats = { clean: [], conflict: [], new: [], deleted: [], skipped: [], binary: [] };

    try {
        for (const relPath of affectedFiles) {
            log.raw(`\n  -- ${relPath}`, colors.white);
            const absPath = path.join(repoPath, relPath);
            const safeName = getSafeTempName(relPath);

            const theirsExists = gitObjectExists(`FETCH_HEAD:${relPath}`);
            const oursExists = pathExists(absPath);

            // New file added by PR
            if (!oursExists && theirsExists) {
                log.info("New file - writing directly from PR head.");
                fs.mkdirSync(path.dirname(absPath), { recursive: true });
                if (writeGitObjectToFile(`FETCH_HEAD:${relPath}`, absPath)) {
                    // Normalize line endings via git index
                    tryExec(`git add "${relPath}"`);
                    tryExec(`git checkout-index -f -- "${relPath}"`);
                    tryExec(`git reset HEAD -- "${relPath}"`);
                    
                    stats.new.push(relPath);
                    log.ok(`Created: ${relPath}`);
                } else {
                    log.err(`Failed to write new file: ${relPath}`);
                    stats.skipped.push(relPath);
                }
                continue;
            }

            // File deleted by PR
            if (oursExists && !theirsExists) {
                log.info("File deleted by this PR - removing.");
                rmrf(absPath);
                stats.deleted.push(relPath);
                log.ok(`Deleted: ${relPath}`);
                continue;
            }

            // Missing from both
            if (!oursExists && !theirsExists) {
                log.warn(`Cannot find '${relPath}' in working tree or PR head - skipping.`);
                stats.skipped.push(relPath);
                continue;
            }

            // Modified file - 3-way merge
            const oursFile = path.join(tempDir, `ours_${safeName}.tmp`);
            const baseFile = path.join(tempDir, `base_${safeName}.tmp`);
            const theirsFile = path.join(tempDir, `theirs_${safeName}.tmp`);

            fs.copyFileSync(absPath, oursFile);

            if (!writeGitObjectToFile(`FETCH_HEAD:${relPath}`, theirsFile)) {
                log.err(`Could not retrieve THEIRS for '${relPath}' - skipping.`);
                stats.skipped.push(relPath);
                continue;
            }

            if (gitObjectExists(`FETCH_HEAD~1:${relPath}`)) {
                if (!writeGitObjectToFile(`FETCH_HEAD~1:${relPath}`, baseFile)) {
                    fs.copyFileSync(absPath, baseFile);
                    log.warn("Could not write BASE from FETCH_HEAD~1 - using OURS as base.");
                } else {
                    log.info("Base: FETCH_HEAD~1");
                }
            } else {
                fs.copyFileSync(absPath, baseFile);
                log.warn("File not present at FETCH_HEAD~1 - using OURS as base (merge may be noisier).");
            }

            // Normalization Gate
            convertToLF(oursFile);
            convertToLF(baseFile);
            convertToLF(theirsFile);

            const mergeArgs = [
                'merge-file',
                '-L', 'Current branch',
                '-L', 'Base',
                '-L', `PR #${prNum}: ${prData.title}`,
                '--',
                oursFile, baseFile, theirsFile
            ];

            const mergeRes = spawnSync('git', mergeArgs);
            const mergeExit = mergeRes.status;

            let hasConflictMarkers = false;
            if (pathExists(oursFile)) {
                const mergedContent = fs.readFileSync(oursFile, 'utf8');
                hasConflictMarkers = mergedContent.includes("<<<<<<< Current branch") && mergedContent.includes("=======");
            }

            if (mergeExit >= 0 && pathExists(oursFile)) {
                fs.mkdirSync(path.dirname(absPath), { recursive: true });
                fs.copyFileSync(oursFile, absPath);
            }

            if (mergeExit === 0 && !hasConflictMarkers) {
                // Check if logically unchanged to clear false "modified" status
                const diffCheck = tryExec(`git diff --quiet HEAD -- "${relPath}"`);
                if (diffCheck.exitCode === 0) {
                    tryExec(`git checkout HEAD -- "${relPath}"`);
                } else {
                    tryExec(`git add "${relPath}"`);
                    tryExec(`git checkout-index -f -- "${relPath}"`);
                    tryExec(`git reset HEAD -- "${relPath}"`);
                }
                stats.clean.push(relPath);
                log.ok("Clean merge.");

            } else if (mergeExit > 0 || hasConflictMarkers) {
                stats.conflict.push(relPath);
                
                // Artificially create git index conflicts
                const infoLines = [];
                let baseLine = getGitIndexInfo("FETCH_HEAD~1", relPath, 1);
                if (!baseLine) baseLine = getGitIndexInfo("HEAD", relPath, 1);
                if (baseLine) infoLines.push(baseLine);
                
                const oursLine = getGitIndexInfo("HEAD", relPath, 2);
                if (oursLine) infoLines.push(oursLine);
                
                const theirsLine = getGitIndexInfo("FETCH_HEAD", relPath, 3);
                if (theirsLine) infoLines.push(theirsLine);
                
                if (infoLines.length > 0) {
                    const infoText = infoLines.join("\n") + "\n";
                    execSync('git update-index --index-info', { input: infoText, stdio: ['pipe', 'ignore', 'ignore'] });
                }

                if (hasConflictMarkers && mergeExit === 0) {
                    log.warn("Conflict markers detected even though git returned 0 - file flagged for manual review.");
                } else {
                    log.warn(`${mergeExit} conflict block(s) - markers written into file.`);
                }
            } else {
                log.err(`git merge-file error (exit ${mergeExit}) - file may be binary.`);
                log.raw("     Restore this file manually from the PR.", colors.yellow);
                stats.conflict.push(relPath);
                stats.binary.push(relPath);
            }
        }
    } finally {
        rmrf(tempDir);
        rmrf(patchFile);
    }

    // ── 6. Summary ───────────────────────────────────────────────────────────
    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    log.step("Summary");
    log.raw(`\n  Files processed  : ${affectedFiles.size}`, colors.white);

    if (stats.clean.length)    log.ok(`Clean merges  : ${stats.clean.length}  (${stats.clean.join(', ')})`);
    if (stats.new.length)      log.ok(`New files     : ${stats.new.length}  (${stats.new.join(', ')})`);
    if (stats.deleted.length)  log.ok(`Deleted files : ${stats.deleted.length}  (${stats.deleted.join(', ')})`);
    if (stats.conflict.length) log.warn(`Conflicts     : ${stats.conflict.length}  (${stats.conflict.join(', ')})`);
    if (stats.binary.length)   log.warn(`Binary/manual : ${stats.binary.length}  (${stats.binary.join(', ')})`);
    if (stats.skipped.length)  log.warn(`Skipped files : ${stats.skipped.length}  (${stats.skipped.join(', ')})`);

    log.raw(`  Elapsed          : ${elapsed}s\n`, colors.gray);

    if (stats.conflict.length === 0 && stats.skipped.length === 0) {
        log.raw("  +----------------------------------------------+", colors.green);
        log.raw("  |   All changes applied cleanly.               |", colors.green);
        log.raw("  |   Review in your IDE, then commit and push.  |", colors.green);
        log.raw("  +----------------------------------------------+", colors.green);
    } else {
        if (stats.conflict.length > 0) {
            log.raw("  These files contain conflict markers to resolve:", colors.yellow);
            stats.conflict.forEach(f => log.raw(`     -> ${f}`, colors.yellow));
            log.raw("\n  Open each file in your IDE and search for conflict marker blocks.", colors.cyan);
        }
        if (stats.binary.length > 0) log.raw("  Binary files could not be merged automatically and need manual recovery.", colors.yellow);
        if (stats.skipped.length > 0) log.raw("  Some files were skipped because the script could not retrieve or apply them safely.", colors.yellow);
        
        log.raw("  Once resolved, review all changes, then commit and push.", colors.cyan);
    }
    log.raw("");
}

main().catch(e => {
    log.err("An unexpected error occurred:");
    console.error(e);
    process.exit(1);
});
