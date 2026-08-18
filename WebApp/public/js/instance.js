const params = new URLSearchParams(location.search);
const instanceId = params.get('id');
let cpuChart, memChart;
const loaded = {};

const tabContainers = {
    cpu: ['cpuStatus'],
    waits: ['waitsTable'],
    databases: ['databasesTable'],
    diskio: ['diskioTable'],
    tempdb: ['tempdbTable'],
    logstats: ['logstatsTable'],
    backups: ['backupsTable'],
    agent: ['agentTable'],
    queries: ['queriesTable'],
    indexhealth: ['missingTable', 'unusedTable', 'fragTable'],
    connections: ['connSummary', 'blockingTable']
};

function fmtAge(hours) {
    if (hours == null || Number.isNaN(hours)) return 'n/a';
    if (hours < 1) return Math.round(hours * 60) + 'm';
    return `${hours.toFixed(1)}h`;
}

function escapeHtml(str) {
    if (str == null) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function renderTable(containerId, rows, columns) {
    const el = document.getElementById(containerId);
    if (!rows || !rows.length) {
        el.innerHTML = '<p class="empty-note">No data collected yet.</p>';
        return;
    }
    const head = columns.map(c => `<th>${escapeHtml(c.label)}</th>`).join('');
    const body = rows.map(r => {
        const cls = r.__rowClass ? ` class="${r.__rowClass}"` : '';
        const cells = columns.map(c => `<td>${escapeHtml(c.fmt ? c.fmt(r[c.key], r) : r[c.key])}</td>`).join('');
        return `<tr${cls}>${cells}</tr>`;
    }).join('');
    el.innerHTML = `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function setContainerState(containerId, message, level = 'info') {
    const el = document.getElementById(containerId);
    if (!el) return;
    const cls = level === 'error' ? 'panel-state state-error' : 'panel-state state-loading';
    el.innerHTML = `<div class="${cls}">${escapeHtml(message)}</div>`;
}

function setTabLoading(tab) {
    const targets = tabContainers[tab] || [];
    if (tab === 'indexhealth') {
        setContainerState('missingTable', 'Loading missing indexes...');
        setContainerState('unusedTable', 'Loading unused indexes...');
        setContainerState('fragTable', 'Loading fragmentation data...');
        return;
    }
    if (tab === 'connections') {
        setContainerState('connSummary', 'Loading connection summary...');
        setContainerState('blockingTable', 'Loading blocking chains...');
        return;
    }
    if (tab === 'cpu') {
        setContainerState('cpuStatus', 'Loading CPU and memory charts...');
        return;
    }
    targets.forEach(id => setContainerState(id, 'Loading data...'));
}

function setTabError(tab, err) {
    const msg = `Failed to load data: ${err?.message || err || 'unknown error'}`;
    const targets = tabContainers[tab] || [];
    if (tab === 'cpu') {
        setContainerState('cpuStatus', msg, 'error');
        return;
    }
    targets.forEach(id => setContainerState(id, msg, 'error'));
}

async function fetchJson(url) {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Request failed: ${url}`);
    return res.json();
}

async function loadInstanceTitle() {
    const inst = await fetchJson(`/api/instances/${instanceId}/health-snapshot`);
    const nameLine = `${inst.InstanceName} — ${inst.Tags || ''}`;
    document.getElementById('instanceTitle').textContent = nameLine;
    document.getElementById('instanceName').textContent = inst.InstanceName || 'Unknown Instance';

    const seenAt = inst.LastSeenAt ? new Date(inst.LastSeenAt).toLocaleString() : 'n/a';
    const sampleAt = inst.MetricsCollectedAt ? new Date(inst.MetricsCollectedAt).toLocaleString() : 'n/a';
    document.getElementById('instanceMeta').textContent = `Tags: ${inst.Tags || 'n/a'} • Last seen: ${seenAt} • Metrics sample: ${sampleAt}`;

    document.getElementById('kpiSqlCpu').textContent = inst.SqlCpuPercent == null ? 'n/a' : `${inst.SqlCpuPercent}%`;
    document.getElementById('kpiBlocked').textContent = inst.BlockedSessions == null ? '0' : String(inst.BlockedSessions);
    document.getElementById('kpiFailedJobs').textContent = inst.FailedJobCount == null ? '0' : String(inst.FailedJobCount);
    document.getElementById('kpiBackupAge').textContent = fmtAge(inst.WorstFullBackupAgeHours);

    const badge = document.getElementById('instanceStatusBadge');
    badge.className = `badge status-${inst.Status || 'Healthy'}`;
    badge.textContent = inst.Status || 'Healthy';

    document.getElementById('instanceRefresh').textContent = `Last updated: ${new Date().toLocaleTimeString()}`;
}

