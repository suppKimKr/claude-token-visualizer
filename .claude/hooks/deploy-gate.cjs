#!/usr/bin/env node
// claude-token-visualizer deploy gate — PreToolUse Bash hook.
// Blocks `git push` from this project unless .claude/state/gate.json has
// verified:true (or bypass:true).
//
//   verified=true → exit 0
//   bypass=true   → exit 0 + stderr notice
//   otherwise     → exit 2 + stderr instructions

const fs = require('fs');
const path = require('path');

let raw = '';
process.stdin.on('data', (chunk) => {
    raw += chunk;
});
process.stdin.on('end', () => {
    let payload;
    try {
        payload = JSON.parse(raw);
    } catch (_) {
        process.exit(0);
    }

    const cmd = (payload.tool_input && payload.tool_input.command) || '';
    const cwd = payload.cwd || '';

    if (!isGitPush(cmd)) process.exit(0);

    const projectRoot = findProjectRoot(cwd);
    if (!projectRoot) process.exit(0);

    const statePath = path.join(projectRoot, '.claude', 'state', 'gate.json');
    let state = null;
    try {
        state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    } catch (_) {
        // no state
    }

    if (state && state.verified === true) {
        process.stderr.write(`[deploy-gate] verified at ${state.verifiedAt} — push allowed\n`);
        process.exit(0);
    }

    if (state && state.bypass === true) {
        process.stderr.write(
            `[deploy-gate] BYPASS active — reason: ${state.bypassReason || 'unspecified'}\n`,
        );
        process.exit(0);
    }

    process.stderr.write('\n');
    process.stderr.write(`⛔ [deploy-gate] BLOCKED: no verified gate state.\n`);
    process.stderr.write('\n');
    process.stderr.write(`  command : ${cmd}\n`);
    process.stderr.write(`  cwd     : ${cwd}\n`);
    process.stderr.write(`  state   : ${statePath}\n`);
    if (state) {
        process.stderr.write(`  stages  : ${JSON.stringify(state.stages || {})}\n`);
    } else {
        process.stderr.write(`  stages  : (no gate.json)\n`);
    }
    process.stderr.write('\n');
    process.stderr.write(`  → Run /ship to verify and deploy.\n`);
    process.stderr.write(`  → Or /bypass-gate "<reason>" for hotfix bypass.\n`);
    process.stderr.write('\n');
    process.exit(2);
});

function isGitPush(cmd) {
    const stripped = stripQuotedAndHeredocs(cmd);
    const re = /(^|[\s;&|(`])git(\s+(-C\s+\S+|--[\w-]+(=\S*)?|-[A-Za-z]+))*\s+push\b/;
    if (!re.test(stripped)) return false;
    if (/--dry-run\b/.test(stripped)) return false;
    return true;
}

function stripQuotedAndHeredocs(cmd) {
    let s = cmd;
    s = s.replace(/<<-?\s*'?"?(\w+)"?'?[\s\S]*?\n\1\b/g, '');
    s = s.replace(/"(?:[^"\\]|\\.)*"/g, '""');
    s = s.replace(/'[^']*'/g, "''");
    return s;
}

// Walk up from cwd until we find a dir containing .claude/hooks/deploy-gate.cjs
// (i.e. this same file). That dir is the project root.
function findProjectRoot(cwd) {
    if (!cwd) return null;
    let dir = cwd;
    const root = path.parse(dir).root;
    while (true) {
        if (fs.existsSync(path.join(dir, '.claude', 'hooks', 'deploy-gate.cjs'))) return dir;
        if (dir === root) return null;
        const parent = path.dirname(dir);
        if (parent === dir) return null;
        dir = parent;
    }
}
