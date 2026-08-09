#!/usr/bin/env python3
"""Live PostgREST payload/timing probe (anon key / RLS-visible rows only)."""

from __future__ import annotations

import json
import ssl
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = "https://rhyqjzulpvaeslbaymex.supabase.co/rest/v1"
KEY = "sb_publishable_aEvruC4m4U4OXCHOnGIMHw_sv1btxwP"
OUT = Path("/tmp/occubus_sb_measure")
OUT.mkdir(parents=True, exist_ok=True)

QUERIES = [
    ("tours_star", "tours?select=*&limit=1000"),
    (
        "tours_narrow",
        "tours?select=id,title,from_city,to_city,departure_date,return_date,status,owner_id,created_at&limit=1000",
    ),
    ("passengers_star", "passengers?select=*&limit=1000"),
    (
        "passengers_narrow",
        "passengers?select=id,tour_id,name,phone,assigned_seats,request_lines,payment_status,is_confirmed,cancelled_at,priority_status,trip_type,group_id,age_group,is_handler,is_waitlisted,note,priority_reason,journey_done,pickup_location_id,pickup_location_name,cancel_requested_at,seats_notified_sig,created_at,user_id&limit=1000",
    ),
    ("buses_star", "buses?select=*&limit=1000"),
    (
        "buses_nolayout",
        "buses?select=id,tour_id,bus_number,driver_name,driver_phone,total_seats,bus_price,price_bands,rear_rows,rear_price,front_rows,front_price&limit=1000",
    ),
    ("buses_layout_only", "buses?select=id,layout&limit=1000"),
    ("groups_star", "passenger_groups?select=*&limit=1000"),
    ("finance_bus", "finance_bus_summary?select=*&limit=1000"),
    ("finance_rider", "finance_rider_balance?select=*&limit=1000"),
    ("collections", "collections?select=*&limit=1000"),
    ("expenses", "expenses?select=*&limit=1000"),
    ("handovers", "bus_handovers?select=*&limit=1000"),
    ("incomes", "incomes?select=*&limit=1000"),
    ("claims", "payment_claims?select=*&limit=1000"),
    ("wa_conv", "wa_conversations?select=*&limit=1000"),
    ("customer_memory", "customer_memory?select=*&limit=1000"),
]


def fetch(path: str) -> tuple[int, bytes, float, str]:
    req = urllib.request.Request(
        f"{BASE}/{path}",
        headers={
            "apikey": KEY,
            "Authorization": f"Bearer {KEY}",
            "Prefer": "count=exact",
        },
    )
    ctx = ssl.create_default_context()
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            body = resp.read()
            cr = resp.headers.get("Content-Range", "")
            code = resp.status
    except urllib.error.HTTPError as e:
        body = e.read()
        cr = e.headers.get("Content-Range", "") if e.headers else ""
        code = e.code
    dt = time.perf_counter() - t0
    return code, body, dt, cr


def main() -> None:
    print("=== LIVE MEASUREMENT (anon key / RLS-visible) ===")
    results = []
    for name, path in QUERIES:
        code, body, dt, cr = fetch(path)
        (OUT / f"{name}.json").write_bytes(body)
        try:
            data = json.loads(body)
            rows = len(data) if isinstance(data, list) else "obj"
            err = None if isinstance(data, list) else body[:120]
        except Exception:
            rows = "err"
            err = body[:200]
        line = (
            f"{name:22s} http={code} bytes={len(body):8d} "
            f"time={dt:6.3f}s rows={rows} {cr}"
        )
        if err and code >= 400:
            line += f" body={err!r}"
        print(line)
        results.append(
            {
                "name": name,
                "http": code,
                "bytes": len(body),
                "time_s": round(dt, 3),
                "rows": rows,
                "content_range": cr,
            }
        )

    print("\n=== COMPARISONS ===")
    by = {r["name"]: r for r in results}

    def ratio(a: str, b: str) -> None:
        if a not in by or b not in by or not by[a]["bytes"]:
            return
        saved = 100.0 * (by[a]["bytes"] - by[b]["bytes"]) / by[a]["bytes"]
        print(
            f"{a} {by[a]['bytes']} B → {b} {by[b]['bytes']} B "
            f"(save {saved:.1f}%, Δtime {by[a]['time_s']-by[b]['time_s']:+.3f}s)"
        )

    ratio("tours_star", "tours_narrow")
    ratio("passengers_star", "passengers_narrow")
    ratio("buses_star", "buses_nolayout")
    if by.get("buses_star", {}).get("bytes"):
        share = 100.0 * by["buses_layout_only"]["bytes"] / by["buses_star"]["bytes"]
        print(f"buses layout-only share of buses*: {share:.1f}%")

    # Status breakdown if tours readable
    tours_path = OUT / "tours_star.json"
    try:
        tours = json.loads(tours_path.read_text())
        if isinstance(tours, list):
            from collections import Counter

            c = Counter(t.get("status") for t in tours)
            print("\n=== TOUR STATUS (anon-visible) ===")
            print(f"total={len(tours)}")
            for k, v in c.most_common():
                print(f"  {k}: {v}")
    except Exception as e:
        print("status breakdown failed:", e)

    (OUT / "summary.json").write_text(json.dumps(results, indent=2))
    print(f"\nWrote {OUT}/summary.json")


if __name__ == "__main__":
    main()
