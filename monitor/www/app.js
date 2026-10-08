// Status page of vps-stack monitor. Reads status.json written by the
// collector on the host and renders it. Values from the file only ever reach
// the page through textContent, never as HTML.
"use strict";

const REFRESH_MS = 10000;
// history.json gains a sample every 5 minutes; checking every minute is plenty.
const HISTORY_REFRESH_MS = 60000;
const SVG_NS = "http://www.w3.org/2000/svg";
// Data older than this is flagged: the collector writes every 10 seconds.
const STALE_SECONDS = 30;

const $ = (id) => document.getElementById(id);

let lastData = null;
let lastError = null;
// Set after a 401: the browser's stored login is no longer valid.
let stopped = false;
const timers = [];
let history = null;
let historyRange = 86400;

function formatBytes(bytes) {
    if (bytes === null || bytes === undefined) {
        return "–";
    }
    const units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let value = bytes;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit += 1;
    }
    const digits = value >= 100 || unit === 0 ? 0 : 1;
    return `${value.toFixed(digits)} ${units[unit]}`;
}

function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || seconds < 0) {
        return "–";
    }
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (days > 0) {
        return `${days}d ${hours}h`;
    }
    if (hours > 0) {
        return `${hours}h ${minutes}m`;
    }
    if (minutes > 0) {
        return `${minutes}m`;
    }
    return `${Math.floor(seconds)}s`;
}

function percentOf(part, total) {
    if (part === null || total === null || part === undefined || total === undefined || total <= 0) {
        return null;
    }
    return (part / total) * 100;
}

function formatPercent(value) {
    return value === null || value === undefined ? "–" : `${value.toFixed(1)}%`;
}

function level(percent) {
    if (percent === null || percent === undefined) {
        return "ok";
    }
    if (percent >= 90) {
        return "bad";
    }
    if (percent >= 70) {
        return "warn";
    }
    return "ok";
}

function setBar(element, percent) {
    const clamped = percent === null || percent === undefined ? 0 : Math.min(Math.max(percent, 0), 100);
    element.style.width = `${clamped}%`;
    element.dataset.level = level(percent);
}

function renderHost(host) {
    $("hostname").textContent = host.hostname || "Server status";
    $("subtitle").textContent = `Up for ${formatDuration(host.uptime_seconds)}` +
        (host.reboot_required ? " · reboot required after updates" : "");

    $("cpu-value").textContent = formatPercent(host.cpu_percent);
    setBar($("cpu-bar"), host.cpu_percent);
    const load = (host.load || []).map((v) => (v === null ? "–" : v.toFixed(2))).join(" / ");
    $("cpu-detail").textContent = `${host.cpus ?? "–"} cores · load ${load}`;

    const mem = host.memory || {};
    const memPercent = percentOf(mem.used, mem.total);
    $("mem-value").textContent = formatPercent(memPercent);
    setBar($("mem-bar"), memPercent);
    $("mem-detail").textContent = `${formatBytes(mem.used)} of ${formatBytes(mem.total)} · ${formatBytes(mem.available)} available`;

    const swap = host.swap || {};
    const swapPercent = percentOf(swap.used, swap.total);
    $("swap-value").textContent = swap.total ? formatPercent(swapPercent) : "off";
    setBar($("swap-bar"), swapPercent);
    $("swap-detail").textContent = swap.total ? `${formatBytes(swap.used)} of ${formatBytes(swap.total)}` : "no swap configured";

    const disk = host.disk || {};
    const diskPercent = percentOf(disk.used, disk.total);
    $("disk-value").textContent = formatPercent(diskPercent);
    setBar($("disk-bar"), diskPercent);
    $("disk-detail").textContent = `${formatBytes(disk.used)} of ${formatBytes(disk.total)}`;
}

function badge(text, badgeLevel) {
    const span = document.createElement("span");
    span.className = "badge";
    span.dataset.level = badgeLevel;
    span.textContent = text;
    return span;
}

function stateLevel(container) {
    if (container.state === "running") {
        if (container.health === "unhealthy") {
            return "bad";
        }
        return container.health === "starting" ? "warn" : "ok";
    }
    if (container.state === "restarting" || container.state === "dead") {
        return "bad";
    }
    return "idle";
}

// Problems first, then running containers, then stopped ones; by name inside.
function sortContainers(containers) {
    const rank = { bad: 0, warn: 1, ok: 2, idle: 3 };
    return [...containers].sort((a, b) =>
        rank[stateLevel(a)] - rank[stateLevel(b)] || a.name.localeCompare(b.name));
}

function cell(content, className) {
    const td = document.createElement("td");
    if (className) {
        td.className = className;
    }
    if (content instanceof Node) {
        td.appendChild(content);
    } else {
        td.textContent = content;
    }
    return td;
}

