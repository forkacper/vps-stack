// Status page of vps-stack monitor. Reads status.json written by the
// collector on the host and renders it. Values from the file only ever reach
// the page through textContent, never as HTML.
"use strict";

const REFRESH_MS = 10000;
// Data older than this is flagged: the collector writes every 10 seconds.
const STALE_SECONDS = 30;

const $ = (id) => document.getElementById(id);

let lastData = null;
let lastError = null;

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

        rows.push(tr);
    }

    if (rows.length === 0) {
        const tr = document.createElement("tr");
        const td = cell("No containers.", "empty");
        td.colSpan = 7;
        tr.appendChild(td);
        rows.push(tr);
    }
    body.replaceChildren(...rows);

    const running = containers.filter((c) => c.state === "running").length;
    const problems = containers.filter((c) => stateLevel(c) === "bad").length;
    $("containers-summary").textContent = `${running} running of ${containers.length}` +
        (problems > 0 ? ` · ${problems} with problems` : "");
}

function renderFreshness() {
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

async function refresh() {
    try {
        const response = await fetch("status.json", { cache: "no-store", credentials: "same-origin" });
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        const data = await response.json();
        renderHost(data.host || {});
        renderContainers(Array.isArray(data.containers) ? data.containers : [], data.generated_at);
        lastData = data;
        lastError = null;
    } catch (error) {
        lastError = error instanceof Error ? error.message : String(error);
    }
    renderFreshness();
}

refresh();
setInterval(refresh, REFRESH_MS);
// The age label keeps counting between refreshes.
setInterval(renderFreshness, 1000);
document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
        refresh();
    }
});
