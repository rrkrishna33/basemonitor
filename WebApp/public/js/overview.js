async function fetchInstances() {
    const res = await fetch('/api/instances');
    if (!res.ok) throw new Error('Failed to load instances');
    return res.json();
}

async function fetchConfig() {
    const res = await fetch('/api/config');
    if (!res.ok) throw new Error('Failed to load UI config');
    return res.json();
}

let currentInstances = [];
let currentThresholds = {};
let compactMode = localStorage.getItem('overviewCompactMode') === '1';

function fmtAge(hours) {
    if (hours == null || Number.isNaN(hours)) return 'n/a';
    if (hours < 1) return Math.round(hours * 60) + 'm';
    return hours.toFixed(1) + 'h';
}

function escapeHtml(value) {
    return String(value ?? '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
}

function statusRank(status) {
    if (status === 'Critical') return 3;
    if (status === 'Warning') return 2;
    return 1;
}

function issueReason(inst, thresholds) {
    const failedJobs = Number(inst.FailedJobCount ?? 0);
    const blocked = Number(inst.BlockedSessions ?? 0);
    const backupAge = inst.WorstFullBackupAgeHours;
    const sqlCpu = inst.SqlCpuPercent;

    if (failedJobs > 0) return `${failedJobs} failed job${failedJobs > 1 ? 's' : ''}`;
    if (backupAge != null && backupAge >= thresholds.fullBackupCriticalHours) return `full backup stale ${fmtAge(backupAge)}`;
    if (sqlCpu != null && sqlCpu >= thresholds.cpuCriticalPercent) return `SQL CPU high at ${sqlCpu}%`;
    if (blocked > 0) return `${blocked} blocked session${blocked > 1 ? 's' : ''}`;
    if (backupAge != null && backupAge >= thresholds.fullBackupWarningHours) return `backup nearing limit at ${fmtAge(backupAge)}`;
    if (sqlCpu != null && sqlCpu >= thresholds.cpuWarningPercent) return `SQL CPU elevated at ${sqlCpu}%`;
    return 'healthy baseline';
}

function issueScore(inst, thresholds) {
    const failedJobs = Number(inst.FailedJobCount ?? 0);
    const blocked = Number(inst.BlockedSessions ?? 0);
    const backupAge = Number(inst.WorstFullBackupAgeHours ?? 0);
    const sqlCpu = Number(inst.SqlCpuPercent ?? 0);

    return (failedJobs * 1000) + (blocked * 80) + backupAge + sqlCpu + (statusRank(inst.Status) * 10000);
}

function populateTagFilter(instances) {
    const tagFilter = document.getElementById('tagFilter');
    const currentValue = tagFilter.value || 'All';
    const tags = [...new Set(instances
        .map(i => String(i.Tags || '').trim())
        .filter(Boolean))]
        .sort((a, b) => a.localeCompare(b));

    tagFilter.innerHTML = '<option value="All">All</option>' +
        tags.map(t => `<option value="${escapeHtml(t)}">${escapeHtml(t)}</option>`).join('');

    tagFilter.value = tags.includes(currentValue) ? currentValue : 'All';
}

function applyFilters(instances) {
    const statusValue = document.getElementById('statusFilter').value;
    const tagValue = document.getElementById('tagFilter').value;
    const nameValue = document.getElementById('nameFilter').value.trim().toLowerCase();
    const failedOnly = document.getElementById('failedOnly').checked;
    const blockedOnly = document.getElementById('blockedOnly').checked;

    return instances.filter(inst => {
        if (statusValue !== 'All' && inst.Status !== statusValue) return false;
        if (tagValue !== 'All' && String(inst.Tags || '') !== tagValue) return false;
        if (nameValue && !String(inst.InstanceName || '').toLowerCase().includes(nameValue)) return false;
        if (failedOnly && Number(inst.FailedJobCount || 0) <= 0) return false;
        if (blockedOnly && Number(inst.BlockedSessions || 0) <= 0) return false;
        return true;
    });
}

function applyDensityUi() {
    document.body.classList.toggle('density-compact', compactMode);
    const toggle = document.getElementById('densityToggle');
    if (!toggle) return;
    toggle.textContent = compactMode ? 'Comfortable Mode' : 'Compact Mode';
    toggle.setAttribute('aria-pressed', String(compactMode));
}

function renderSummary(instances) {
    const root = document.getElementById('healthSummary');
    const total = instances.length;
    const critical = instances.filter(i => i.Status === 'Critical').length;
    const warning = instances.filter(i => i.Status === 'Warning').length;
    const healthy = instances.filter(i => i.Status === 'Healthy').length;

    const latestMetricAt = instances
        .map(i => i.MetricsCollectedAt)
        .filter(Boolean)
        .map(v => new Date(v).getTime())
        .filter(v => Number.isFinite(v));

    const newest = latestMetricAt.length ? new Date(Math.max(...latestMetricAt)) : null;
    const freshness = newest
        ? `${Math.max(0, Math.round((Date.now() - newest.getTime()) / 1000))}s ago`
        : 'n/a';

    root.innerHTML = `
        <div class="summary-head">
            <div>
                <h2>OverAll Health</h2>
                <p class="summary-meta">${total} monitored instances • latest sample ${freshness}</p>
            </div>
            <div class="summary-clock">${new Date().toLocaleTimeString()}</div>
        </div>
        <div class="summary-strip">
            <div class="summary-chip critical"><span>Critical</span><strong>${critical}</strong></div>
            <div class="summary-chip warning"><span>Warning</span><strong>${warning}</strong></div>
            <div class="summary-chip healthy"><span>Healthy</span><strong>${healthy}</strong></div>
        </div>
    `;
}

function renderTiles(instances, thresholds) {
    const grid = document.getElementById('tileGrid');
    if (!instances.length) {
        grid.innerHTML = '<p class="empty-note">No instances registered yet.</p>';
        return;
    }

    const sorted = [...instances].sort((a, b) => {
        const statusCompare = statusRank(b.Status) - statusRank(a.Status);
        if (statusCompare !== 0) return statusCompare;
        const scoreCompare = issueScore(b, thresholds) - issueScore(a, thresholds);
        if (scoreCompare !== 0) return scoreCompare;
        return String(a.InstanceName).localeCompare(String(b.InstanceName));
    });

    grid.innerHTML = sorted.map((inst, idx) => `
        <div class="tile status-${inst.Status}" style="--idx:${idx}" onclick="location.href='instance.html?id=${inst.InstanceId}'">
            <h3>${escapeHtml(inst.InstanceName)} <span class="badge status-${inst.Status}">${escapeHtml(inst.Status)}</span></h3>
            <div class="tile-reason">${escapeHtml(issueReason(inst, thresholds))}</div>
            <div class="tags">${escapeHtml(inst.Tags || '')}</div>
            <div class="metric-row"><span>SQL CPU</span><span class="value">${inst.SqlCpuPercent ?? 'n/a'}%</span></div>
            <div class="metric-row"><span>System CPU</span><span class="value">${inst.SystemCpuPercent ?? 'n/a'}%</span></div>
            <div class="metric-row"><span>SQL Memory Used</span><span class="value">${inst.SqlMemoryUsedMB ?? 'n/a'} MB</span></div>
            <div class="metric-row"><span>Blocked Sessions</span><span class="value">${inst.BlockedSessions ?? 0}</span></div>
            <div class="metric-row"><span>Oldest Full Backup</span><span class="value">${fmtAge(inst.WorstFullBackupAgeHours)}</span></div>
            <div class="metric-row"><span>Failed Jobs</span><span class="value">${inst.FailedJobCount ?? 0}</span></div>
        </div>
    `).join('');
}

function renderFilteredTiles() {
    const filtered = applyFilters(currentInstances);
    renderTiles(filtered, currentThresholds);
}

function wireControls() {
    const ids = ['statusFilter', 'tagFilter', 'nameFilter', 'failedOnly', 'blockedOnly'];
    ids.forEach(id => {
        const el = document.getElementById(id);
        if (!el) return;
        const eventName = (id === 'nameFilter') ? 'input' : 'change';
        el.addEventListener(eventName, renderFilteredTiles);
    });

    const densityToggle = document.getElementById('densityToggle');
    if (densityToggle) {
        densityToggle.addEventListener('click', () => {
            compactMode = !compactMode;
            localStorage.setItem('overviewCompactMode', compactMode ? '1' : '0');
            applyDensityUi();
        });
    }
}

async function refresh() {
    try {
        const [instances, cfg] = await Promise.all([fetchInstances(), fetchConfig()]);
        currentInstances = instances;
        currentThresholds = cfg.thresholds || {};

        renderSummary(currentInstances);
        populateTagFilter(currentInstances);
        renderFilteredTiles();
        document.getElementById('lastRefresh').textContent = 'Last updated: ' + new Date().toLocaleTimeString();
    } catch (err) {
        document.getElementById('healthSummary').innerHTML = `<p class="empty-note">Error loading summary: ${err.message}</p>`;
        document.getElementById('tileGrid').innerHTML = `<p class="empty-note">Error loading instances: ${err.message}</p>`;
    }
}

wireControls();
applyDensityUi();
refresh();
setInterval(refresh, 30000);
