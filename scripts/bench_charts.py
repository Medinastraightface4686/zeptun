import json
import os
import statistics
import sys

PALETTE = ["#2563eb", "#64748b", "#0f766e", "#b45309", "#7c3aed", "#be123c"]
BAR = 18
GAP = 6
GROUP_GAP = 18
GROUP_HEAD = 20
LEFT = 150
RIGHT = 90
TOP = 56


def load(path):
    rows = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def detail(out_dir, engine, scenario, rep):
    path = os.path.join(out_dir, f"{engine}-{scenario}-{rep}.json")
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def number(value):
    try:
        return float(str(value).split()[0])
    except (TypeError, ValueError):
        return 0.0


def escape(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def chart(path, title, note, groups, engines, values, unit, better):
    rows = sum(len(engines) for _ in groups)
    height = TOP + rows * (BAR + GAP) + len(groups) * (GROUP_GAP + GROUP_HEAD) + 24
    width = 920
    span = width - LEFT - RIGHT
    top = max([values.get((g, e), 0.0) for g in groups for e in engines] + [1.0])
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        'font-family="-apple-system,Segoe UI,Roboto,sans-serif" font-size="13">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        f'<text x="16" y="24" font-size="15" font-weight="600" fill="#0f172a">{escape(title)}</text>',
        f'<text x="16" y="42" font-size="12" fill="#64748b">{escape(note)} &#183; {escape(better)}</text>',
    ]
    y = TOP
    for group in groups:
        out.append(
            f'<text x="16" y="{y + 12}" font-size="12" font-weight="600" fill="#334155">{escape(group)}</text>'
        )
        y += GROUP_HEAD
        for index, engine in enumerate(engines):
            value = values.get((group, engine), 0.0)
            length = 0 if top == 0 else max(2, int(span * value / top))
            color = PALETTE[index % len(PALETTE)]
            out.append(
                f'<text x="{LEFT - 8}" y="{y + BAR - 4}" text-anchor="end" font-size="12" fill="#475569">{escape(engine)}</text>'
            )
            out.append(
                f'<rect x="{LEFT}" y="{y}" width="{length}" height="{BAR - 2}" rx="3" fill="{color}"/>'
            )
            label = f"{value:.2f}" if value < 100 else f"{value:.0f}"
            out.append(
                f'<text x="{LEFT + length + 8}" y="{y + BAR - 4}" font-size="12" fill="#0f172a">{label} {escape(unit)}</text>'
            )
            y += BAR + GAP
        y += GROUP_GAP
    out.append("</svg>")
    with open(path, "w") as handle:
        handle.write("\n".join(out) + "\n")


def collect(rows, out_dir, scenarios, pick):
    values = {}
    for row in rows:
        key = (row["scenario"], row["engine"])
        if row["scenario"] not in scenarios:
            continue
        values.setdefault(key, []).append(pick(row, detail(out_dir, row["engine"], row["scenario"], row["rep"])))
    return {key: statistics.median(items) for key, items in values.items()}


def order(rows, scenarios):
    engines = []
    for row in rows:
        if row["scenario"] in scenarios and row["engine"] not in engines:
            engines.append(row["engine"])
    engines.sort(key=lambda name: (0 if name.startswith("zeptun") else 1, name))
    present = [s for s in scenarios if any(r["scenario"] == s for r in rows)]
    return present, engines


