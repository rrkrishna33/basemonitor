let performanceData = { queries: [], procedures: [], waits: [], io: [] };
let selectedInstance = 'All';
let sqlTextRows = [];

function escapeHtml(value) {
    return String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

function fmtNumber(value, digits = 0) {
    if (value == null || !Number.isFinite(Number(value))) return 'n/a';
    return Number(value).toLocaleString(undefined, { maximumFractionDigits: digits });
}

function fmtQuery(value) {
    return escapeHtml(String(value || '').replace(/\s+/g, ' ').trim().slice(0, 140));
}

function rowsFor(rows) {
    return rows.filter(row => selectedInstance === 'All' || String(row.InstanceId) === selectedInstance);
}

function renderQueries() {
    const rows = rowsFor(performanceData.queries);
    sqlTextRows = rows;
    document.getElementById('queryCount').textContent = rows.length;
    document.getElementById('queryTable').innerHTML = rows.length ? `<table><thead><tr><th>Instance</th><th>Database</th><th>SQL Text</th><th>Total CPU</th><th>Avg CPU</th><th>Executions</th><th>Reads</th></tr></thead><tbody>${rows.map((r, index) => `<tr><td>${escapeHtml(r.InstanceName)}</td><td>${escapeHtml(r.DatabaseName)}</td><td><button class="sql-text-btn" type="button" data-sql-index="${index}" title="Open full SQL text">${fmtQuery(r.QueryText)}</button></td><td>${fmtNumber(r.TotalCpuUs)}</td><td>${fmtNumber(r.AvgCpuUs)}</td><td>${fmtNumber(r.ExecutionCount)}</td><td>${fmtNumber(r.AvgLogicalReads)}</td></tr>`).join('')}</tbody></table>` : '<p class="empty-note">No query data collected yet.</p>';
    document.querySelectorAll('[data-sql-index]').forEach(btn => btn.addEventListener('click', () => openSqlModal(sqlTextRows[Number(btn.dataset.sqlIndex)])));
}

function renderProcedures() {
    const rows = rowsFor(performanceData.procedures || []);
    document.getElementById('procedureCount').textContent = rows.length;
    document.getElementById('procedureTable').innerHTML = rows.length ? `<table><thead><tr><th>Instance</th><th>Database</th><th>Procedure</th><th>Total CPU</th><th>Executions</th><th>Avg Duration</th><th>SQL Text</th></tr></thead><tbody>${rows.map((r, index) => `<tr><td>${escapeHtml(r.InstanceName)}</td><td>${escapeHtml(r.DatabaseName)}</td><td>${escapeHtml([r.ProcedureSchema, r.ProcedureName].filter(Boolean).join('.'))}</td><td>${fmtNumber(r.TotalCpuUs)}</td><td>${fmtNumber(r.ExecutionCount)}</td><td>${fmtNumber(r.AvgDurationUs)} us</td><td><button class="sql-text-btn" type="button" data-procedure-index="${index}">Open SQL Text</button></td></tr>`).join('')}</tbody></table>` : '<p class="empty-note">No stored-procedure data collected yet. New query samples will populate this view.</p>';
    document.querySelectorAll('[data-procedure-index]').forEach(btn => btn.addEventListener('click', () => openSqlModal(rows[Number(btn.dataset.procedureIndex)])));
}

function renderWaits() {
    const rows = rowsFor(performanceData.waits);
    document.getElementById('waitCount').textContent = rows.length;
    document.getElementById('waitTable').innerHTML = rows.length ? `<table><thead><tr><th>Instance</th><th>Wait Type</th><th>Wait Time</th><th>Tasks</th><th>Signal Wait</th></tr></thead><tbody>${rows.map(r => `<tr><td>${escapeHtml(r.InstanceName)}</td><td><span class="wait-pill">${escapeHtml(r.WaitType)}</span></td><td>${fmtNumber(r.WaitTimeMs)} ms</td><td>${fmtNumber(r.WaitingTasksCount)}</td><td>${fmtNumber(r.SignalWaitTimeMs)} ms</td></tr>`).join('')}</tbody></table>` : '<p class="empty-note">No wait data collected yet.</p>';
}

function renderIo() {
    const rows = rowsFor(performanceData.io);
    document.getElementById('ioCount').textContent = rows.length;
    document.getElementById('ioTable').innerHTML = rows.length ? `<table><thead><tr><th>Instance</th><th>Database</th><th>File</th><th>Type</th><th>Read Latency</th><th>Write Latency</th><th>Reads</th><th>Writes</th></tr></thead><tbody>${rows.map(r => `<tr><td>${escapeHtml(r.InstanceName)}</td><td>${escapeHtml(r.DatabaseName)}</td><td class="query-cell">${escapeHtml(r.PhysicalName)}</td><td>${escapeHtml(r.FileType)}</td><td>${fmtNumber(r.AvgReadLatencyMs, 1)} ms</td><td>${fmtNumber(r.AvgWriteLatencyMs, 1)} ms</td><td>${fmtNumber(r.NumReads)}</td><td>${fmtNumber(r.NumWrites)}</td></tr>`).join('')}</tbody></table>` : '<p class="empty-note">No I/O data collected yet.</p>';
}

function renderAll() {
    renderQueries();
    renderProcedures();
    renderWaits();
    renderIo();
}

function openSqlModal(row) {
    if (!row) return;
    const modal = document.getElementById('sqlModal');
    document.getElementById('sqlModalTitle').textContent = row.ProcedureName || `${row.InstanceName || 'Query'} - ${row.DatabaseName || ''}`;
    document.getElementById('sqlModalText').textContent = row.QueryText || 'SQL text is not available for this sample.';
    modal.hidden = false;
    document.getElementById('closeSqlModal').focus();
}

function closeSqlModal() {
    document.getElementById('sqlModal').hidden = true;
}

async function loadPerformance() {
    const res = await fetch('/api/performance?top=50');
    if (!res.ok) throw new Error('Failed to load performance data');
    performanceData = await res.json();
    renderAll();
}

async function init() {
    try {
        const instances = await (await fetch('/api/instances')).json();
        const filter = document.getElementById('instanceFilter');
        filter.innerHTML += instances.map(i => `<option value="${escapeHtml(i.InstanceId)}">${escapeHtml(i.InstanceName)}</option>`).join('');
        filter.addEventListener('change', () => { selectedInstance = filter.value; renderAll(); });
        document.getElementById('refreshPerformance').addEventListener('click', () => loadPerformance().catch(showError));
        await loadPerformance();
    } catch (err) {
        showError(err);
    }
}

function showError(err) {
    ['queryTable', 'procedureTable', 'waitTable', 'ioTable'].forEach(id => {
        document.getElementById(id).innerHTML = `<p class="panel-state state-error">${escapeHtml(err.message)}</p>`;
    });
}

document.getElementById('closeSqlModal').addEventListener('click', closeSqlModal);
document.querySelector('[data-close-sql]').addEventListener('click', closeSqlModal);
document.addEventListener('keydown', event => { if (event.key === 'Escape') closeSqlModal(); });

init();