function renderContainers(containers, generatedAt) {
    const body = $("containers");
    const rows = [];
    const now = Date.parse(generatedAt);

    for (const c of sortContainers(containers)) {
        const tr = document.createElement("tr");
        tr.appendChild(cell(c.name));

        const image = cell(c.image, "image");
        image.title = c.image;
        tr.appendChild(image);

        const state = document.createElement("span");
        state.appendChild(badge(c.state, stateLevel(c)));
        if (c.state === "running" && c.health) {
            state.appendChild(badge(c.health, c.health === "healthy" ? "ok" : stateLevel(c)));
        }
        tr.appendChild(cell(state));

        const started = Date.parse(c.started_at);
        const upFor = c.state === "running" && !Number.isNaN(started) && !Number.isNaN(now)
            ? formatDuration((now - started) / 1000) : "–";
        tr.appendChild(cell(upFor));
        tr.appendChild(cell(c.restarts === null ? "–" : String(c.restarts), "num"));
        tr.appendChild(cell(formatPercent(c.cpu_percent), "num"));

        const mem = document.createElement("div");
        const label = document.createElement("div");
        label.textContent = c.memory_used === null
            ? "–"
            : `${formatBytes(c.memory_used)} / ${formatBytes(c.memory_limit)}`;
        mem.appendChild(label);
        if (c.memory_used !== null) {
            const bar = document.createElement("div");
            bar.className = "bar";
            const fill = document.createElement("span");
            setBar(fill, c.memory_percent);
            bar.appendChild(fill);
            mem.appendChild(bar);
        }
        tr.appendChild(cell(mem, "mem"));
        tr.appendChild(cell(containerSparkline(c.name), "spark"));

        rows.push(tr);
    }

    if (rows.length === 0) {
        const tr = document.createElement("tr");
        const td = cell("No containers.", "empty");
        td.colSpan = 8;
        tr.appendChild(td);
        rows.push(tr);
    }
    body.replaceChildren(...rows);

    const running = containers.filter((c) => c.state === "running").length;
    const problems = containers.filter((c) => stateLevel(c) === "bad").length;
    $("containers-summary").textContent = `${running} running of ${containers.length}` +
        (problems > 0 ? ` · ${problems} with problems` : "");
}

// The state of a backup group comes from the server (the same thresholds as
// vps-stack verify); only the label and the age are formatted here.
const BACKUP_LEVELS = { ok: "ok", warn: "warn", error: "bad" };

function renderBackups(backups, generatedAt) {
    const section = $("backups-section");
    // No backup groups: the section stays hidden.
    section.hidden = backups.length === 0;
    if (backups.length === 0) {
        return;
    }
    const now = Date.parse(generatedAt);
    const rows = backups.map((b) => {
        const tr = document.createElement("tr");
        tr.appendChild(cell(b.group));
        const badgeLevel = BACKUP_LEVELS[b.state] || "warn";
        const label = b.last_ok ? b.state : "never";
        tr.appendChild(cell(badge(label, badgeLevel)));
        const last = Date.parse(b.last_ok);
        tr.appendChild(cell(Number.isNaN(last) ? "–" : formatTime(last / 1000)));
        tr.appendChild(cell(Number.isNaN(last) || Number.isNaN(now) ? "–" : `${formatDuration((now - last) / 1000)} ago`));
        return tr;
    });
    $("backups").replaceChildren(...rows);
    const problems = backups.filter((b) => b.state !== "ok").length;
    $("backups-summary").textContent = `${backups.length} ${backups.length === 1 ? "group" : "groups"}` +
        (problems > 0 ? ` · ${problems} need attention` : "");
}

function renderFreshness() {
    if (stopped) {
        return;
    }
    const freshness = $("freshness");
    const banner = $("banner");

    if (!lastData) {
        freshness.dataset.state = lastError ? "error" : "loading";
        freshness.textContent = lastError ? "No data" : "Loading…";
        banner.hidden = !lastError;
        banner.textContent = lastError ? `Cannot load status.json: ${lastError}` : "";
        return;
    }

    const age = Math.max(0, (Date.now() - Date.parse(lastData.generated_at)) / 1000);
    const stale = Number.isNaN(age) || age > STALE_SECONDS;
    freshness.dataset.state = stale ? "stale" : "fresh";
    freshness.textContent = Number.isNaN(age) ? "Unknown age" : `Updated ${formatDuration(age)} ago`;

    let message = "";
    if (stale) {
        message = "The data is out of date: the collector on the server is not writing new values (check: sudo vps-stack monitor status).";
    } else if (lastError) {
        message = `Last refresh failed (${lastError}); showing the previous data.`;
    } else if (!lastData.docker_available) {
        message = "Docker is not responding on the server: the container list may be empty or incomplete.";
    }
    banner.hidden = message === "";
    banner.textContent = message;
}