def compact(path, title, note, rows, unit, better, width=440, paired=False):
    label_width = 128
    bar = 15 if not paired else 9
    gap = 5 if not paired else 9
    top = 46 if not paired else 60
    height = top + len(rows) * (bar * (2 if paired else 1) + gap) + 12
    span = width - label_width - 74
    best = max([max(value) if paired else value for _, value in rows] + [1.0])
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        'font-family="-apple-system,Segoe UI,Roboto,sans-serif" font-size="12">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        f'<text x="12" y="20" font-size="13" font-weight="600" fill="#0f172a">{escape(title)}</text>',
        f'<text x="12" y="36" font-size="11" fill="#64748b">{escape(note)} &#183; {escape(better)}</text>',
    ]
    if paired:
        out.append(
            f'<rect x="{label_width}" y="44" width="9" height="7" rx="2" fill="{PALETTE[0]}"/>'
            f'<text x="{label_width + 14}" y="51" font-size="10" fill="#64748b">under load</text>'
            f'<rect x="{label_width + 86}" y="44" width="9" height="7" rx="2" fill="{PALETTE[0]}" opacity="0.4"/>'
            f'<text x="{label_width + 100}" y="51" font-size="10" fill="#64748b">after it stops</text>'
        )
    y = top
    for index, (name, value) in enumerate(rows):
        series = value if paired else (value,)
        color = PALETTE[0] if index == 0 else "#94a3b8"
        label_y = y + (bar * 2 - 4 if paired else bar - 3)
        out.append(
            f'<text x="{label_width - 8}" y="{label_y}" text-anchor="end" font-size="11" fill="#475569">{escape(name)}</text>'
        )
        for slot, item in enumerate(series):
            length = 0 if best == 0 else max(2, int(span * item / best))
            fade = ' opacity="0.4"' if slot else ""
            out.append(
                f'<rect x="{label_width}" y="{y + slot * bar}" width="{length}" height="{bar - 2}" rx="2" fill="{color}"{fade}/>'
            )
            text = f"{item:.1f}" if item < 100 else f"{item:.0f}"
            out.append(
                f'<text x="{label_width + length + 6}" y="{y + slot * bar + bar - 3}" font-size="11" fill="#0f172a">{text} {escape(unit)}</text>'
            )
        y += bar * (2 if paired else 1) + gap
    out.append("</svg>")
    with open(path, "w") as handle:
        handle.write("\n".join(out) + "\n")


NAMES = {
    "zeptun-userspace": "zeptun",
    "zeptun-hybrid": "zeptun hybrid",
    "hev": "hev-socks5-tunnel",
    "singbox-system": "sing-box system",
    "singbox-gvisor": "sing-box gvisor",
    "tun2socks": "tun2socks",
}


def summary(rows, out_dir, dest):
    wanted = ["zeptun-userspace", "hev", "singbox-system", "singbox-gvisor", "tun2socks"]

    def rank(scenario, pick, reverse=True):
        values = {}
        for row in rows:
            if row["scenario"] != scenario or row["engine"] not in wanted:
                continue
            values.setdefault(row["engine"], []).append(pick(row, detail(out_dir, row["engine"], scenario, row["rep"])))
        ordered = [(NAMES.get(name, name), statistics.median(items)) for name, items in values.items()]
        ordered.sort(key=lambda item: item[1], reverse=reverse)
        head = [item for item in ordered if item[0] == "zeptun"]
        return head + [item for item in ordered if item[0] != "zeptun"]

    speed = rank("tcp-up-10", lambda row, _: number(row["value"]))
    if speed:
        compact(
            os.path.join(dest, "summary-throughput.svg"),
            "Throughput, 10 streams through SOCKS5",
            "GitHub-hosted runner",
            speed,
            "Gbit/s",
            "higher is better",
        )
    cpu = rank("tcp-up-10", lambda row, _: float(row["cpu_pct"]), reverse=False)
    if cpu:
        compact(
            os.path.join(dest, "summary-cpu.svg"),
            "CPU at the same load",
            "GitHub-hosted runner",
            cpu,
            "%",
            "lower is better",
        )
    memory = {}
    settle = 0
    for row in rows:
        if row["scenario"] != "tcp-down-10" or row["engine"] not in wanted:
            continue
        if "rss_after_kb" not in row:
            continue
        settle = max(settle, row.get("settle_s", 0))
        peak, rest = memory.setdefault(NAMES.get(row["engine"], row["engine"]), ([], []))
        peak.append(row["rss_kb"] / 1024.0)
        rest.append(row["rss_after_kb"] / 1024.0)
    if memory:
        ordered = [
            (name, (statistics.median(peak), statistics.median(rest)))
            for name, (peak, rest) in memory.items()
        ]
        ordered.sort(key=lambda item: item[1][1])
        head = [item for item in ordered if item[0] == "zeptun"]
        compact(
            os.path.join(dest, "summary-memory.svg"),
            "Memory while downloading, 10 streams",
            "%d s of idle before the second reading" % settle,
            head + [item for item in ordered if item[0] != "zeptun"],
            "MB",
            "lower is better",
            paired=True,
        )
    tps = rank("rr-8x1k", lambda _, d: d.get("tps", 0.0))
    if tps:
        compact(
            os.path.join(dest, "summary-transactions.svg"),
            "Request/response, 8 connections",
            "GitHub-hosted runner",
            tps,
            "tps",
            "higher is better",
        )


