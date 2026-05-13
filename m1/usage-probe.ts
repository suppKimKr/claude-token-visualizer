import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CLAUDE_DIR = join(homedir(), '.claude');
const PROJECTS_DIR = join(CLAUDE_DIR, 'projects');
const SESSIONS_DIR = join(CLAUDE_DIR, 'sessions');
const HOMUNCULUS_PROJECTS = join(CLAUDE_DIR, 'homunculus', 'projects.json');

const CLAUDE_VER = process.env.CLAUDE_CLI_VERSION ?? '2.1.140';

interface UsageBucket {
    utilization: number;
    resets_at: string | null;
}

interface ExtraUsage {
    is_enabled: boolean;
    monthly_limit: number;
    used_credits: number;
    utilization: number | null;
    currency: string;
}

interface UsageResponse {
    five_hour: UsageBucket | null;
    seven_day: UsageBucket | null;
    seven_day_opus: UsageBucket | null;
    seven_day_sonnet: UsageBucket | null;
    seven_day_cowork: UsageBucket | null;
    seven_day_omelette: UsageBucket | null;
    seven_day_oauth_apps: UsageBucket | null;
    extra_usage: ExtraUsage | null;
    [key: string]: unknown;
}

interface SessionIndex {
    pid: number;
    sessionId: string;
    cwd: string;
    status: string;
    startedAt: number;
    updatedAt: number;
    version: string;
    kind?: string;
}

interface UsageBlock {
    input_tokens: number;
    cache_creation_input_tokens?: number;
    cache_read_input_tokens?: number;
    output_tokens: number;
}

interface MessageLine {
    type?: string;
    isSidechain?: boolean;
    cwd?: string;
    sessionId?: string;
    timestamp?: string;
    parentUuid?: string | null;
    message?: {
        model?: string;
        role?: string;
        usage?: UsageBlock;
    };
}

function readKeychainToken(): string {
    const raw = execFileSync(
        'security',
        ['find-generic-password', '-s', 'Claude Code-credentials', '-w'],
        { encoding: 'utf-8' },
    );
    const data = JSON.parse(raw);
    const token = data?.claudeAiOauth?.accessToken;
    if (!token) {
        throw new Error('claudeAiOauth.accessToken not found in Keychain');
    }
    return token;
}

async function fetchUsage(token: string): Promise<UsageResponse> {
    const res = await fetch('https://api.anthropic.com/api/oauth/usage', {
        headers: {
            Authorization: `Bearer ${token}`,
            'anthropic-beta': 'oauth-2025-04-20',
            'anthropic-version': '2023-06-01',
            'User-Agent': `claude-cli/${CLAUDE_VER} (external, cli)`,
            Accept: 'application/json',
        },
    });
    if (!res.ok) {
        const body = await res.text();
        throw new Error(`Usage API ${res.status}: ${body.slice(0, 200)}`);
    }
    return (await res.json()) as UsageResponse;
}

function listActiveSessions(): SessionIndex[] {
    if (!existsSync(SESSIONS_DIR)) return [];
    const out: SessionIndex[] = [];
    for (const f of readdirSync(SESSIONS_DIR)) {
        if (!f.endsWith('.json')) continue;
        try {
            const idx = JSON.parse(readFileSync(join(SESSIONS_DIR, f), 'utf-8')) as SessionIndex;
            try {
                process.kill(idx.pid, 0);
                out.push(idx);
            } catch {
                // dead PID, skip
            }
        } catch {
            // malformed, skip
        }
    }
    return out;
}

function cwdToProjectDir(cwd: string): string {
    return cwd.replace(/[\/\.]/g, '-');
}

function findSessionJsonl(sessionId: string, cwd: string): string | null {
    const direct = join(PROJECTS_DIR, cwdToProjectDir(cwd), `${sessionId}.jsonl`);
    if (existsSync(direct)) return direct;
    if (!existsSync(PROJECTS_DIR)) return null;
    for (const sub of readdirSync(PROJECTS_DIR)) {
        const candidate = join(PROJECTS_DIR, sub, `${sessionId}.jsonl`);
        if (existsSync(candidate)) return candidate;
    }
    return null;
}