// --- history ----------------------------------------------------------------

// samplesIn(seconds): the samples of the last <seconds>, oldest first.
function samplesIn(seconds) {
    if (!history || !Array.isArray(history.samples)) {
        return [];
    }
    const newest = history.samples.length > 0 ? history.samples[history.samples.length - 1].t : 0;
    return history.samples.filter((s) => s.t >= newest - seconds);
}

// A gap longer than this many sampling intervals (the collector or the
// server was down) breaks the line instead of being drawn across.
const GAP_FACTOR = 2.5;

function segments(points, interval) {
    const result = [];
    let current = [];
    let previous = null;
    for (const p of points) {
        if (p.v === null || p.v === undefined || Number.isNaN(p.v)) {
            previous = null;
            if (current.length > 0) {
                result.push(current);
                current = [];
            }
            continue;
        }
        if (previous !== null && p.t - previous > interval * GAP_FACTOR && current.length > 0) {
            result.push(current);
            current = [];
        }
        current.push(p);
        previous = p.t;
    }
    if (current.length > 0) {
        result.push(current);
    }
    return result;
}

function svg(tag, attributes) {
    const element = document.createElementNS(SVG_NS, tag);
    for (const [name, value] of Object.entries(attributes || {})) {
        element.setAttribute(name, String(value));
    }
    return element;
}

// plot(series, from, to, yMin, yMax, width, height, interval): an SVG with one
// polyline per continuous segment of every series.
// Series: [{points: [{t, v}], className}].
function plot(series, from, to, yMin, yMax, width, height, interval) {
    const chart = svg("svg", { viewBox: `0 0 ${width} ${height}`, preserveAspectRatio: "none", "aria-hidden": "true" });
    const span = Math.max(to - from, 1);
    const range = yMax > yMin ? yMax - yMin : 1;
    const x = (t) => ((t - from) / span) * width;
    const y = (v) => height - ((Math.min(Math.max(v, yMin), yMin + range) - yMin) / range) * (height - 2) - 1;
    for (const s of series) {
        for (const segment of segments(s.points, interval)) {
            const coordinates = segment.length === 1
                ? `${x(segment[0].t) - 1},${y(segment[0].v)} ${x(segment[0].t) + 1},${y(segment[0].v)}`
                : segment.map((p) => `${x(p.t).toFixed(1)},${y(p.v).toFixed(1)}`).join(" ");
            chart.appendChild(svg("polyline", { points: coordinates, class: s.className, "vector-effect": "non-scaling-stroke" }));
        }
    }
    return chart;
}

function formatTime(epoch) {
    const date = new Date(epoch * 1000);
    const time = date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    return `${date.toLocaleDateString([], { day: "numeric", month: "short" })} ${time}`;
}

function stats(values) {
    const numbers = values.filter((v) => typeof v === "number" && !Number.isNaN(v));
    if (numbers.length === 0) {
        return null;
    }
    return { min: Math.min(...numbers), max: Math.max(...numbers), last: numbers[numbers.length - 1] };
}

// The charts: what each one draws, its scale and how values are shown.
const CHARTS = {
    cpu: {
        series: [
            { key: "cpu_max", className: "line-faint" },
            { key: "cpu", className: "line-main" },
        ],
        max: () => 100,
        format: (v) => formatPercent(v),
        summary: "cpu",
    },
    mem: {
        series: [{ key: "mem", className: "line-main" }],
        max: (samples) => Math.max(...samples.map((s) => s.mem_total || 0)),
        format: (v) => formatBytes(v),
        summary: "mem",
        of: "mem_total",
    },
    disk: {
        series: [{ key: "disk", className: "line-main" }],
        max: (samples) => Math.max(...samples.map((s) => s.disk_total || 0)),
        format: (v) => formatBytes(v),
        summary: "disk",
        of: "disk_total",
    },
    load: {
        series: [{ key: "load", className: "line-main" }],
        max: (samples) => Math.max(1, ...samples.map((s) => s.load || 0)) * 1.1,
        format: (v) => (v === null || v === undefined ? "–" : v.toFixed(2)),
        summary: "load",
    },
};