def main():
    out_dir = sys.argv[1]
    dest = sys.argv[2]
    os.makedirs(dest, exist_ok=True)
    rows = load(os.path.join(out_dir, "results.jsonl"))
    summary(rows, out_dir, dest)

    bulk = ["tcp-up-1", "tcp-up-10", "tcp-down-1", "tcp-down-10"]
    scenarios, engines = order(rows, bulk)
    if scenarios:
        chart(
            os.path.join(dest, "throughput.svg"),
            "Throughput through a SOCKS5 proxy",
            "median of the repeats",
            scenarios,
            engines,
            collect(rows, out_dir, scenarios, lambda row, _: number(row["value"])),
            "Gbit/s",
            "higher is better",
        )
        chart(
            os.path.join(dest, "cpu.svg"),
            "CPU while forwarding",
            "median of the repeats, all engine threads",
            scenarios,
            engines,
            collect(rows, out_dir, scenarios, lambda row, _: float(row["cpu_pct"])),
            "%",
            "lower is better",
        )

    latency = ["rr", "rr-8x1k", "crr"]
    scenarios, engines = order(rows, latency)
    if scenarios:
        chart(
            os.path.join(dest, "transactions.svg"),
            "Request/response rate",
            "median of the repeats",
            scenarios,
            engines,
            collect(rows, out_dir, scenarios, lambda _, d: d.get("tps", 0.0)),
            "tps",
            "higher is better",
        )
        chart(
            os.path.join(dest, "latency.svg"),
            "Request/response latency, 99th percentile",
            "median of the repeats",
            scenarios,
            engines,
            collect(rows, out_dir, scenarios, lambda _, d: d.get("p99_us", 0.0)),
            "us",
            "lower is better",
        )

    udp = ["udp-100k", "udp-gso-100k"]
    scenarios, engines = order(rows, udp)
    if scenarios:
        chart(
            os.path.join(dest, "udp.svg"),
            "UDP datagrams echoed",
            "median of the repeats",
            scenarios,
            engines,
            collect(
                rows,
                out_dir,
                scenarios,
                lambda _, d: d.get("received", 0) / max(d.get("seconds", 1), 1e-9),
            ),
            "pps",
            "higher is better",
        )

    memory = {}
    settle = 0
    for row in rows:
        memory.setdefault(("peak while forwarding", row["engine"]), []).append(row["rss_kb"] / 1024.0)
        if "rss_after_kb" in row:
            memory.setdefault(("after the load stops", row["engine"]), []).append(row["rss_after_kb"] / 1024.0)
            settle = max(settle, row.get("settle_s", 0))
    if memory:
        engines = sorted({key[1] for key in memory}, key=lambda name: (0 if name.startswith("zeptun") else 1, name))
        groups = ["peak while forwarding"]
        values = {key: max(items) for key, items in memory.items() if key[0] == groups[0]}
        note = "highest sample of every run"
        if settle:
            groups.append("after the load stops")
            for key, items in memory.items():
                if key[0] == groups[1]:
                    values[key] = max(items)
            note = "highest sample of every run, then again after %d s of idle" % settle
        chart(
            os.path.join(dest, "memory.svg"),
            "Resident memory",
            note,
            groups,
            engines,
            values,
            "MB",
            "lower is better",
        )


if __name__ == "__main__":
    main()
