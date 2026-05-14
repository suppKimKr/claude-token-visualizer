// Shared helpers for deploy-gate.cjs and deploy-gate-cleanup.cjs.
// Both hooks need to (a) detect a real `git push` invocation in a Bash
// command string and (b) find the project root from cwd. Keeping the
// logic here avoids drift between the PreToolUse and PostToolUse paths.

const fs = require('fs');
const path = require('path');

function isGitPush(cmd) {
    const stripped = stripQuotedAndHeredocs(cmd);
    const re = /(^|[\s;&|(`])git(\s+(-C\s+\S+|--[\w-]+(=\S*)?|-[A-Za-z]+))*\s+push\b/;
    if (!re.test(stripped)) return false;
    if (/--dry-run\b/.test(stripped)) return false;
    return true;
}

// Remove single-quoted strings, double-quoted strings, and heredoc bodies so
// `git push` mentioned inside a commit message or shell string does not
// trigger the gate.
function stripQuotedAndHeredocs(cmd) {
    let s = cmd;
    s = s.replace(/<<-?\s*'?"?(\w+)"?'?[\s\S]*?\n\1\b/g, '');
    s = s.replace(/"(?:[^"\\]|\\.)*"/g, '""');
    s = s.replace(/'[^']*'/g, "''");
    return s;
}

// Walk up from cwd until we find a directory containing
// .claude/hooks/deploy-gate.cjs. That directory is treated as the project
// root for state-file lookup.
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

module.exports = { isGitPush, stripQuotedAndHeredocs, findProjectRoot };