function renderHistory() {
    const samples = samplesIn(historyRange);
    const interval = (history && history.interval_seconds) || 300;
    $("history-empty").hidden = samples.length > 1;
    $("charts").hidden = samples.length <= 1;
    if (samples.length <= 1) {
        return;
    }
    const from = samples[0].t;
    const to = samples[samples.length - 1].t;

    for (const article of document.querySelectorAll("[data-chart]")) {
        const definition = CHARTS[article.dataset.chart];
        const series = definition.series.map((s) => ({
            className: s.className,
            points: samples.map((sample) => ({ t: sample.t, v: sample[s.key] })),
        }));
        const yMax = definition.max(samples);
        const plotArea = article.querySelector(".chart-plot");
        plotArea.replaceChildren(plot(series, from, to, 0, yMax, 600, 120, interval));

        const summary = stats(samples.map((s) => s[definition.summary]));
        const value = article.querySelector(".chart-value");
        if (summary === null) {
            value.textContent = "–";
        } else {
            const of = definition.of ? ` of ${definition.format(samples[samples.length - 1][definition.of])}` : "";
            value.textContent = `${definition.format(summary.last)}${of} · lowest ${definition.format(summary.min)} · highest ${definition.format(summary.max)}`;
        }
        article.querySelector(".chart-axis").textContent = `${formatTime(from)} – ${formatTime(to)}`;
        plotArea.setAttribute("role", "img");
        plotArea.setAttribute("aria-label", `${article.querySelector("h3").textContent}: ${value.textContent}`);
    }
}

// containerSparkline(name): the memory of one container over the last 24
// hours, or a dash when there is no history for it.
function containerSparkline(name) {
    const samples = samplesIn(86400);
    const points = samples.map((s) => ({ t: s.t, v: s.containers ? s.containers[name] : null }));
    const known = points.filter((p) => typeof p.v === "number");
    if (known.length < 2) {
        const dash = document.createElement("span");
        dash.className = "muted";
        dash.textContent = "–";
        return dash;
    }
    const interval = (history && history.interval_seconds) || 300;
    // From the lowest to the highest value: the sparkline shows the trend
    // (e.g. memory creeping up), the column next to it the absolute value.
    // The scale spans at least 10% of the value, so that noise in a stable
    // value does not look like a swing.
    const range = stats(known.map((p) => p.v));
    const minSpan = range.max * 0.1;
    let low = range.min;
    let high = range.max;
    if (high - low < minSpan) {
        const middle = (high + low) / 2;
        low = middle - minSpan / 2;
        high = middle + minSpan / 2;
    }
    const chart = plot([{ points, className: "line-main" }], samples[0].t, samples[samples.length - 1].t,
        low, high, 120, 28, interval);
    chart.setAttribute("class", "sparkline");
    const wrapper = document.createElement("span");
    wrapper.title = `24 h: ${formatBytes(range.min)} – ${formatBytes(range.max)}`;
    wrapper.appendChild(chart);
    return wrapper;
}

// stopPolling: after a 401 the login the browser keeps is no longer valid,
// usually because the password was changed. Polling on would send it every
// few seconds; each attempt counts as a failed login and fail2ban would ban
// this address. So the page stops and asks for a reload.
function stopPolling() {
    if (stopped) {
        return;
    }
    stopped = true;
    timers.forEach((timer) => clearInterval(timer));
    const freshness = $("freshness");
    freshness.dataset.state = "error";
    freshness.textContent = "Stopped";
    const banner = $("banner");
    banner.hidden = false;
    banner.textContent = "The login is no longer valid (was the password changed?). The page stopped refreshing: reload it and log in again.";
}

async function refreshHistory() {
    if (stopped) {
        return;
    }
    try {
        const response = await fetch("history.json", { cache: "no-store", credentials: "same-origin" });
        if (response.status === 401) {
            stopPolling();
            return;
        }
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        history = await response.json();
    } catch (error) {
        // The page works without history (e.g. right after enabling).
        history = null;
    }
    renderHistory();
    if (lastData) {
        renderContainers(Array.isArray(lastData.containers) ? lastData.containers : [], lastData.generated_at);
    }
}

for (const button of document.querySelectorAll("[data-range]")) {
    button.addEventListener("click", () => {
        historyRange = Number(button.dataset.range);
        for (const other of document.querySelectorAll("[data-range]")) {
            other.setAttribute("aria-pressed", String(other === button));
        }
        renderHistory();
    });
}

async function refresh() {
    if (stopped) {
        return;
    }
    try {
        const response = await fetch("status.json", { cache: "no-store", credentials: "same-origin" });
        if (response.status === 401) {
            stopPolling();
            return;
        }
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        const data = await response.json();
        renderHost(data.host || {});
        renderContainers(Array.isArray(data.containers) ? data.containers : [], data.generated_at);
        renderBackups(Array.isArray(data.backups) ? data.backups : [], data.generated_at);
        lastData = data;
        lastError = null;
    } catch (error) {
        lastError = error instanceof Error ? error.message : String(error);
    }
    renderFreshness();
}

refresh();
refreshHistory();
timers.push(setInterval(refresh, REFRESH_MS));
timers.push(setInterval(refreshHistory, HISTORY_REFRESH_MS));
// The age label keeps counting between refreshes.
timers.push(setInterval(renderFreshness, 1000));
document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
        refresh();
        refreshHistory();
    }
});
