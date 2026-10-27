/* 학교장허가 교외체험학습 — 회차 등록·자동 입력·사용 일수·보고서·이전 기록 붙여넣기
   admin.html 의 공용 함수(sb, $, must, esc, fmtDate, CUR, curClass, ME_EMAIL, kstToday, say, BOARD, loadBoard, loadDoc …)를 씀 */
(function(){
  const LIMIT = 20;
  const NOTE_REASON = "학교장허가 교외체험학습";
  const RULE_HTML = `교외체험학습은 1일 단위로 운영하며, 교외체험학습 시간이 4차시 미만일 경우 반일을 허가할 수 있음
    (반일은 4차시 미만, 즉 <b>수업시수 3차시 이하</b>인 경우 반일 처리 가능)<br>
    <b>[반일 처리 예시]</b><br>
    ▸ 4교시인 경우: 1교시 수업 후 2~4교시 교외체험학습인 경우 → 반일처리 가능<br>
    ▸ 5교시인 경우: 1~2교시 수업 후 3~5교시 교외체험학습인경우 → 반일처리 가능<br>
    ▸ 6교시인 경우: 1~3교시 교외체험학습, 4~6교시 수업인 경우 → 반일처리 가능<br>
    ※ 수업시간 기준이므로 쉬는 시간, 점심시간 포함 여부 상관없음<br>
    ※ 학교에 등교하지 않은 경우는 수업시수와 상관없이 하루(1일)로 처리`;
  $("tpRule").innerHTML = RULE_HTML;
  $("tdRule").innerHTML = RULE_HTML;

  const ayOfD = d => { const y = +d.slice(0, 4), m = +d.slice(5, 7); return m >= 3 ? y : y - 1; };
  const md = d => `${+d.slice(5, 7)}.${+d.slice(8)}`;
  const mdw = d => `${md(d)}(${"일월화수목금토"[new Date(d + "T00:00:00").getDay()]})`;
  const fmtDays = n => (Math.round(n * 10) / 10).toString();
  let AY = null, TRIPS = [], STU = [], FILTER = "all", SHOW_ALL = false;
  let SORT = (() => { try{ const v = localStorage.getItem("attend-trip-sort"); return ["new", "old"].includes(v) ? v : "no"; }catch(e){ return "no"; } })();   // 기본: 학번순

  /* ---------- 불러오기 ---------- */
  async function loadTrip(){
    if(!CUR) return;
    if(AY === null) AY = ayOfD(kstToday());
    const c = CUR, ay = AY;
    $("tpAy").textContent = `${ay}학년도`;
    $("tpSub").textContent = `${ay}.3 ~ ${ay + 1}.2 · 학생 1인 ${LIMIT}일 이내 · 수업 3차시 이하는 반일(0.5일)`;
    try{
      const [st, tr] = await Promise.all([sb.from("students").select("*").eq("class_id", c).order("no"),
        sb.from("trip").select("*").eq("class_id", c).eq("ay", ay).order("start_d", {ascending: false})]);
      if(c !== CUR || ay !== AY) return;
      STU = must(st); TRIPS = must(tr);
      render();
    }catch(e){ say("tpMsg", "불러오기 실패: " + e.message + " (변경 020 SQL을 실행했는지 확인)", "err"); }
  }
  window.loadTrip = loadTrip;
  const usedOf = no => TRIPS.filter(t => t.student_no === no).reduce((a, t) => a + Number(t.days), 0);
  const nameOf = no => (STU.find(s => s.no === no) || {}).name || "";

  function render(){
    // 학생별 사용 일수
    const list = STU.filter(s => !s.excluded).map(s => ({...s, used: usedOf(s.no), prev: TRIPS.filter(t => t.student_no === s.no && t.source === "import").reduce((a, t) => a + Number(t.days), 0),
      half: TRIPS.some(t => t.student_no === s.no && t.half)}));
    const show = SHOW_ALL ? list : list.filter(s => s.used > 0);
    $("tpAllBtn").textContent = SHOW_ALL ? "쓴 학생만" : "모든 학생";
    $("tpUse").innerHTML = !show.length ? `<tbody><tr><td class="mute" style="padding:16px">아직 체험학습 기록이 없습니다.</td></tr></tbody>` :
      `<thead><tr><th>번호</th><th style="text-align:left">이름</th><th style="text-align:left">사용 / ${LIMIT}일</th><th>남은</th></tr></thead><tbody>` +
      show.map(s => {
        const left = LIMIT - s.used, pct = Math.min(100, s.used / LIMIT * 100), warn = left <= 2;
        return `<tr><td>${s.no}</td><td class="l"><button class="lnkb" data-tpprev="${s.no}" title="체험학습 기록 보기">${esc(s.name)}</button></td>
          <td class="l"><div style="display:flex;gap:8px;align-items:center"><div style="height:8px;width:110px;border-radius:99px;background:var(--line2);overflow:hidden"><i style="display:block;height:100%;width:${pct}%;background:${warn ? "var(--dk3)" : "var(--ok)"}"></i></div><b>${fmtDays(s.used)}</b></div>
          ${s.prev || s.half ? `<div class="mute" style="font-size:11px">${[s.prev ? (s.used - s.prev > 0 ? `이전 기록 ${fmtDays(s.prev)} + 앱 ${fmtDays(s.used - s.prev)}` : "이전 기록") : "", s.half ? "반일 포함" : ""].filter(Boolean).join(" · ")}</div>` : ""}</td>
          <td>${left < 0 ? `<span class="pill dk3">${fmtDays(-left)}일 초과</span>` : warn ? `<span class="pill dk3">${fmtDays(left)}일 남음</span>` : fmtDays(left)}</td></tr>`;
      }).join("") + "</tbody>";
    // 회차 목록
    const today = kstToday();
    const tracked = t => t.source === "app" || t.report_track;
    const due = t => tracked(t) && !t.report_at;
    document.querySelectorAll("[data-tpf]").forEach(b => { const on = b.dataset.tpf === FILTER; b.classList.toggle("on", on);
      b.textContent = b.dataset.tpf === "all" ? `전체 ${TRIPS.length}` : `보고서 미제출 ${TRIPS.filter(due).length}`; });
    const byEnd = (a, b) => (a.end_d || "9999").localeCompare(b.end_d || "9999");
    const newer = (a, b) => (b.end_d || "0000").localeCompare(a.end_d || "0000");   // 날짜 없는 기록은 맨 뒤
    const rows = TRIPS.filter(t => FILTER === "all" || due(t)).sort(
        SORT === "new" ? (a, b) => newer(a, b) || a.student_no - b.student_no
      : SORT === "old" ? (a, b) => byEnd(a, b) || a.student_no - b.student_no
      : (a, b) => a.student_no - b.student_no || byEnd(a, b));
    document.querySelectorAll("[data-tps]").forEach(b => { const on = b.dataset.tps === SORT; b.classList.toggle("on", on); b.setAttribute("aria-pressed", on); });
    $("tpList").innerHTML = !rows.length ? `<tbody><tr><td class="mute" style="padding:16px">${FILTER === "all" ? "등록된 회차가 없습니다." : "보고서를 낼 회차가 없습니다."}</td></tr></tbody>` :
      `<thead><tr><th style="text-align:left">학생</th><th style="text-align:left">기간</th><th style="text-align:left">형태</th><th>일수</th><th style="text-align:left">보고서</th><th></th></tr></thead><tbody>` +
      rows.map(t => {
        const per = !t.start_d ? `<span class="mute">날짜 없음 (일수만)</span>` : t.start_d === t.end_d ? mdw(t.start_d) : `${mdw(t.start_d)} ~ ${mdw(t.end_d)}`;
        const form = t.source === "import" ? "" : t.half ? `일부 교시 · ${esc((t.slots || []).map(x => /^\d+$/.test(x) ? x + "교시" : x).join("·"))}<br><span class="mute" style="font-size:12px">${esc(t.kind || "")}${Number(t.days) === 0.5 ? " · 반일" : ""}</span>` : "하루 종일";
        const rep = !tracked(t) ? `<span class="pill">이전 기록</span>`
          : t.report_at ? `<span class="pill" style="background:var(--accent-soft2);color:var(--ok)">✓ 제출함${t.source === "import" ? "" : " " + md(new Date(t.report_at).toISOString().slice(0, 10))}</span> <button class="lnkb" data-tpundo="${t.id}">취소</button>`
          : `<button class="btn sm dk3" data-tpdoc="${t.id}">제출처리</button> <span class="mute" style="font-size:12px">${t.end_d >= today ? "진행 중" : "미제출"}</span>`;
        const src = t.source === "import" && tracked(t) ? `<br><span class="mute" style="font-size:11px">이전 기록</span>` : "";
        return `<tr style="${!tracked(t) ? "color:var(--mute)" : ""}"><td class="l"><b>${t.student_no}</b> ${esc(nameOf(t.student_no))}</td><td class="l">${per}${t.memo ? `<br><span class="mute" style="font-size:12px">${esc(t.memo)}</span>` : ""}</td>
          <td class="l">${form}</td><td>${fmtDays(t.days)}</td><td class="l">${rep}${src}</td>
          <td style="white-space:nowrap">${t.source === "app" ? `<button class="lnkb" data-tpedit="${t.id}">수정</button> ` : t.start_d ? `<button class="lnkb" data-tpsync="${t.id}">출석부 반영</button> ` : ""}<button class="lnkb" data-tpdel="${t.id}">삭제</button></td></tr>`;
      }).join("") + "</tbody>";
  }

  $("tpPrev").onclick = () => { AY--; loadTrip(); };
  $("tpNext").onclick = () => { AY++; loadTrip(); };
  $("tpAllBtn").onclick = () => { SHOW_ALL = !SHOW_ALL; render(); };
  document.querySelectorAll("[data-tpf]").forEach(b => b.onclick = () => { FILTER = b.dataset.tpf; render(); });
  document.querySelectorAll("[data-tps]").forEach(b => b.onclick = () => { SORT = b.dataset.tps; try{ localStorage.setItem("attend-trip-sort", SORT); }catch(e){} render(); });

  /* ---------- 반일 판단 ---------- */
  // slots: 빠진 칸, periods: 그날 수업 교시(숫자 배열)
  function halfKind(slots, periods){
    const nums = slots.filter(x => /^\d+$/.test(x)).map(Number);
    const P = periods || [];
    const all = ["조회", ...P.map(String), "종례"];
    const idx = all.map((x, i) => slots.includes(x) ? i : -1).filter(i => i >= 0);
    const missed = nums.length, attended = P.length - missed;
    const days = missed <= 3 && attended >= 1 ? 0.5 : 1;
    const contiguous = idx.every((v, i) => i === 0 || v === idx[i - 1] + 1);
    const fromStart = idx.length > 0 && idx[0] <= 1 && contiguous;              // 조회 또는 1교시부터 이어짐
    const toEnd = idx.length > 0 && idx[idx.length - 1] >= all.length - 2 && contiguous;   // 마지막 교시 또는 종례까지 이어짐
    let t = "결과";
    if(attended <= 0) t = "결석";
    else if(fromStart && !toEnd) t = "지각";
    else if(toEnd && !fromStart) t = "조퇴";
    return {days, kind: "출석인정" + t, missed, attended};
  }

  /* ---------- 등록·수정 ---------- */
  let TD = null;   // {edit: trip|null, days: [{d, periods}]}
  async function openTrip(opts){
    opts = opts || {};
    if(!CUR) return;
    if(!STU.length || STU[0].class_id !== CUR){
      try{ STU = must(await sb.from("students").select("*").eq("class_id", CUR).order("no")); }catch(e){ alert(e.message); return; }
    }
    const t = opts.edit || null;
    TD = {edit: t, days: [], sel: new Set(t && t.half ? t.slots : []), ay: null, trips: []};
    $("tdTitle").textContent = t ? "교외체험학습 수정" : "학교장허가 교외체험학습 등록";
    $("tdStu").innerHTML = STU.filter(s => !s.excluded).map(s => `<option value="${s.no}">${s.no}번 ${esc(s.name)}</option>`).join("");
    $("tdStu").value = String(t ? t.student_no : opts.no || STU.filter(s => !s.excluded)[0]?.no || "");
    $("tdStu").disabled = !!t;
    const d0 = t ? t.start_d : opts.d || kstToday();
    $("tdFrom").value = d0; $("tdTo").value = t ? t.end_d : d0;
    document.querySelectorAll('input[name="tdForm"]').forEach(r => r.checked = r.value === (t && t.half ? "half" : "full"));
    $("tdMemo").value = t ? t.memo || "" : "";
    $("tripDlg").showModal();
    await refreshTD();
  }
  window.openTrip = openTrip;
  const isHalf = () => (document.querySelector('input[name="tdForm"]:checked') || {}).value === "half";
  async function refreshTD(){
    if(isHalf()) $("tdTo").value = $("tdFrom").value;
    $("tdTo").disabled = isHalf();
    $("tdHalf").classList.toggle("hidden", !isHalf());
    const from = $("tdFrom").value, to = $("tdTo").value, no = +$("tdStu").value;
    if(!from || !to || to < from){ $("tdPrev").innerHTML = `<span class="err">기간을 확인해 주세요.</span>`; $("tdOk").disabled = true; return; }
    try{ TD.days = must(await sb.rpc("school_days_list", {p_class: CUR, p_from: from, p_to: to})) || []; }
    catch(e){ $("tdPrev").innerHTML = `<span class="err">${esc(e.message)}</span>`; $("tdOk").disabled = true; return; }
    let days = TD.days.length, extra = "";
    if(isHalf()){
      const day = TD.days[0];
      if(!day){ $("tdSlots").innerHTML = ""; $("tdPrev").innerHTML = `<span class="err">${mdw(from)}은(는) 수업이 없는 날입니다.</span>`; $("tdOk").disabled = true; return; }
      const all = ["조회", ...day.periods.map(String), "종례"];
      $("tdSlots").innerHTML = all.map(x => `<button type="button" class="btn ghost sm ${TD.sel.has(x) ? "dk3 on" : ""}" style="${TD.sel.has(x) ? "background:var(--dk3s);color:var(--dk3);border-color:var(--dk3l)" : ""}" data-tdslot="${x}" aria-pressed="${TD.sel.has(x)}">${/^\d+$/.test(x) ? x + "교시" : x}</button>`).join("");
      $("tdSlots").querySelectorAll("[data-tdslot]").forEach(b => b.onclick = () => { const x = b.dataset.tdslot; TD.sel.has(x) ? TD.sel.delete(x) : TD.sel.add(x); refreshTD(); });
      const sel = all.filter(x => TD.sel.has(x));
      if(!sel.some(x => /^\d+$/.test(x))){ $("tdPrev").innerHTML = `빠지는 <b>수업 교시</b>를 눌러 주세요. (조회·종례는 차시에 넣지 않습니다)`; $("tdOk").disabled = true; return; }
      const k = halfKind(sel, day.periods);
      days = k.days;
      extra = `<br>${mdw(day.d)} · 빠지는 칸 ${sel.map(x => /^\d+$/.test(x) ? x + "교시" : x).join("·")} · 이날 수업 ${day.periods.length}차시 중 ${k.missed}차시<br>마감 <b>${k.kind}</b> · ${k.days === 0.5 ? "<b>반일 0.5일</b>" : k.attended <= 0 ? "수업을 전혀 듣지 않음 → <b>1일</b>" : "수업 4차시 이상 → <b>1일</b>"}`;
    }else if(days){
      extra = `<br>${TD.days.map(x => mdw(x.d)).join(" ")}`;
    }
    const ay = ayOfD(from);
    if(TD.ay !== ay){ try{ TD.trips = must(await sb.from("trip").select("*").eq("class_id", CUR).eq("ay", ay)); TD.ay = ay; }catch(e){ TD.trips = []; } }
    const others = TD.trips.filter(t => t.student_no === no && (!TD.edit || t.id !== TD.edit.id));
    const usedBefore = others.reduce((a, t) => a + Number(t.days), 0);
    const total = usedBefore + days;
    const clash = others.filter(t => t.start_d && t.start_d <= to && t.end_d >= from);
    const appClash = clash.filter(t => t.source === "app"), impClash = clash.filter(t => t.source === "import");
    const ayWarn = ayOfD(to) !== ay ? `<br><span class="err">학년도(3월~2월)를 넘는 기간입니다. 학년도별로 나눠 등록해 주세요.</span>` : "";
    $("tdPrev").innerHTML = (days ? `<b>수업일 ${isHalf() ? 1 : TD.days.length}일</b> · 사용 <b>${fmtDays(days)}일</b> → ${ay}학년도 누적 <b>${fmtDays(total)} / ${LIMIT}일</b> (남은 ${fmtDays(LIMIT - total)}일)` : `<span class="err">이 기간에는 수업일이 없습니다.</span>`) + extra +
      (!isHalf() && days ? `<br><span class="mute" style="font-size:13px">마감 출석인정결석 · 비고 "출석인정결석(${NOTE_REASON}) 보고서 미제출" 로 ${TD.days.length}일 모두 자동 입력</span>` : "") +
      (total > LIMIT ? `<br><span class="err">연간 ${LIMIT}일을 ${fmtDays(total - LIMIT)}일 넘습니다.</span>` : "") +
      (appClash.length ? `<br><span class="err">이미 등록된 회차(${appClash.map(t => `${md(t.start_d)}~${md(t.end_d)}`).join(", ")})와 날짜가 겹칩니다.</span>` : "") +
      (impClash.length ? `<br><span style="color:var(--dk2)">이전 기록(${impClash.map(t => `${md(t.start_d)}~${md(t.end_d)}`).join(", ")})과 날짜가 겹칩니다. 같은 체험학습이면 이전 기록을 지워 주세요.</span>` : "") + ayWarn;
    $("tdOk").disabled = !days || appClash.length > 0 || !!ayWarn;
    $("tdOk").textContent = TD.edit ? "수정" : `등록 · ${isHalf() ? 1 : TD.days.length}일 입력`;
  }
  ["tdFrom", "tdTo", "tdStu"].forEach(id => $(id).onchange = () => { if(id === "tdFrom" && $("tdTo").value < $("tdFrom").value) $("tdTo").value = $("tdFrom").value; refreshTD(); });
  document.querySelectorAll('input[name="tdForm"]').forEach(r => r.onchange = refreshTD);
  $("tdX").onclick = $("tdCancel").onclick = () => $("tripDlg").close();

  // 회차가 출석부에 넣은 칸 지우기
  async function removeTripWrites(t){
    const tag = "trip:" + t.id;
    must(await sb.from("homeroom_marks").delete().eq("class_id", t.class_id).eq("student_no", t.student_no).eq("by_email", tag).gte("d", t.start_d).lte("d", t.end_d));
    // 마감·비고: 이 회차가 넣은 것(보고서 제출로 비고가 바뀐 것 포함)
    const dm = must(await sb.from("day_manual").select("*").eq("class_id", t.class_id).eq("student_no", t.student_no).gte("d", t.start_d).lte("d", t.end_d));
    for(const r of dm) if(r.by_email === tag || (t.source === "app" && /교외체험학습/.test(r.note || ""))) must(await sb.from("day_manual").delete().match({class_id: t.class_id, d: r.d, student_no: t.student_no}));
    must(await sb.from("doc_submit").delete().eq("class_id", t.class_id).eq("student_no", t.student_no).gte("d", t.start_d).lte("d", t.end_d));
  }
  // 회차를 출석부에 넣기
  async function applyTripWrites(t, days){
    const tag = "trip:" + t.id, now = new Date().toISOString(), logs = [];
    for(const day of days){
      const all = ["조회", ...day.periods.map(String), "종례"];
      const slots = t.half ? all.filter(x => t.slots.includes(x)) : all;
      const kind = t.half ? halfKind(slots, day.periods).kind : "출석인정결석";
      const note = `${kind}(${NOTE_REASON}) 보고서 미제출`;
      must(await sb.from("day_manual").upsert({class_id: t.class_id, d: day.d, student_no: t.student_no, kind, note, by_email: tag, at: now}));
      must(await sb.from("homeroom_marks").upsert(slots.map(sl => ({class_id: t.class_id, d: day.d, student_no: t.student_no, slot: sl, state: "absent", by_email: tag, at: now}))));
      logs.push({class_id: t.class_id, d: day.d, student_no: t.student_no, period: null, slot: null, action: "hr_kind", teacher: "담임", before: "", after: kind, by_email: ME_EMAIL, memo: "교외체험학습 " + (t.half ? "일부 교시" : "등록")});
    }
    if(logs.length) must(await sb.from("mark_log").insert(logs));
  }
  $("tdOk").onclick = async () => {
    $("tdOk").disabled = true;
    try{
      const no = +$("tdStu").value, half = isHalf();
      const all = half && TD.days[0] ? ["조회", ...TD.days[0].periods.map(String), "종례"] : [];
      const slots = half ? all.filter(x => TD.sel.has(x)) : null;
      const hk = half ? halfKind(slots, TD.days[0].periods) : null;
      const days = half ? hk.days : TD.days.length;
      const row = {class_id: CUR, student_no: no, ay: ayOfD($("tdFrom").value), start_d: $("tdFrom").value, end_d: $("tdTo").value, half, slots, kind: half ? hk.kind : "출석인정결석", days, source: "app", memo: $("tdMemo").value.trim() || null, by_email: ME_EMAIL};
      let t;
      if(TD.edit){
        await removeTripWrites(TD.edit);
        t = (must(await sb.from("trip").update({...row, report_at: null}).eq("id", TD.edit.id).select()) || [])[0] || {...TD.edit, ...row};
      }else{
        t = (must(await sb.from("trip").insert(row).select()) || [])[0];
      }
      await applyTripWrites(t, half ? TD.days.slice(0, 1) : TD.days);
      $("tripDlg").close();
      say("tpMsg", `${no}번 ${nameOf(no)} 교외체험학습을 ${TD.edit ? "수정" : "등록"}했습니다 (${fmtDays(days)}일).`, "ok");
    }catch(e){ alert("저장 실패: " + e.message); $("tdOk").disabled = false; return; }
    refreshAll();
  };
  function refreshAll(){
    const t = document.querySelector("#tabs button.on");
    if(t && t.dataset.t === "trip") loadTrip(); else if(t && t.dataset.t === "board") loadBoard(); else loadTrip();
  }

  /* ---------- 보고서 제출 (회차 단위) ---------- */
  async function tripReportSubmit(id){
    const t = (must(await sb.from("trip").select("*").eq("id", id)) || [])[0]; if(!t) return;
    const rows = must(await sb.from("day_manual").select("*").eq("class_id", t.class_id).eq("student_no", t.student_no).gte("d", t.start_d).lte("d", t.end_d));
    for(const r of rows) if(/보고서\s*미제출/.test(r.note || "")) await docSubmitDay(t.class_id, r.d, t.student_no, "보고서");
    must(await sb.from("trip").update({report_at: new Date().toISOString()}).eq("id", id));
  }
  async function tripReportUndo(id){
    const t = (must(await sb.from("trip").select("*").eq("id", id)) || [])[0]; if(!t) return;
    const ds = must(await sb.from("doc_submit").select("*").eq("class_id", t.class_id).eq("student_no", t.student_no).gte("d", t.start_d).lte("d", t.end_d));
    for(const r of ds) await docUndoDay(t.class_id, r.d, t.student_no);
    must(await sb.from("trip").update({report_at: null}).eq("id", id));
  }
  window.tripReportSubmit = tripReportSubmit; window.tripReportUndo = tripReportUndo;

  $("tpList").onclick = async e => {
    const b = e.target.closest("[data-tpdoc],[data-tpundo],[data-tpedit],[data-tpdel],[data-tpsync]"); if(!b) return;
    const id = +(b.dataset.tpdoc || b.dataset.tpundo || b.dataset.tpedit || b.dataset.tpdel || b.dataset.tpsync);
    const t = TRIPS.find(x => x.id === id); if(!t) return;
    try{
      if(b.dataset.tpedit){ openTrip({edit: t}); return; }
      if(b.dataset.tpsync){ await syncToBoard([t]); return; }
      if(b.dataset.tpdoc){ b.disabled = true; await tripReportSubmit(id); say("tpMsg", `${t.student_no}번 ${nameOf(t.student_no)} 보고서 제출 완료. 비고의 "보고서 미제출"을 지웠습니다.`, "ok"); }
      if(b.dataset.tpundo){ if(!confirm("보고서 제출 완료를 취소할까요?")) return; await tripReportUndo(id); }
      if(b.dataset.tpdel){
        if(!confirm(t.source === "import" ? "이 이전 기록을 지울까요?\n이 기록으로 출석부에 넣은 내용이 있으면 함께 지워집니다." : `${t.student_no}번 ${nameOf(t.student_no)} ${md(t.start_d)}~${md(t.end_d)} 회차를 지울까요?\n이 회차가 출석부에 넣은 "/"·마감·비고도 함께 지워집니다.`)) return;
        if(t.start_d) await removeTripWrites(t);
        must(await sb.from("trip").delete().eq("id", id));
      }
    }catch(err){ say("tpMsg", "저장 실패: " + err.message, "err"); }
    loadTrip();
  };
  // 이전 사용 일수 직접 입력 (날짜 없는 이전 기록 1건)
  // 학생 이름 → 그 학생의 체험학습 기록 + 이전 사용 일수 입력
  const SD = document.createElement("dialog");
  SD.className = "kd"; SD.id = "tripStuDlg"; SD.style.width = "min(640px, calc(100% - 32px))";
  document.body.appendChild(SD);
  function openStudent(no){
    const mine = TRIPS.filter(t => t.student_no === no).sort((a, b) => (a.start_d || "0").localeCompare(b.start_d || "0"));
    const used = usedOf(no), left = LIMIT - used;
    const plain = mine.find(t => t.source === "import" && !t.start_d);
    const tracked = t => t.source === "app" || t.report_track;
    SD.innerHTML = `<div class="top"><span>${no}번 ${esc(nameOf(no))} · ${AY}학년도 교외체험학습</span><button type="button" data-sdx aria-label="닫기">×</button></div>
      <div style="padding:14px 18px 18px;display:flex;flex-direction:column;gap:12px">
        <div style="font-size:15px">사용 <b>${fmtDays(used)}</b> / ${LIMIT}일 · ${left < 0 ? `<span class="err">${fmtDays(-left)}일 초과</span>` : `남은 <b>${fmtDays(left)}</b>일`}</div>
        <div class="tbox"><table style="font-size:13px">${mine.filter(t => t.start_d).length ? `<thead><tr><th style="text-align:left">기간</th><th style="text-align:left">형태</th><th>일수</th><th style="text-align:left">보고서</th><th style="text-align:left">구분</th></tr></thead><tbody>` +
          mine.filter(t => t.start_d).map(t => `<tr><td class="l">${t.start_d === t.end_d ? mdw(t.start_d) : `${mdw(t.start_d)} ~ ${mdw(t.end_d)}`}${t.memo && t.source === "app" ? `<br><span class="mute">${esc(t.memo)}</span>` : ""}</td>
            <td class="l">${t.source === "import" ? "—" : t.half ? `일부 교시 (${esc((t.slots || []).map(x => /^\d+$/.test(x) ? x + "교시" : x).join("·"))})` : "하루 종일"}</td><td>${fmtDays(t.days)}</td>
            <td class="l">${!tracked(t) ? '<span class="mute">—</span>' : t.report_at ? (t.source === "import" ? "✓ 제출" : `✓ 제출 ${md(new Date(t.report_at).toISOString().slice(0, 10))}`) : '<span style="color:var(--dk3)">미제출</span>'}</td>
            <td class="l">${t.source === "import" ? "이전 기록" : "앱 등록"}</td></tr>`).join("") + "</tbody>"
          : `<tbody><tr><td class="mute" style="padding:12px">날짜가 있는 체험학습 기록이 없습니다.</td></tr></tbody>`}</table></div>
        <div style="background:var(--head);border-radius:10px;padding:10px 12px;font-size:13px">
          <b>이 앱을 쓰기 전 사용 일수</b> <span class="mute">(날짜를 모를 때 숫자만 · 위 목록의 이전 기록과 겹치지 않게)</span>
          <div class="row" style="margin-top:6px;align-items:center"><input type="number" min="0" step="0.5" id="sdPrev" value="${plain ? fmtDays(plain.days) : ""}" placeholder="0" style="width:90px"> 일 <button class="btn sm" data-sdsave>저장</button><span id="sdMsg"></span></div>
        </div>
        <div class="row" style="justify-content:flex-end"><button class="btn ghost" data-sdadd>이 학생 체험학습 등록</button><button class="btn" data-sdx>닫기</button></div>
      </div>`;
    SD.querySelectorAll("[data-sdx]").forEach(b => b.onclick = () => SD.close());
    SD.querySelector("[data-sdadd]").onclick = () => { SD.close(); openTrip({no}); };
    SD.querySelector("[data-sdsave]").onclick = async () => {
      const n = Number(SD.querySelector("#sdPrev").value || 0);
      if(!isFinite(n) || n < 0){ say("sdMsg", "0 이상의 숫자로 입력해 주세요.", "err"); return; }
      try{
        if(plain && n === 0) must(await sb.from("trip").delete().eq("id", plain.id));
        else if(plain) must(await sb.from("trip").update({days: n}).eq("id", plain.id));
        else if(n > 0) must(await sb.from("trip").insert({class_id: CUR, student_no: no, ay: AY, days: n, source: "import", memo: "이전 사용 일수(직접 입력)", by_email: ME_EMAIL}));
      }catch(err){ say("sdMsg", "저장 실패: " + err.message, "err"); return; }
      await loadTrip(); openStudent(no);
    };
    if(!SD.open) SD.showModal();
  }
  $("tpUse").onclick = e => {
    const b = e.target.closest("[data-tpprev]"); if(!b) return;
    openStudent(+b.dataset.tpprev);
  };

  // 엑셀 화면처럼 그린 안내 그림 (학생 이름은 예시)
  function excelGuide(){
    const rows = [
      ["30201", "김하늘", "2026년 6월 11일 목요일", "2026년 6월 11일 목요일", "1", "O"],
      ["30207", "박도윤", "2026년 8월 14일 금요일", "2026년 8월 19일 수요일", "3", "O"],
      ["30212", "이서준", "2026년 9월 28일 월요일", "2026년 10월 2일 금요일", "5", "O"],
      ["30218", "정하은", "2026년 10월 23일 금요일", "2026년 10월 23일 금요일", "1", "X"],
      ["30224", "최지우", "2026년 10월 26일 월요일", "2026년 10월 30일 금요일", "5", "X"]];
    const head = ["학번", "이름", "시작일", "종료일", "사용일수", "보고서제출여부"];
    const cell = "border:1px solid #d4d4d4;padding:3px 8px;white-space:nowrap;color:#111";
    const arrow = `<span style="float:right;margin-left:8px;display:inline-block;width:14px;height:14px;border:1px solid #9a9a9a;background:#fff;border-radius:2px;font-size:9px;line-height:13px;text-align:center;color:#444">▼</span>`;
    return `<div style="display:flex;gap:18px;flex-wrap:wrap;align-items:flex-start;margin:4px 0 12px">
      <div style="flex:0 1 auto;min-width:0;max-width:100%;overflow-x:auto">
        <div class="mute" style="font-size:12px;margin-bottom:4px">엑셀 화면 예시 (이름은 예시입니다)</div>
        <table role="img" aria-label="엑셀 예시: 학번, 이름, 시작일, 종료일, 사용일수, 보고서제출여부 열을 머리글부터 마지막 줄까지 선택" style="border-collapse:collapse;font:13px 'Malgun Gothic','맑은 고딕',sans-serif;background:#fff;outline:3px solid #2b7a3d;outline-offset:-1px">
          <tr style="background:#f3f3f3;color:#555;font-size:11px"><td style="${cell};width:22px;color:#777"></td>${["A","B","C","D","E","F"].map(x => `<td style="${cell};text-align:center;color:#555">${x}</td>`).join("")}</tr>
          <tr><td style="${cell};background:#f3f3f3;color:#777;font-size:11px;text-align:center">1</td>${head.map(h => `<td style="${cell};background:#ffc000;font-weight:700">${h}${arrow}</td>`).join("")}</tr>
          ${rows.map((r, i) => `<tr style="background:${i % 2 ? "#fff" : "#fff2cc"}"><td style="${cell};background:#f3f3f3;color:#777;font-size:11px;text-align:center">${i + 2}</td>${r.map((v, k) => `<td style="${cell};text-align:${k === 1 ? "left" : k === 5 ? "center" : "right"}">${v}</td>`).join("")}</tr>`).join("")}
        </table>
      </div>
      <ol style="flex:1 1 260px;margin:18px 0 0;padding-left:20px;font-size:14px;line-height:1.85">
        <li><b>머리글(1행)부터 마지막 줄까지</b> 표 전체를 마우스로 끌어 선택 <span class="mute">(초록 테두리처럼)</span></li>
        <li><b>Ctrl + C</b> 로 복사</li>
        <li>아래 칸을 누르고 <b>Ctrl + V</b></li>
        <li>열이 맞게 잡혔는지, 미리보기를 확인하고 <b>[가져오기]</b></li>
      </ol>
    </div>
    <ul class="mute" style="font-size:12.5px;margin:-4px 0 10px;padding-left:20px;line-height:1.7">
      <li><b>학번</b>은 5자리(30211 = 3학년 2반 11번). 학번 대신 <b>번호</b> 열이어도 됩니다.</li>
      <li><b>날짜</b>는 "2026년 6월 11일 목요일", "2026-06-11", "6/11" 모두 읽습니다. 하루짜리는 시작일=종료일.</li>
      <li><b>사용일수</b>는 휴일을 뺀 실제 사용 일수(반일은 0.5). 표에 적힌 값을 그대로 씁니다.</li>
      <li><b>보고서제출여부</b>는 O / X. 이 열이 없으면 보고서는 추적하지 않습니다.</li>
      <li>머리글 이름이 조금 달라도 괜찮습니다. 붙여넣은 뒤 "열 확인"에서 고를 수 있습니다.</li>
    </ul>`;
  }

  /* ---------- 이전 기록 붙여넣기 ---------- */
  const IMP = {rows: [], head: [], map: {}, out: []};
  const GUESS = {no: /학번|번호/, name: /이름|성명/, from: /시작/, to: /종료|끝/, range: /기간/, days: /일수|사용/, report: /보고서|제출/};
  const FIELD = {no: "학번(또는 번호)", name: "이름", from: "시작일", to: "종료일", days: "사용일수", report: "보고서제출여부(O/X)", range: "기간(시작~종료가 한 칸일 때)"};
  const yesNo = v => { v = String(v || "").replace(/\s/g, ""); if(!v) return null;
    if(/^(O|o|○|◯|●|Y|y|예|네|제출|완료|제출함|제출완료|ㅇ|0)$/.test(v)) return true;
    if(/^(X|x|×|✕|N|n|아니오|미제출|ㄴ|-)$/.test(v)) return false; return null; };
  $("tpImpBtn").onclick = () => {
    const box = $("tpImp");
    if(!box.classList.contains("hidden")){ box.classList.add("hidden"); return; }
    box.classList.remove("hidden");
    box.innerHTML = `<h2 style="margin-top:0">이전 기록 붙여넣기</h2>
      <p class="mute" style="font-size:14px;margin:0 0 8px">이 앱을 쓰기 전의 체험학습 기록을 누적 일수에 더합니다. 출석부·나이스·보고서 목록에는 넣지 않습니다. 엑셀에서 표를 <b>머리글까지</b> 복사해 아래에 붙여넣으세요(Ctrl+V).</p>
      ${excelGuide()}
      <textarea id="impText" style="width:100%;min-height:120px;font:13px/1.5 ui-monospace,monospace;padding:10px;border:1px solid var(--line);border-radius:10px;background:var(--head);color:var(--ink);box-sizing:border-box" placeholder="엑셀에서 복사한 표를 여기에 붙여넣기 (Ctrl+V)"></textarea>
      <div id="impMap" style="margin-top:10px"></div><div id="impPrev" style="margin-top:10px"></div>`;
    $("impText").oninput = () => parsePaste($("impText").value);
  };
  function parsePaste(txt){
    const lines = txt.replace(/\r/g, "").split("\n").filter(l => l.trim());
    if(lines.length < 2){ $("impMap").innerHTML = ""; $("impPrev").innerHTML = ""; return; }
    IMP.head = lines[0].split("\t").map(x => x.trim());
    IMP.rows = lines.slice(1).map(l => l.split("\t").map(x => x.trim()));
    IMP.map = {};
    for(const [k, re] of Object.entries(GUESS)) IMP.map[k] = IMP.head.findIndex(h => re.test(h));
    if(IMP.map.range >= 0 && (IMP.map.range === IMP.map.from || IMP.map.range === IMP.map.to)) IMP.map.range = -1;
    drawMap(); buildPreview();
  }
  function drawMap(){
    $("impMap").innerHTML = `<b style="font-size:14px">열 확인</b> <span class="mute" style="font-size:13px">— 머리글로 짐작했습니다. 틀렸으면 바꿔 주세요.</span><div class="row" style="flex-wrap:wrap;gap:12px;margin-top:6px;font-size:13px">` +
      Object.keys(FIELD).filter(k => k !== "range" || IMP.map.from < 0 || IMP.map.range >= 0).map(k => `<label>${FIELD[k]} → <select data-impmap="${k}"><option value="-1">(없음)</option>${IMP.head.map((h, i) => `<option value="${i}" ${IMP.map[k] === i ? "selected" : ""}>${esc(h || `${i + 1}번째 열`)}</option>`).join("")}</select></label>`).join("") + `</div>`;
    $("impMap").querySelectorAll("[data-impmap]").forEach(s => s.onchange = () => { IMP.map[s.dataset.impmap] = +s.value; buildPreview(); });
  }
  function parseDate(v, ayHint){
    v = String(v || "").trim(); if(!v) return null;
    let m = v.match(/(\d{4})\s*[.\-\/년]\s*(\d{1,2})\s*[.\-\/월]\s*(\d{1,2})/);
    if(m) return `${m[1]}-${String(m[2]).padStart(2, "0")}-${String(m[3]).padStart(2, "0")}`;
    m = v.match(/^(\d{1,2})\s*[.\-\/월]\s*(\d{1,2})/);
    if(m){ const mo = +m[1], y = mo >= 3 ? ayHint : ayHint + 1; return `${y}-${String(mo).padStart(2, "0")}-${String(m[2]).padStart(2, "0")}`; }
    if(/^\d{5}$/.test(v)){ const d = new Date(Date.UTC(1899, 11, 30) + (+v) * 86400000); return d.toISOString().slice(0, 10); }   // 엑셀 날짜 숫자
    return null;
  }
  async function buildPreview(){
    const M = IMP.map, cell = (r, k) => M[k] >= 0 ? (r[M[k]] || "") : "";
    const label = curClass().label.match(/(\d+)\D+(\d+)/) || [];
    const g = +label[1], cl = +label[2];
    let hol = [];
    try{ hol = must(await sb.from("holiday").select("d").gte("d", `${AY}-03-01`).lt("d", `${AY + 1}-03-01`)).map(x => x.d); }catch(e){}
    const weekdays = (a, b) => { let n = 0; for(let t = Date.parse(a + "T00:00:00Z"); t <= Date.parse(b + "T00:00:00Z"); t += 864e5){ const d = new Date(t), w = d.getUTCDay(); if(w > 0 && w < 6 && !hol.includes(d.toISOString().slice(0, 10))) n++; } return n; };
    const seen = [];
    IMP.out = IMP.rows.map(r => {
      const o = {raw: r, ok: true, msg: "", tone: "ok", choice: "skip"};
      // 학생
      const rawNo = cell(r, "no").replace(/\s/g, ""), nm = cell(r, "name").replace(/\s/g, "");
      if(/^\d{5}$/.test(rawNo)){
        if(+rawNo[0] !== g || +rawNo.slice(1, 3) !== cl){ o.ok = false; o.msg = "다른 반 학번"; o.other = true; }
        o.no = +rawNo.slice(3);
      }else if(/^\d{1,2}$/.test(rawNo)) o.no = +rawNo;
      else if(nm){ const s = STU.find(x => x.name.replace(/\s/g, "") === nm); if(s) o.no = s.no; }
      const s = o.other ? null : STU.find(x => x.no === o.no);
      o.name = s ? s.name : cell(r, "name");
      if(o.other) o.no = rawNo;
      if(o.ok && !s){ o.ok = false; o.msg = "명단에 없는 번호"; }
      else if(o.ok && nm && s.name.replace(/\s/g, "") !== nm){ o.ok = false; o.msg = `명단의 ${o.no}번은 ${s.name}`; }
      // 날짜
      if(M.range >= 0){ const [a, b] = cell(r, "range").split(/[~∼\-–]/); o.from = parseDate(a, AY); o.to = parseDate(b || a, AY); }
      else { o.from = parseDate(cell(r, "from"), AY); o.to = parseDate(cell(r, "to") || cell(r, "from"), AY); }
      o.report = M.report >= 0 ? yesNo(cell(r, "report")) : null;
      o.zero = M.report >= 0 && cell(r, "report").trim() === "0";
      const dv = cell(r, "days").match(/\d+(\.\d+)?/);
      o.days = dv ? +dv[0] : null;
      if(o.ok && !o.from && o.days === null){ o.ok = false; o.msg = "날짜·일수를 읽지 못함"; }
      if(o.ok && o.from && o.to < o.from){ o.ok = false; o.msg = "종료일이 시작일보다 빠름"; }
      if(o.ok && o.from && ayOfD(o.from) !== AY){ o.ok = false; o.msg = `${ayOfD(o.from)}학년도 기록`; }
      if(o.ok && o.from){
        const wd = weekdays(o.from, o.to);
        if(o.days === null){ o.days = wd; o.msg = "일수 없음 → 평일로 계산(공휴일 확인)"; o.tone = "warn"; }
        else if(o.days !== wd && o.days % 1 === 0){ o.msg = `평일 ${wd}일인데 ${o.days}일 · 표 값 사용`; o.tone = "warn"; }
      }
      // 겹침 (기존 회차·이전 기록·이번 표 안에서)
      if(o.ok && o.from){
        const prev = TRIPS.filter(t => t.student_no === o.no && t.start_d).concat(seen.filter(x => x.no === o.no).map(x => ({start_d: x.from, end_d: x.to, source: "paste"})));
        const same = prev.find(t => t.start_d === o.from && t.end_d === o.to);
        const part = prev.filter(t => t.start_d <= o.to && t.end_d >= o.from);
        if(same && same.source !== "paste" && o.report !== null && (!(same.source === "app" || same.report_track) || !!same.report_at !== o.report)){
          o.update = same; o.tone = "update";
          const was = !(same.source === "app" || same.report_track) ? "추적 안 함" : same.report_at ? "제출" : "미제출";
          o.msg = `이미 있음 · 보고서 상태 갱신 (${was} → ${o.report ? "제출" : "미제출"})`;
        }
        else if(same){ o.ok = false; o.msg = same.source === "paste" ? "표 안에 같은 줄이 또 있음" : "이미 있음"; o.tone = "same"; }
        else if(part.length){
          const ov = part.reduce((a, t) => a + weekdays(t.start_d > o.from ? t.start_d : o.from, t.end_d < o.to ? t.end_d : o.to), 0);
          o.overlap = Math.min(ov, o.days); o.tone = "overlap";
          o.msg = `겹침: ${part.map(t => `${md(t.start_d)}~${md(t.end_d)}`).join(", ")}과 ${o.overlap}일`;
        }
      }
      if(o.ok && o.zero) o.msg = (o.msg ? o.msg + " · " : "") + "보고서 칸의 숫자 0 → O로 봄";
      if(o.ok && o.zero && o.tone === "ok") o.tone = "warn";
      if(o.ok && o.from) seen.push(o);
      return o;
    });
    drawPreview();
  }
  function drawPreview(){
    const L = IMP.out, take = L.filter(o => o.ok && (o.tone !== "overlap" || o.choice === "take"));
    $("impPrev").innerHTML = `<b style="font-size:14px">미리보기</b> <span class="mute" style="font-size:13px">· ${L.length}줄 중 반영할 ${take.length}줄 · 빨간 줄과 "이미 있음"(보고서 상태가 같은 것)은 건너뜁니다</span>
      <div class="tbox" style="margin-top:6px;max-height:360px;overflow:auto"><table><thead><tr><th>번호</th><th style="text-align:left">이름</th><th style="text-align:left">기간</th><th>일수</th><th>보고서</th><th style="text-align:left">확인</th></tr></thead><tbody>` +
      L.map((o, i) => `<tr style="${!o.ok && o.tone !== "same" ? "background:var(--red-soft)" : o.tone === "same" ? "color:var(--mute)" : ""}"><td>${o.no ?? "—"}</td><td class="l">${esc(o.name || o.raw.join(" "))}</td>
        <td class="l">${o.from ? (o.from === o.to ? mdw(o.from) : `${mdw(o.from)} ~ ${mdw(o.to)}`) : '<span class="mute">날짜 없음</span>'}</td><td>${o.days ?? "—"}</td><td>${o.report === true ? "제출" : o.report === false ? '<span style="color:var(--dk3)">미제출</span>' : '<span class="mute">—</span>'}</td>
        <td class="l" style="font-size:13px">${!o.ok ? `<span class="${o.tone === "same" ? "mute" : "err"}">${esc(o.msg)}</span>` : o.tone === "overlap"
          ? `<span style="color:var(--dk2)">${esc(o.msg)}</span> <select data-impch="${i}"><option value="skip" ${o.choice === "skip" ? "selected" : ""}>건너뛰기</option><option value="take" ${o.choice === "take" ? "selected" : ""}>가져오기(겹친 ${o.overlap}일 빼고)</option></select>`
          : o.msg ? `<span style="color:var(--dk2)">${esc(o.msg)}</span>` : '<span class="pill" style="background:var(--accent-soft2);color:var(--ok)">OK</span>'}</td></tr>`).join("") +
      `</tbody></table></div><div class="row" style="margin-top:10px"><button class="btn" id="impGo" ${take.length ? "" : "disabled"}>${[take.filter(o => !o.update).length ? `${take.filter(o => !o.update).length}줄 가져오기` : "", take.filter(o => o.update).length ? `${take.filter(o => o.update).length}건 보고서 상태 갱신` : ""].filter(Boolean).join(" · ") || "가져올 줄 없음"}</button><button class="btn ghost" id="impCancel">닫기</button><span id="impMsg"></span></div>
      <label style="display:flex;gap:8px;align-items:flex-start;margin-top:10px;font-size:14px"><input type="checkbox" id="impAtt" style="margin-top:4px"> <span><b>앱 출석부에도 넣기</b> <span class="mute" style="font-size:13px">— 가져온 뒤 기간의 수업일을 확인해서, 빈 날은 채우고 이미 같은 날은 그대로 두며 <b>다른 날만</b> 보여 주고 고르게 합니다.</span></span></label>`;
    $("impPrev").querySelectorAll("[data-impch]").forEach(s => s.onchange = () => { L[+s.dataset.impch].choice = s.value; drawPreview(); });
    $("impCancel").onclick = () => $("tpImp").classList.add("hidden");
    $("impGo").onclick = async () => {
      $("impGo").disabled = true;
      try{
        // 이미 있는 회차: 보고서 상태만 갱신
        let upd = 0;
        for(const o of take.filter(o => o.update)){
          const t = o.update;
          if(o.report){ must(await sb.from("trip").update({report_track: true}).eq("id", t.id)); await tripReportSubmit(t.id); }
          else { if(t.report_at) await tripReportUndo(t.id); must(await sb.from("trip").update({report_track: true, report_at: null}).eq("id", t.id)); }
          upd++;
        }
        const rows = take.filter(o => !o.update).map(o => ({class_id: CUR, student_no: o.no, ay: AY, start_d: o.from, end_d: o.to, half: false, days: Math.max(0, o.days - (o.choice === "take" ? o.overlap || 0 : 0)), source: "import",
          memo: o.choice === "take" && o.overlap ? `이전 기록(겹친 ${o.overlap}일 뺌)` : "이전 기록", by_email: ME_EMAIL,
          report_track: o.report !== null, report_at: o.report === true ? new Date().toISOString() : null}));
        const ins = rows.length ? (must(await sb.from("trip").insert(rows).select()) || []) : [];
        // 보고서 O: 그 기간 비고의 "보고서 미제출"도 정리
        let fixed = 0;
        for(const t of ins) if(t.report_track && t.report_at && t.start_d){ await tripReportSubmit(t.id); fixed++; }
        const att = $("impAtt") && $("impAtt").checked;
        $("tpImp").classList.add("hidden");
        const due = rows.filter(r => r.report_track && !r.report_at).length;
        const msg = `이전 기록 ${rows.length}줄을 가져왔습니다.` + (rows.some(r => r.report_track) ? ` (보고서 제출 ${fixed}건 · 미제출 ${due}건)` : "") + (upd ? ` · 이미 있던 ${upd}건은 보고서 상태를 갱신했습니다.` : "");
        say("tpMsg", msg, "ok");
        await loadTrip();
        if(att){
          const ids = new Set(ins.map(t => t.id).concat(take.filter(o => o.update).map(o => o.update.id)));
          await syncToBoard(TRIPS.filter(t => ids.has(t.id)), msg);
        }
      }catch(e){ say("impMsg", "가져오기 실패: " + e.message, "err"); $("impGo").disabled = false; return; }
    };
  }

  /* ---------- 이전 기록을 출석부에 반영 (같으면 넘어가고, 빈 날은 채우고, 다른 날만 묻기) ---------- */
  const AD = document.createElement("dialog");
  AD.className = "kd"; AD.id = "tripAttDlg"; AD.style.width = "min(760px, calc(100% - 32px))";
  document.body.appendChild(AD);
  const nsp = v => String(v || "").replace(/\s/g, "");
  const targetNote = t => `출석인정결석(${NOTE_REASON})` + (t.report_track && !t.report_at ? " 보고서 미제출" : "");
  async function analyzeTrips(trips){
    const out = [];
    for(const t of trips){
      if(!t.start_d) continue;
      const days = must(await sb.rpc("school_days_list", {p_class: t.class_id, p_from: t.start_d, p_to: t.end_d})) || [];
      if(!days.length) continue;
      const q = tb => sb.from(tb).select("*").eq("class_id", t.class_id).eq("student_no", t.student_no).gte("d", t.start_d).lte("d", t.end_d);
      const [dm, nd, hm, nm, tm] = await Promise.all([q("day_manual"), q("neis_day"), q("homeroom_marks"), q("neis_marks"), q("teacher_marks")]);
      const DM = must(dm), ND = must(nd), HM = hm.error ? [] : hm.data, NM = must(nm), TM = must(tm);
      const tn = targetNote(t);
      for(const day of days){
        const slots = ["조회", ...day.periods.map(String), "종례"];
        const man = DM.find(x => x.d === day.d), nd_ = ND.find(x => x.d === day.d);
        const kind = (man ? man.kind : nd_ && nd_.kind) || "", note = (man ? man.note : nd_ && nd_.note) || "";
        const absent = slots.filter(sl => {
          const te = /^\d+$/.test(sl) ? TM.find(x => x.d === day.d && String(x.period) === sl) : null; if(te) return te.kind === "absent";
          const h = HM.find(x => x.d === day.d && x.slot === sl); if(h) return h.state === "absent";
          return NM.some(x => x.d === day.d && x.slot === sl);
        });
        const allSlash = absent.length === slots.length;
        // 같은 체험학습 내용인데 빠진 것("/"·비고·보고서 미제출 문구)만 있으면 자동 보완, 내용이 다르면 묻기
        const kindOk = !kind || kind === "출석인정결석";
        const noteOk = !note || nsp(note).replace(/보고서미제출/g, "") === nsp(tn).replace(/보고서미제출/g, "");
        let st;
        if(!kind && !note && !absent.length) st = "fill";
        else if(kind === "출석인정결석" && allSlash && nsp(note) === nsp(tn)) st = "same";
        else if(kindOk && noteOk) st = "note";
        else st = "diff";
        out.push({t, d: day.d, slots, kind, note, absentN: absent.length, st, tn, choice: "keep"});
      }
    }
    return out;
  }
  async function applySync(list){
    const now = new Date().toISOString(), logs = [];
    for(const x of list){
      const tag = "trip:" + x.t.id;
      if(x.st === "fill" || x.st === "note" || (x.st === "diff" && x.choice === "replace")){
        must(await sb.from("day_manual").upsert({class_id: x.t.class_id, d: x.d, student_no: x.t.student_no, kind: "출석인정결석", note: x.tn, by_email: tag, at: now}));
        must(await sb.from("homeroom_marks").upsert(x.slots.map(sl => ({class_id: x.t.class_id, d: x.d, student_no: x.t.student_no, slot: sl, state: "absent", by_email: tag, at: now}))));
        logs.push({class_id: x.t.class_id, d: x.d, student_no: x.t.student_no, period: null, slot: null, action: "hr_kind", teacher: "담임", before: x.kind, after: "출석인정결석", by_email: ME_EMAIL, memo: "교외체험학습 이전 기록 반영"});
      }
    }
    if(logs.length) must(await sb.from("mark_log").insert(logs));
    return logs.length;
  }
  // trips: 반영할 이전 기록들 → 분석해서 묻고 반영
  async function syncToBoard(trips, doneMsg){
    let L;
    try{ L = await analyzeTrips(trips); }catch(e){ say("tpMsg", "출석부 확인 실패: " + e.message, "err"); return; }
    const cnt = k => L.filter(x => x.st === k).length;
    const draw = () => {
      const diff = L.filter(x => x.st === "diff");
      AD.innerHTML = `<div class="top"><span>이전 기록을 출석부에 반영</span><button type="button" data-adx aria-label="닫기">×</button></div>
        <div style="padding:14px 18px 18px;display:flex;flex-direction:column;gap:12px">
          ${doneMsg ? `<div class="mute" style="font-size:13px">${esc(doneMsg)}</div>` : ""}
          <div style="font-size:14px;line-height:1.8">수업일 <b>${L.length}일</b> 확인 · 빈 날 채움 <b>${cnt("fill")}일</b> · 빠진 "/"·비고 보완 <b>${cnt("note")}일</b> · 이미 같음 <b>${cnt("same")}일</b> (그대로) · 다름 <b style="color:var(--dk3)">${diff.length}일</b>${diff.length ? " (아래에서 선택)" : ""}</div>
          <div class="mute" style="font-size:12.5px">채우는 내용: 마감 출석인정결석 · 조회~종례 "/" · 비고 "출석인정결석(${NOTE_REASON})" (보고서 미제출이면 뒤에 "보고서 미제출")</div>
          ${diff.length ? `<div class="row" style="gap:6px"><button class="btn ghost sm" data-adall="keep">모두 기존 유지</button><button class="btn ghost sm" data-adall="replace">모두 체험학습으로 바꾸기</button></div>
          <div class="tbox" style="max-height:46vh;overflow:auto"><table style="font-size:13px"><thead><tr><th>학생</th><th>날짜</th><th style="text-align:left">지금 출석부</th><th style="text-align:left">선택</th></tr></thead><tbody>` +
            diff.map(x => { const i = L.indexOf(x); return `<tr><td>${x.t.student_no} ${esc(nameOf(x.t.student_no))}</td><td>${mdw(x.d)}</td>
              <td class="l">${esc(x.kind || "마감 없음")} · "/" ${x.absentN}/${x.slots.length}칸<br><span class="mute">${esc(x.note || "비고 없음")}</span></td>
              <td class="l" style="white-space:nowrap"><label style="display:block"><input type="radio" name="ad${i}" value="keep" ${x.choice === "keep" ? "checked" : ""}> 기존 유지</label>
              <label style="display:block"><input type="radio" name="ad${i}" value="replace" ${x.choice === "replace" ? "checked" : ""}> 체험학습으로 바꾸기</label></td></tr>`; }).join("") + `</tbody></table></div>` : ""}
          <div class="row" style="justify-content:flex-end"><button class="btn ghost" data-adx>출석부는 그대로 두기</button><button class="btn" data-adgo ${cnt("fill") + cnt("note") + diff.filter(x => x.choice === "replace").length ? "" : "disabled"}>출석부에 반영 (${cnt("fill") + cnt("note") + diff.filter(x => x.choice === "replace").length}일)</button></div>
        </div>`;
      AD.querySelectorAll("[data-adx]").forEach(b => b.onclick = () => AD.close());
      AD.querySelectorAll('input[type=radio]').forEach(r => r.onchange = () => { L[+r.name.slice(2)].choice = r.value; draw(); });
      AD.querySelectorAll("[data-adall]").forEach(b => b.onclick = () => { L.filter(x => x.st === "diff").forEach(x => x.choice = b.dataset.adall); draw(); });
      AD.querySelector("[data-adgo]").onclick = async () => {
        AD.querySelector("[data-adgo]").disabled = true;
        try{ const n = await applySync(L); AD.close(); say("tpMsg", `출석부에 ${n}일을 반영했습니다.`, "ok"); }
        catch(e){ alert("반영 실패: " + e.message); }
        loadTrip();
      };
    };
    if(!L.length){ say("tpMsg", (doneMsg ? doneMsg + " " : "") + "반영할 수업일이 없습니다.", "ok"); return; }
    draw();
    if(!AD.open) AD.showModal();
  }
  window.syncTripsToBoard = syncToBoard;

  /* ---------- 엑셀로 내려받기 (이전 기록 붙여넣기와 같은 형식) ---------- */
  let XS = null;
  function styledXlsx(){
    if(!XS) XS = new Promise((res, rej) => { const el = document.createElement("script");
      el.src = "https://cdn.jsdelivr.net/npm/xlsx-js-style@1.2.0/dist/xlsx.bundle.js";
      el.onload = () => res(window.XLSX); el.onerror = () => { XS = null; rej(new Error("엑셀 도구를 불러오지 못했습니다.")); }; document.head.appendChild(el); });
    return XS;
  }
  const longDate = d => { const x = new Date(d + "T00:00:00"); return `${x.getFullYear()}년 ${x.getMonth() + 1}월 ${x.getDate()}일 ${"일월화수목금토"[x.getDay()]}요일`; };
  $("tpExpBtn").onclick = async () => {
    if(!TRIPS.length){ alert(`${AY}학년도 체험학습 기록이 없습니다.`); return; }
    let X; try{ X = await styledXlsx(); }catch(e){ alert(e.message); return; }
    const m = curClass().label.match(/(\d+)\D+(\d+)/) || [];
    const hak = no => `${+m[1]}${String(+m[2]).padStart(2, "0")}${String(no).padStart(2, "0")}`;
    const list = TRIPS.slice().sort((a, b) => (a.start_d || "9999").localeCompare(b.start_d || "9999") || a.student_no - b.student_no);
    const head = ["학번", "이름", "시작일", "종료일", "사용일수", "보고서제출여부"];
    const aoa = [head].concat(list.map(t => [Number(hak(t.student_no)), nameOf(t.student_no), t.start_d ? longDate(t.start_d) : "", t.end_d ? longDate(t.end_d) : "",
      Number(t.days), (t.source === "app" || t.report_track) ? (t.report_at ? "O" : "X") : ""]));
    const ws = X.utils.aoa_to_sheet(aoa);
    const border = {top: {style: "thin", color: {rgb: "D4D4D4"}}, bottom: {style: "thin", color: {rgb: "D4D4D4"}}, left: {style: "thin", color: {rgb: "D4D4D4"}}, right: {style: "thin", color: {rgb: "D4D4D4"}}};
    for(let r = 0; r < aoa.length; r++) for(let c = 0; c < head.length; c++){
      const ref = X.utils.encode_cell({r, c}); if(!ws[ref]) ws[ref] = {t: "s", v: ""};
      ws[ref].s = {font: {name: "맑은 고딕", sz: 11, bold: r === 0}, border,
        fill: r === 0 ? {fgColor: {rgb: "FFC000"}} : r % 2 ? {fgColor: {rgb: "FFF2CC"}} : undefined,
        alignment: {horizontal: r === 0 ? "center" : c === 1 ? "left" : c === 5 ? "center" : "right", vertical: "center"}};
    }
    ws["!cols"] = [{wch: 8}, {wch: 9}, {wch: 24}, {wch: 24}, {wch: 9}, {wch: 14}];
    ws["!autofilter"] = {ref: X.utils.encode_range({s: {r: 0, c: 0}, e: {r: aoa.length - 1, c: head.length - 1}})};
    const wb = X.utils.book_new(); X.utils.book_append_sheet(wb, ws, "체험학습");
    X.writeFile(wb, `${AY}학년도_${curClass().label}반_교외체험학습.xlsx`);
    say("tpMsg", `${list.length}건을 엑셀로 내려받았습니다.`, "ok");
  };

  $("tpAddBtn").onclick = () => openTrip();
  $("tpSyncAll").onclick = () => {
    const list = TRIPS.filter(t => t.source === "import" && t.start_d);
    if(!list.length){ alert("날짜가 있는 이전 기록이 없습니다."); return; }
    syncToBoard(list);
  };
  $("bTrip").onclick = () => openTrip({d: (typeof BOARD !== "undefined" && BOARD && BOARD.d) || kstToday()});
})();
