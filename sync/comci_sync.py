"""
컴시간알리미 → Supabase 시간표 동기화

GitHub Actions(.github/workflows/comci-sync.yml)가 평일 정해진 시각에 실행합니다.
- 전체 학년·반의 이번 주와 다음 주 시간표(교체 반영)를 comci_slot 에 저장
- 선생님 번호와 컴시간에 보이는 이름을 comci_teacher 에 저장 (관리자가 입력한 실명은 건드리지 않음)
- 결과를 comci_config 의 last_run_at / last_ok / last_message 에 기록 (관리자 페이지에서 확인)

필요한 GitHub Secret: SUPABASE_SERVICE_KEY  (Supabase 의 secret 키 또는 service_role 키)
Supabase 주소는 저장소의 config.js 에서 읽습니다.
"""
from __future__ import annotations

import os
import re
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import requests

from comci.school_search import search_schools
from comci.timetable import (
    _get_code,
    _get_jaryo,
    extract_timetable_context,
    fetch_timetable_raw,
    parse_ilja_weeks,
    resolve_r_for_date,
)

KST = timezone(timedelta(hours=9))
MAX_PERIOD = 9
EMPTY = 100  # 코드가 이 값 이하이면 수업 없음


# ---------------------------------------------------------------- Supabase
def supabase_url() -> str:
    env = os.environ.get("SUPABASE_URL", "").strip()
    if env:
        return env.rstrip("/")
    cfg = (Path(__file__).resolve().parent.parent / "config.js").read_text(encoding="utf-8")
    m = re.search(r'SUPABASE_URL:\s*"([^"]+)"', cfg)
    if not m:
        raise RuntimeError("config.js 에서 SUPABASE_URL 을 찾지 못했습니다.")
    return m.group(1).rstrip("/")


class SB:
    def __init__(self, url: str, key: str):
        self.base = url + "/rest/v1/"
        self.h = {"apikey": key, "Content-Type": "application/json"}
        if key.startswith("eyJ"):  # 예전 JWT 형식 service_role 키
            self.h["Authorization"] = f"Bearer {key}"

    def _ok(self, r: requests.Response) -> requests.Response:
        if r.status_code >= 300:
            raise RuntimeError(f"Supabase {r.status_code}: {r.text[:300]}")
        return r

    def get(self, path: str):
        return self._ok(requests.get(self.base + path, headers=self.h, timeout=30)).json()

    def patch(self, path: str, body: dict):
        self._ok(requests.patch(self.base + path, headers=self.h, json=body, timeout=30))

    def delete(self, path: str):
        self._ok(requests.delete(self.base + path, headers=self.h, timeout=60))

    def upsert(self, table: str, rows: list, on_conflict: str):
        h = dict(self.h, Prefer="resolution=merge-duplicates,return=minimal")
        for i in range(0, len(rows), 500):
            self._ok(requests.post(f"{self.base}{table}?on_conflict={on_conflict}", headers=h,
                                   json=rows[i:i + 500], timeout=60))


# ---------------------------------------------------------------- 컴시간 해석
def decode_week(raw: dict, day_dates: dict) -> tuple[list, dict]:
    """한 주 원본 JSON → (수업 행 목록, {선생님 번호: (웹 이름, {과목})})"""
    split = raw.get("분리", 100) or 100
    base = _get_jaryo(raw, "481")
    chg = _get_jaryo(raw, "147")
    subjects = _get_jaryo(raw, "492") or []
    teachers = _get_jaryo(raw, "446") or []
    if not isinstance(base, list) or len(base) < 2:
        raise RuntimeError("컴시간 응답에 시간표 자료(481)가 없습니다. 구조가 바뀌었을 수 있습니다.")

    num_grades = int(base[0]) if isinstance(base[0], (int, float)) else len(base) - 1
    rows, tinfo = [], {}
    for g in range(num_grades):
        gdata = base[g + 1] if g + 1 < len(base) else None
        if not isinstance(gdata, list) or not gdata:
            continue
        num_classes = int(gdata[0]) if isinstance(gdata[0], (int, float)) else len(gdata) - 1
        for c in range(num_classes):
            label = f"{g + 1}-{c + 1}"
            for day in range(1, 6):
                d = day_dates.get(day)
                if not d:
                    continue
                for period in range(1, MAX_PERIOD + 1):
                    b = _get_code(base, g, c, day, period)
                    x = _get_code(chg, g, c, day, period) if chg else 0
                    code = x if x > 0 else b
                    if not code or code <= EMPTY:
                        continue
                    if split == 100:
                        t_idx, s_idx = code // split, code % split
                    else:
                        t_idx, s_idx = code % split, code // split
                    subj = subjects[s_idx] if 0 <= s_idx < len(subjects) else None
                    subj = str(subj).strip() if subj not in (None, "") else None
                    wname = teachers[t_idx] if 0 <= t_idx < len(teachers) else None
                    wname = str(wname).strip() if wname not in (None, "") else None
                    rows.append({"label": label, "d": d.isoformat(), "period": period, "subject": subj,
                                 "teacher_idx": t_idx or None, "changed": bool(x > 0 and x != b)})
                    if t_idx:
                        info = tinfo.setdefault(t_idx, [wname, set()])
                        if wname and not info[0]:
                            info[0] = wname
                        if subj:
                            info[1].add(subj)
    return rows, tinfo