function parseJsonl(path: string): MessageLine[] {
    const out: MessageLine[] = [];
    const content = readFileSync(path, 'utf-8');
    for (const line of content.split('\n')) {
        if (!line.trim()) continue;
        try {
            out.push(JSON.parse(line) as MessageLine);
        } catch {
            // skip malformed
        }
    }
    return out;
}

function lastAssistantUsage(messages: MessageLine[]): { usage: UsageBlock; model: string } | null {
    for (let i = messages.length - 1; i >= 0; i--) {
        const m = messages[i];
        if (m?.message?.role === 'assistant' && m.message.usage) {
            return { usage: m.message.usage, model: m.message.model ?? 'unknown' };
        }
    }
    return null;
}

function effectiveContextSize(u: UsageBlock): number {
    return (
        (u.input_tokens ?? 0) +
        (u.cache_creation_input_tokens ?? 0) +
        (u.cache_read_input_tokens ?? 0)
    );
}

function totalTokens(u: UsageBlock): number {
    return effectiveContextSize(u) + (u.output_tokens ?? 0);
}

function inferContextWindow(messages: MessageLine[]): number {
    let maxCtx = 0;
    for (const m of messages) {
        if (m?.message?.usage) {
            const c = effectiveContextSize(m.message.usage);
            if (c > maxCtx) maxCtx = c;
        }
    }
    if (maxCtx > 200_000) return 1_000_000;
    return 200_000;
}

function loadProjectNames(): Record<string, string> {
    if (!existsSync(HOMUNCULUS_PROJECTS)) return {};
    try {
        const data = JSON.parse(readFileSync(HOMUNCULUS_PROJECTS, 'utf-8')) as Record<
            string,
            { name: string; root: string }
        >;
        const byRoot: Record<string, string> = {};
        for (const v of Object.values(data)) {
            if (v.root && v.name) byRoot[v.root] = v.name;
        }
        return byRoot;
    } catch {
        return {};
    }
}

function humanTokens(n: number): string {
    if (n >= 1_000_000) return (n / 1_000_000).toFixed(2) + 'M';
    if (n >= 1_000) return (n / 1_000).toFixed(1) + 'k';
    return String(n);
}

function bar(remainingPct: number, width = 20): string {
    const clamped = Math.max(0, Math.min(100, remainingPct));
    const filled = Math.round((clamped / 100) * width);
    return '[' + '#'.repeat(filled) + '.'.repeat(width - filled) + ']';
}

function untilDuration(iso: string | null): string {
    if (!iso) return '—';
    const diff = new Date(iso).getTime() - Date.now();
    if (!Number.isFinite(diff) || diff <= 0) return 'now';
    const s = Math.floor(diff / 1000);
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (d > 0) return `${d}d ${h}h`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
}

function ageString(ms: number): string {
    if (ms < 60_000) return `${Math.floor(ms / 1000)}s ago`;
    if (ms < 3_600_000) return `${Math.floor(ms / 60_000)}m ago`;
    if (ms < 86_400_000) return `${Math.floor(ms / 3_600_000)}h ago`;
    return `${Math.floor(ms / 86_400_000)}d ago`;
}

