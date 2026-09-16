import json
import os
import statistics
import sys

PALETTE = ["#2563eb", "#64748b", "#0f766e", "#b45309", "#7c3aed", "#be123c"]
BAR = 18
GAP = 6
GROUP_GAP = 18
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
    height = TOP + rows * (BAR + GAP) + len(groups) * GROUP_GAP + 24
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


def main():
    out_dir = sys.argv[1]
    dest = sys.argv[2]
    os.makedirs(dest, exist_ok=True)
    rows = load(os.path.join(out_dir, "results.jsonl"))

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
    for row in rows:
        memory.setdefault(("peak while forwarding", row["engine"]), []).append(row["rss_kb"] / 1024.0)
    if memory:
        engines = sorted({key[1] for key in memory}, key=lambda name: (0 if name.startswith("zeptun") else 1, name))
        chart(
            os.path.join(dest, "memory.svg"),
            "Resident memory",
            "highest sample of every run",
            ["peak while forwarding"],
            engines,
            {key: max(items) for key, items in memory.items()},
            "MB",
            "lower is better",
        )


if __name__ == "__main__":
    main()