def find_school_code(sb: SB, cfg: dict) -> tuple[int, str]:
    if cfg.get("school_code"):
        return int(cfg["school_code"]), cfg.get("school_name") or ""
    name = (cfg.get("school_name") or os.environ.get("SCHOOL_NAME") or "").strip()
    if not name:
        raise RuntimeError("관리자 페이지 [컴시간] 탭에서 학교 이름을 먼저 저장하세요.")
    found = search_schools(name)
    exact = [s for s in found if s["school_name"] == name] or found
    if len(exact) != 1:
        listing = ", ".join(f'{s["region"]} {s["school_name"]}({s["school_code"]})' for s in found[:8]) or "없음"
        raise RuntimeError(f"학교를 하나로 정하지 못했습니다. 검색 결과: {listing}")
    s = exact[0]
    sb.patch("comci_config?id=eq.1", {"school_code": s["school_code"], "school_name": s["school_name"]})
    return int(s["school_code"]), s["school_name"]


def run(sb: SB, today: date) -> str:
    cfg = sb.get("comci_config?id=eq.1&select=*")
    cfg = cfg[0] if cfg else {}
    if cfg.get("enabled") is False:
        return "연동이 꺼져 있어 건너뜀"
    code, school = find_school_code(sb, cfg)

    probe = fetch_timetable_raw(code, 1)
    weeks = parse_ilja_weeks(probe.get("일자자료"))
    r_today = resolve_r_for_date(weeks, today)
    if r_today is None:
        try:
            r_today = int(probe.get("오늘r") or 1)
        except (TypeError, ValueError):
            r_today = 1
    targets = [r_today] + [w["r"] for w in weeks if w["r"] == r_today + 1]

    all_rows, all_t, labels, week_labels = [], {}, set(), []
    for r in targets:
        raw = probe if r == 1 else fetch_timetable_raw(code, r)
        ctx = extract_timetable_context(raw, r)
        day_dates = ctx.get("day_dates") or {}
        if not day_dates:
            continue
        rows, tinfo = decode_week(raw, day_dates)
        if not rows:
            continue
        # 그 주 날짜의 기존 자료를 새 자료로 교체
        dates = ",".join(sorted({dd.isoformat() for dd in day_dates.values()}))
        sb.delete(f"comci_slot?d=in.({dates})")
        sb.upsert("comci_slot", rows, "label,d,period")
        all_rows += rows
        labels |= {x["label"] for x in rows}
        week_labels.append((ctx.get("active_week") or {}).get("label", f"r={r}"))
        for idx, (wname, subs) in tinfo.items():
            cur = all_t.setdefault(idx, [wname, set()])
            cur[0] = cur[0] or wname
            cur[1] |= subs

    if not all_rows:
        raise RuntimeError("받아 온 수업이 없습니다. 학교 이름과 컴시간 공개 여부를 확인하세요.")

    teachers = [{"idx": i, "web_name": w, "subjects": ", ".join(sorted(s))[:80],
                 "updated_at": datetime.now(timezone.utc).isoformat()} for i, (w, s) in sorted(all_t.items())]
    sb.upsert("comci_teacher", teachers, "idx")
    sb.delete(f"comci_slot?d=lt.{(today - timedelta(days=60)).isoformat()}")

    changed = sum(1 for x in all_rows if x["changed"])
    return (f"{school or raw.get('학교명', '')} · {len(labels)}개 반 · 수업 {len(all_rows)}칸"
            f"(교체 {changed}) · 선생님 {len(teachers)}명 · {' / '.join(week_labels)}")


def main() -> int:
    key = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()
    if not key:
        print("SUPABASE_SERVICE_KEY 가 없습니다. GitHub 저장소 Settings → Secrets 에 추가하세요.")
        return 1
    sb = SB(supabase_url(), key)
    now = datetime.now(timezone.utc)
    try:
        msg = run(sb, now.astimezone(KST).date())
        sb.patch("comci_config?id=eq.1", {"last_run_at": now.isoformat(), "last_ok": True, "last_message": msg})
        print("OK:", msg)
        return 0
    except Exception as e:  # noqa: BLE001
        msg = f"{type(e).__name__}: {e}"[:400]
        print("FAIL:", msg)
        try:
            sb.patch("comci_config?id=eq.1", {"last_run_at": now.isoformat(), "last_ok": False, "last_message": msg})
        except Exception as e2:  # noqa: BLE001
            print("상태 기록 실패:", e2)
        return 1


if __name__ == "__main__":
    sys.exit(main())