async function main(): Promise<void> {
    console.log('Claude Token Visualizer — M1 probe\n');

    // 1) Anthropic OAuth usage API
    let usage: UsageResponse | null = null;
    try {
        const token = readKeychainToken();
        usage = await fetchUsage(token);
    } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error(`[usage API] failed: ${msg}\n`);
    }

    if (usage) {
        console.log('== Anthropic Usage API ==');
        if (usage.five_hour) {
            const remain = 100 - usage.five_hour.utilization;
            console.log(
                `  5-hour:   ${remain.toFixed(1).padStart(5)}% ${bar(remain)}  resets in ${untilDuration(usage.five_hour.resets_at)}`,
            );
        }
        if (usage.seven_day) {
            const remain = 100 - usage.seven_day.utilization;
            console.log(
                `  7-day:    ${remain.toFixed(1).padStart(5)}% ${bar(remain)}  resets in ${untilDuration(usage.seven_day.resets_at)}`,
            );
        }
        const subBuckets: Array<[string, UsageBucket | null]> = [
            ['7d Opus', usage.seven_day_opus],
            ['7d Sonnet', usage.seven_day_sonnet],
        ];
        for (const [label, b] of subBuckets) {
            if (b) {
                const remain = 100 - b.utilization;
                console.log(
                    `    └ ${label.padEnd(10)} ${remain.toFixed(1).padStart(5)}% remaining`,
                );
            }
        }
        if (usage.extra_usage) {
            const e = usage.extra_usage;
            const pct = e.monthly_limit > 0 ? 100 - (e.used_credits / e.monthly_limit) * 100 : 100;
            console.log(
                `  Overage:  ${pct.toFixed(1).padStart(5)}% ${bar(pct)}  $${e.used_credits.toFixed(2)} / $${e.monthly_limit} ${e.currency}`,
            );
        }
        console.log();
    }

    // 2) Active sessions
    const sessions = listActiveSessions();
    const projectNames = loadProjectNames();

    console.log(`== Active Sessions (${sessions.length}) ==`);
    if (sessions.length === 0) {
        console.log('  (none — no Claude Code processes detected)\n');
    }

    for (const s of sessions) {
        const display = projectNames[s.cwd] ?? s.cwd.split('/').filter(Boolean).pop() ?? s.cwd;
        const age = ageString(Date.now() - s.updatedAt);

        console.log(`  [PID ${s.pid}] ${display}  (${s.status}, updated ${age})`);
        console.log(`    sid: ${s.sessionId.slice(0, 8)}…  cwd: ${s.cwd}`);

        const jsonl = findSessionJsonl(s.sessionId, s.cwd);
        if (!jsonl) {
            console.log(`    (no JSONL found)\n`);
            continue;
        }
        const msgs = parseJsonl(jsonl);
        const last = lastAssistantUsage(msgs);
        if (!last) {
            console.log(`    (no assistant usage yet)\n`);
            continue;
        }

        const ctx = effectiveContextSize(last.usage);
        const win = inferContextWindow(msgs);
        const usedPct = (ctx / win) * 100;
        const remainPct = 100 - usedPct;

        console.log(`    model: ${last.model}   context window: ${win.toLocaleString()}`);
        console.log(
            `    context:  ${remainPct.toFixed(1).padStart(5)}% ${bar(remainPct)}  ${humanTokens(ctx)} / ${humanTokens(win)} used`,
        );

        const u = last.usage;
        console.log(
            `    last msg: in=${humanTokens(u.input_tokens)}  cache_create=${humanTokens(u.cache_creation_input_tokens ?? 0)}  cache_read=${humanTokens(u.cache_read_input_tokens ?? 0)}  out=${humanTokens(u.output_tokens)}`,
        );

        let sideMsgs = 0;
        let sideTokens = 0;
        for (const m of msgs) {
            if (m.isSidechain && m.message?.usage) {
                sideMsgs++;
                sideTokens += totalTokens(m.message.usage);
            }
        }
        if (sideMsgs > 0) {
            console.log(
                `    subagents (sidechain): ${sideMsgs} msgs, ${humanTokens(sideTokens)} tokens cumulative`,
            );
        }
        console.log();
    }

    // 3) Project rolling 7-day totals
    if (!existsSync(PROJECTS_DIR)) return;

    interface ProjectAgg {
        display: string;
        tokens24h: number;
        tokens7d: number;
        sessionFiles: number;
        sidechain7d: number;
        subagentFiles: number;
    }
    const aggByDir: Record<string, ProjectAgg> = {};
    const now = Date.now();

    function walkJsonl(dir: string): Array<{ path: string; isSubagent: boolean }> {
        const out: Array<{ path: string; isSubagent: boolean }> = [];
        let entries: string[];
        try {
            entries = readdirSync(dir);
        } catch {
            return out;
        }
        for (const name of entries) {
            const p = join(dir, name);
            let st;
            try {
                st = statSync(p);
            } catch {
                continue;
            }
            if (st.isDirectory()) {
                // any *.jsonl under a `subagents/` subtree counts as subagent
                const sub = walkJsonl(p);
                for (const item of sub) {
                    out.push({
                        path: item.path,
                        isSubagent: item.isSubagent || /\/subagents\//.test(item.path),
                    });
                }
            } else if (name.endsWith('.jsonl')) {
                out.push({ path: p, isSubagent: /\/subagents\//.test(p) });
            }
        }
        return out;
    }

    for (const sub of readdirSync(PROJECTS_DIR)) {
        const dir = join(PROJECTS_DIR, sub);
        try {
            if (!statSync(dir).isDirectory()) continue;
        } catch {
            continue;
        }
        const files = walkJsonl(dir);
        if (files.length === 0) continue;

        let t24 = 0;
        let t7 = 0;
        let side7 = 0;
        let cwd: string | null = null;
        let mainFiles = 0;
        let subFiles = 0;

        for (const f of files) {
            if (f.isSubagent) subFiles++;
            else mainFiles++;
            const msgs = parseJsonl(f.path);
            for (const m of msgs) {
                if (!cwd && m.cwd) cwd = m.cwd;
                if (!m.message?.usage) continue;
                const ts = m.timestamp ? Date.parse(m.timestamp) : NaN;
                if (!Number.isFinite(ts)) continue;
                const age = now - ts;
                const tot = totalTokens(m.message.usage);
                const fromSub = f.isSubagent || m.isSidechain === true;
                if (age <= 7 * 86_400_000) {
                    t7 += tot;
                    if (fromSub) side7 += tot;
                }
                if (age <= 86_400_000) t24 += tot;
            }
        }
        if (t7 === 0) continue;
        const display = cwd
            ? (projectNames[cwd] ?? cwd.split('/').filter(Boolean).pop() ?? sub)
            : sub;
        aggByDir[sub] = {
            display,
            tokens24h: t24,
            tokens7d: t7,
            sessionFiles: mainFiles,
            sidechain7d: side7,
            subagentFiles: subFiles,
        };
    }

    const sorted = Object.values(aggByDir).sort((a, b) => b.tokens7d - a.tokens7d);
    console.log(`== Per-Project Rolling Totals (top 15 by 7d, ${sorted.length} active) ==`);
    for (const a of sorted.slice(0, 15)) {
        const sidechainPct = a.tokens7d > 0 ? (a.sidechain7d / a.tokens7d) * 100 : 0;
        console.log(
            `  ${a.display.padEnd(38)}  7d:${humanTokens(a.tokens7d).padStart(7)}  24h:${humanTokens(a.tokens24h).padStart(7)}  sub:${sidechainPct.toFixed(0).padStart(3)}%  sessions:${a.sessionFiles}  subagents:${a.subagentFiles}`,
        );
    }
    console.log();

    // 4) Discrepancy check
    if (usage?.seven_day) {
        const allTokens7d = sorted.reduce((s, a) => s + a.tokens7d, 0);
        console.log('== Cross-check ==');
        console.log(
            `  Local sum across projects (7d transacted tokens): ${humanTokens(allTokens7d)}`,
        );
        console.log(
            `  API 7-day utilization:                            ${usage.seven_day.utilization.toFixed(1)}%`,
        );
        console.log(
            `  → Local sum is gross token volume; API value is plan-weighted. They are NOT directly comparable but should move together.`,
        );
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