async function loadCpu() {
    setContainerState('cpuStatus', 'Loading CPU and memory charts...');
    const rows = await fetchJson(`/api/instances/${instanceId}/system-metrics?hours=24`);
    const labels = rows.map(r => new Date(r.CollectedAt).toLocaleTimeString());

    if (cpuChart) cpuChart.destroy();
    cpuChart = new Chart(document.getElementById('cpuChart'), {
        type: 'line',
        data: {
            labels,
            datasets: [
                { label: 'SQL CPU %', data: rows.map(r => r.SqlCpuPercent), borderColor: '#4da3ff', tension: 0.2 },
                { label: 'System CPU %', data: rows.map(r => r.SystemCpuPercent), borderColor: '#f5a623', tension: 0.2 }
            ]
        },
        options: { responsive: true, maintainAspectRatio: false, plugins: { title: { display: true, text: 'CPU (last 24h)', color: '#e6e9ef' } } }
    });

    if (memChart) memChart.destroy();
    memChart = new Chart(document.getElementById('memChart'), {
        type: 'line',
        data: {
            labels,
            datasets: [
                { label: 'SQL Memory Used MB', data: rows.map(r => r.SqlMemoryUsedMB), borderColor: '#2ecc71', tension: 0.2 },
                { label: 'Available Memory MB', data: rows.map(r => r.AvailableMemoryMB), borderColor: '#e74c3c', tension: 0.2 }
            ]
        },
        options: { responsive: true, maintainAspectRatio: false, plugins: { title: { display: true, text: 'Memory (last 24h)', color: '#e6e9ef' } } }
    });

    const status = document.getElementById('cpuStatus');
    if (status) status.innerHTML = '';
}

async function loadWaits() {
    const rows = await fetchJson(`/api/instances/${instanceId}/wait-stats?top=15`);
    renderTable('waitsTable', rows, [
        { key: 'WaitType', label: 'Wait Type' },
        { key: 'WaitingTasksCount', label: 'Waiting Tasks' },
        { key: 'WaitTimeMs', label: 'Wait Time (ms)' },
        { key: 'SignalWaitTimeMs', label: 'Signal Wait (ms)' }
    ]);
}

async function loadDatabases() {
    const rows = await fetchJson(`/api/instances/${instanceId}/databases`);
    renderTable('databasesTable', rows, [
        { key: 'DatabaseName', label: 'Database' },
        { key: 'State', label: 'State' },
        { key: 'RecoveryModel', label: 'Recovery Model' },
        { key: 'DataSizeMB', label: 'Data (MB)' },
        { key: 'LogSizeMB', label: 'Log (MB)' },
        { key: 'FileCount', label: 'Files' }
    ]);
}

async function loadDiskIo() {
    const rows = await fetchJson(`/api/instances/${instanceId}/disk-io`);
    renderTable('diskioTable', rows, [
        { key: 'DatabaseName', label: 'Database' },
        { key: 'PhysicalName', label: 'File' },
        { key: 'FileType', label: 'Type' },
        { key: 'AvgReadLatencyMs', label: 'Avg Read Latency (ms)' },
        { key: 'AvgWriteLatencyMs', label: 'Avg Write Latency (ms)' },
        { key: 'NumReads', label: 'Reads' },
        { key: 'NumWrites', label: 'Writes' }
    ]);
}

async function loadTempDb() {
    const rows = await fetchJson(`/api/instances/${instanceId}/tempdb`);
    renderTable('tempdbTable', rows, [
        { key: 'FileName', label: 'File' },
        { key: 'FileType', label: 'Type' },
        { key: 'FileSizeMB', label: 'Size (MB)' },
        { key: 'UnallocatedSpaceMB', label: 'Free (MB)' },
        { key: 'UserObjectMB', label: 'User Objects (MB)' },
        { key: 'VersionStoreMB', label: 'Version Store (MB)' }
    ]);
}

async function loadLogStats() {
    const rows = await fetchJson(`/api/instances/${instanceId}/log-stats`);
    renderTable('logstatsTable', rows, [
        { key: 'DatabaseName', label: 'Database' },
        { key: 'RecoveryModel', label: 'Recovery Model' },
        { key: 'LogSizeMB', label: 'Log Size (MB)' },
        { key: 'LogUsedMB', label: 'Log Used (MB)' },
        { key: 'VlfCount', label: 'VLF Count' }
    ]);
}

async function loadBackups() {
    const rows = await fetchJson(`/api/instances/${instanceId}/backups`);
    rows.forEach(r => {
        if (r.FullBackupAgeHours >= 24) r.__rowClass = 'row-critical';
        else if (r.FullBackupAgeHours >= 20) r.__rowClass = 'row-warning';
    });
    renderTable('backupsTable', rows, [
        { key: 'DatabaseName', label: 'Database' },
        { key: 'RecoveryModel', label: 'Recovery Model' },
        { key: 'LastFullBackupAt', label: 'Last Full', fmt: v => v ? new Date(v).toLocaleString() : 'never' },
        { key: 'FullBackupAgeHours', label: 'Full Age (h)', fmt: v => v == null ? 'n/a' : v.toFixed(1) },
        { key: 'LastLogBackupAt', label: 'Last Log', fmt: v => v ? new Date(v).toLocaleString() : 'never' },
        { key: 'LogBackupAgeHours', label: 'Log Age (h)', fmt: v => v == null ? 'n/a' : v.toFixed(1) }
    ]);
}

