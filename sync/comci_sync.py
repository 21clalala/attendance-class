"""
컴시간알리미 → Supabase 시간표 동기화

GitHub Actions(.github/workflows/comci-sync.yml)가 평일 정해진 시각에 실행합니다.
- 전체 학년·반의 이번 주와 다음 주 시간표(교체 반영)를 comci_slot 에 저장
- 선생님 번호와 컴시간에 보이는 이름을 comci_teacher 에 저장 (관리자가 입력한 실명은 건드리지 않음)
- 결과를 comci_config 의 last_run_at / last_ok / last_message 에 기록 (관리자 페이지에서 확인)

필요한 GitHub Secret: COMCI_SYNC_TOKEN  (관리자 페이지 [컴시간] 탭의 동기화 토큰)
Supabase 주소와 공개 키는 저장소의 config.js 에서 읽습니다.
이 토큰으로는 컴시간 시간표 자료만 쓸 수 있습니다 (DB 함수 comci_sync_* 가 토큰을 확인).
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
def read_config_js() -> tuple[str, str]:
    cfg = (Path(__file__).resolve().parent.parent / "config.js").read_text(encoding="utf-8")
    url = re.search(r'SUPABASE_URL:\s*"([^"]+)"', cfg)
    key = re.search(r'SUPABASE_KEY:\s*"([^"]+)"', cfg)
    if not url or not key:
        raise RuntimeError("config.js 에서 SUPABASE_URL / SUPABASE_KEY 를 찾지 못했습니다.")
    return url.group(1).rstrip("/"), key.group(1)


class SB:
    """토큰을 확인하는 DB 함수(comci_sync_*)만 호출합니다."""

    def __init__(self, url: str, public_key: str, token: str):
        self.base = url + "/rest/v1/rpc/"
        self.h = {"apikey": public_key, "Content-Type": "application/json"}
        if public_key.startswith("eyJ"):  # 예전 JWT 형식 anon 키
            self.h["Authorization"] = f"Bearer {public_key}"
        self.token = token

    def rpc(self, fn: str, **args):
        r = requests.post(self.base + fn, headers=self.h, json={"p_token": self.token, **args}, timeout=60)
        if r.status_code >= 300:
            msg = r.text[:300]
            if "invalid_sync_token" in msg:
                msg = "동기화 토큰이 맞지 않습니다. [컴시간] 탭의 토큰을 GitHub Secret COMCI_SYNC_TOKEN 에 다시 넣으세요."
            raise RuntimeError(f"Supabase {r.status_code}: {msg}")
        return r.json() if r.text else None


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
    sb.rpc("comci_sync_set_school", p_code=int(s["school_code"]), p_name=s["school_name"])
    return int(s["school_code"]), s["school_name"]


def run(sb: SB, today: date) -> str:
    cfg = sb.rpc("comci_sync_config") or {}
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
        dates = sorted({dd.isoformat() for dd in day_dates.values()})
        sb.rpc("comci_sync_week", p_dates=dates, p_rows=rows)
        all_rows += rows
        labels |= {x["label"] for x in rows}
        week_labels.append((ctx.get("active_week") or {}).get("label", f"r={r}"))
        for idx, (wname, subs) in tinfo.items():
            cur = all_t.setdefault(idx, [wname, set()])
            cur[0] = cur[0] or wname
            cur[1] |= subs

    if not all_rows:
        raise RuntimeError("받아 온 수업이 없습니다. 학교 이름과 컴시간 공개 여부를 확인하세요.")

    teachers = [{"idx": i, "web_name": w, "subjects": ", ".join(sorted(s))[:80]}
                for i, (w, s) in sorted(all_t.items())]
    sb.rpc("comci_sync_teachers", p_rows=teachers)

    changed = sum(1 for x in all_rows if x["changed"])
    return (f"{school or raw.get('학교명', '')} · {len(labels)}개 반 · 수업 {len(all_rows)}칸"
            f"(교체 {changed}) · 선생님 {len(teachers)}명 · {' / '.join(week_labels)}")


def annotate(level: str, msg: str) -> None:
    """GitHub Actions 요약 화면(Annotations)에 바로 보이게 출력"""
    print(msg)
    one_line = msg.replace("%", "%25").replace("\r", "").replace("\n", " ")
    print(f"::{level} title=컴시간 동기화::{one_line}")


def main() -> int:
    token = os.environ.get("COMCI_SYNC_TOKEN", "").strip()
    if not token:
        annotate("error", "COMCI_SYNC_TOKEN 이 없습니다. GitHub 저장소 Settings → Secrets and variables → Actions 에 이름 COMCI_SYNC_TOKEN 으로 추가하세요.")
        return 1
    url, public_key = read_config_js()
    sb = SB(url, public_key, token)
    now = datetime.now(timezone.utc)
    try:
        msg = run(sb, now.astimezone(KST).date())
        sb.rpc("comci_sync_finish", p_ok=True, p_message=msg)
        annotate("notice", "OK: " + msg)
        return 0
    except Exception as e:  # noqa: BLE001
        msg = f"{type(e).__name__}: {e}"[:400]
        annotate("error", "FAIL: " + msg)
        if "invalid_sync_token" not in msg and "토큰이 맞지 않습니다" not in msg:
            try:
                sb.rpc("comci_sync_finish", p_ok=False, p_message=msg)
            except Exception as e2:  # noqa: BLE001
                print("상태 기록 실패:", e2)
        return 1


if __name__ == "__main__":
    sys.exit(main())
