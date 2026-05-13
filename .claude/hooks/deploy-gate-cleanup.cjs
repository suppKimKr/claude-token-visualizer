#!/usr/bin/env node
// claude-token-visualizer deploy gate cleanup — PostToolUse Bash hook.
// After a successful `git push` from this project, delete gate.json so the
// next change requires re-verification.

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

    if (!/\bgit\s+push\b/.test(cmd) || /--dry-run\b/.test(cmd)) process.exit(0);

    const projectRoot = findProjectRoot(cwd);
    if (!projectRoot) process.exit(0);

    const statePath = path.join(projectRoot, '.claude', 'state', 'gate.json');
    try {
        fs.unlinkSync(statePath);
        process.stderr.write(`[deploy-gate] push observed — gate state cleared\n`);
    } catch (_) {
        // missing or perm issue, ignore
    }
    process.exit(0);
});

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
