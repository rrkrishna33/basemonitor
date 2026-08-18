function escapeHtml(str) {
    if (str == null) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function showNotice(message, level = 'info') {
    const root = document.getElementById('settingsNotice');
    const cls = level === 'error' ? 'panel-state state-error' : 'panel-state state-loading';
    root.innerHTML = `<div class="${cls}">${escapeHtml(message)}</div>`;
}

async function api(url, options = {}) {
    const res = await fetch(url, {
        headers: { 'Content-Type': 'application/json' },
        ...options
    });

    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
        throw new Error(data.error || 'Request failed');
    }
    return data;
}

function renderServers(servers) {
    const wrap = document.getElementById('serversTableWrap');
    if (!servers.length) {
        wrap.innerHTML = '<p class="empty-note">No servers configured yet.</p>';
        return;
    }

    const rows = servers.map(s => `
        <tr>
            <td>${escapeHtml(s.Name)}</td>
            <td>${escapeHtml(s.Tags || '')}</td>
            <td>${escapeHtml(s.ConnectionString || '')}</td>
            <td><button class="delete-btn" type="button" data-name="${escapeHtml(s.Name)}">Remove</button></td>
        </tr>
    `).join('');

    wrap.innerHTML = `
        <table>
            <thead>
                <tr>
                    <th>Name</th>
                    <th>Tags</th>
                    <th>Connection String</th>
                    <th>Action</th>
                </tr>
            </thead>
            <tbody>${rows}</tbody>
        </table>
    `;

    wrap.querySelectorAll('.delete-btn').forEach(btn => {
        btn.addEventListener('click', async () => {
            const name = btn.dataset.name;
            if (!confirm(`Remove server ${name}?`)) return;
            try {
                const result = await api(`/api/settings/servers/${encodeURIComponent(name)}`, { method: 'DELETE' });
                renderServers(result.servers || []);
                showNotice('Server removed successfully.');
            } catch (err) {
                showNotice(err.message, 'error');
            }
        });
    });
}

function loadAlerts(alerts) {
    const fields = [
        'cpuWarningPercent',
        'cpuCriticalPercent',
        'fullBackupWarningHours',
        'fullBackupCriticalHours',
        'logBackupWarningHours',
        'blockingCriticalMs'
    ];
    fields.forEach(f => {
        const el = document.getElementById(f);
        if (el) el.value = alerts[f] ?? '';
    });
}

async function init() {
    try {
        showNotice('Loading settings...');
        const data = await api('/api/settings');
        renderServers(data.servers || []);
        loadAlerts(data.alerts || {});
        showNotice('Settings loaded.');
    } catch (err) {
        showNotice(err.message, 'error');
    }
}

document.getElementById('serverForm').addEventListener('submit', async e => {
    e.preventDefault();
    try {
        const payload = {
            name: document.getElementById('serverName').value.trim(),
            tags: document.getElementById('serverTags').value.trim(),
            connectionString: document.getElementById('serverConnectionString').value.trim()
        };
        const result = await api('/api/settings/servers', {
            method: 'POST',
            body: JSON.stringify(payload)
        });

        renderServers(result.servers || []);
        e.target.reset();
        showNotice('Server added successfully.');
    } catch (err) {
        showNotice(err.message, 'error');
    }
});

document.getElementById('alertsForm').addEventListener('submit', async e => {
    e.preventDefault();
    try {
        const payload = {
            cpuWarningPercent: Number(document.getElementById('cpuWarningPercent').value),
            cpuCriticalPercent: Number(document.getElementById('cpuCriticalPercent').value),
            fullBackupWarningHours: Number(document.getElementById('fullBackupWarningHours').value),
            fullBackupCriticalHours: Number(document.getElementById('fullBackupCriticalHours').value),
            logBackupWarningHours: Number(document.getElementById('logBackupWarningHours').value),
            blockingCriticalMs: Number(document.getElementById('blockingCriticalMs').value)
        };

        await api('/api/settings/alerts', {
            method: 'PUT',
            body: JSON.stringify(payload)
        });

        showNotice('Alert thresholds saved successfully.');
    } catch (err) {
        showNotice(err.message, 'error');
    }
});

init();