async function loadAgent() {
    const rows = await fetchJson(`/api/instances/${instanceId}/agent-jobs`);
    rows.forEach(r => { if (r.LastRunStatus === 0) r.__rowClass = 'row-critical'; });
    renderTable('agentTable', rows, [
        { key: 'JobName', label: 'Job' },
        { key: 'LastRunStatus', label: 'Status', fmt: v => ({ 0: 'Failed', 1: 'Succeeded', 2: 'Retry', 3: 'Canceled', 4: 'In Progress' }[v] ?? 'Unknown') },
        { key: 'LastRunAt', label: 'Last Run', fmt: v => v ? new Date(v).toLocaleString() : 'never' },
        { key: 'LastRunMessage', label: 'Message' }
    ]);
}

async function loadQueries() {
    const rows = await fetchJson(`/api/instances/${instanceId}/top-queries`);
    renderTable('queriesTable', rows, [
        { key: 'DatabaseName', label: 'Database' },
        { key: 'QueryText', label: 'Query', fmt: v => (v || '').slice(0, 120) },
        { key: 'ExecutionCount', label: 'Executions' },
        { key: 'AvgCpuUs', label: 'Avg CPU (us)' },
        { key: 'TotalCpuUs', label: 'Total CPU (us)' },
        { key: 'AvgDurationUs', label: 'Avg Duration (us)' }
    ]);
}

async function loadIndexHealth() {
    const data = await fetchJson(`/api/instances/${instanceId}/index-health`);
    renderTable('missingTable', data.missing, [
        { key: 'DatabaseName', label: 'Database' },
        { key: 'EqualityColumns', label: 'Equality Columns' },
        { key: 'AvgUserImpact', label: 'Avg Impact %', fmt: v => v == null ? 'n/a' : v.toFixed(1) },
        { key: 'UserSeeks', label: 'Seeks' }
    ]);
    renderTable('unusedTable', data.unused, [
        { key: 'DatabaseName', label: 'Database' },
        { key: 'TableName', label: 'Table' },
        { key: 'IndexName', label: 'Index' },
        { key: 'UserUpdates', label: 'Updates (writes, no reads)' }
    ]);
    data.fragmentation.forEach(r => {
        if (r.FragmentationPercent >= 30) r.__rowClass = 'row-critical';
        else if (r.FragmentationPercent >= 10) r.__rowClass = 'row-warning';
    });
    renderTable('fragTable', data.fragmentation, [
        { key: 'DatabaseName', label: 'Database' },
        { key: 'TableName', label: 'Table' },
        { key: 'IndexName', label: 'Index' },
        { key: 'FragmentationPercent', label: 'Fragmentation %', fmt: v => v == null ? 'n/a' : v.toFixed(1) },
        { key: 'PageCount', label: 'Pages' }
    ]);
}

async function loadConnections() {
    const data = await fetchJson(`/api/instances/${instanceId}/connections`);
    const s = data.snapshot;
    document.getElementById('connSummary').textContent = s
        ? `Total Sessions: ${s.TotalSessions}  |  Active Requests: ${s.ActiveRequests}  |  Blocked: ${s.BlockedSessions}  (as of ${new Date(s.CollectedAt).toLocaleString()})`
        : 'No connection snapshot collected yet.';
    data.blocking.forEach(r => { if (r.WaitTimeMs >= 30000) r.__rowClass = 'row-critical'; else r.__rowClass = 'row-warning'; });
    renderTable('blockingTable', data.blocking, [
        { key: 'BlockingSessionId', label: 'Blocking SPID' },
        { key: 'BlockedSessionId', label: 'Blocked SPID' },
        { key: 'WaitType', label: 'Wait Type' },
        { key: 'WaitTimeMs', label: 'Wait (ms)' },
        { key: 'BlockedStatement', label: 'Blocked Statement', fmt: v => (v || '').slice(0, 120) }
    ]);
}

const loaders = {
    cpu: loadCpu,
    waits: loadWaits,
    databases: loadDatabases,
    diskio: loadDiskIo,
    tempdb: loadTempDb,
    logstats: loadLogStats,
    backups: loadBackups,
    agent: loadAgent,
    queries: loadQueries,
    indexhealth: loadIndexHealth,
    connections: loadConnections
};

function activateTab(tab) {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
    document.querySelectorAll('.tab-content').forEach(c => c.classList.toggle('active', c.id === `tab-${tab}`));
    setTabLoading(tab);
    loaders[tab]().catch(err => {
        console.error(err);
        setTabError(tab, err);
    });
}

document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => activateTab(btn.dataset.tab));
});

loadInstanceTitle().catch(err => console.error(err));
activateTab('cpu');
setInterval(() => {
    const active = document.querySelector('.tab-btn.active').dataset.tab;
    loadInstanceTitle().catch(err => console.error(err));
    setTabLoading(active);
    loaders[active]().catch(err => {
        console.error(err);
        setTabError(active, err);
    });
}, 30000);
