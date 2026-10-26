/* 출결 앱 → 나이스 반영 (나이스 화면 쪽 실행 코드)
   · 나이스 일일출결관리(담임용) 화면의 데이터(dsListDdAtte)를 읽어 앱 반영 창에 보냄
   · 앱 반영 창이 보낸 "채우기 계획"을 받아 화면에 채움 — [저장]·[출결마감]은 절대 누르지 않음
   · 앱 창(https://21clalala.github.io)에서 온 메시지만 받음 */
(function(){
  var APP_ORIGIN = "https://21clalala.github.io";
  var APP_URL = APP_ORIGIN + "/attendance-class/neis/reflect.html";
  var SLOT_COLS = ["jo"].concat(Array.from({length: 12}, function(_, i){ return "gyo" + (i + 1); })).concat(["jong"]);

  if(window.__attendAgent){ window.__attendAgent.open(); return; }

  function findDaily(){
    var apps = [];
    try{ apps = cpr.core.Platform.INSTANCE.getAllRunningAppInstances(); }catch(e){ return null; }
    for(var i = apps.length - 1; i >= 0; i--){
      var ai = apps[i], id = "";
      try{ id = ai.app.id; }catch(e){}
      if(!/his_srgaa02_m02/.test(id)) continue;
      var ds = null, dm = null, grid = null;
      try{ ds = ai.lookup("dsListDdAtte"); dm = ai.lookup("dmSearch"); grid = ai.lookup("grdMain"); }catch(e){}
      if(!ds){
        try{ ai.getAllDataControls().forEach(function(d){ if(d.id === "dsListDdAtte") ds = d; if(d.id === "dmSearch") dm = d; }); }catch(e){}
      }
      if(!grid){ try{ ai.getContainer().getAllRecursiveChildren().forEach(function(c){ if(c.type === "grid" && c.id === "grdMain") grid = c; }); }catch(e){} }
      if(ds && dm) return {ai: ai, ds: ds, dm: dm, grid: grid};
    }
    return null;
  }

  function str(v){ return v === null || v === undefined ? "" : String(v); }
  function readState(){
    var D = findDaily();
    if(!D) return {ok: false, error: "no_screen"};
    var ds = D.ds, dm = D.dm, rows = [];
    var n = ds.getRowCount();
    for(var r = 0; r < n; r++){
      var o = {row: r, no: +str(ds.getValue(r, "clsNo")), name: str(ds.getValue(r, "stuFlnm")).trim(),
               mg: str(ds.getValue(r, "chulgyulGb")).trim(), rmk: str(ds.getValue(r, "atteRmkCn")),
               closed: str(ds.getValue(r, "ddlnYn")) === "Y", slots: {}, has: {}};
      SLOT_COLS.forEach(function(c){ o.slots[c] = str(ds.getValue(r, c)).trim(); });
      for(var p = 1; p <= 12; p++) o.has["gyo" + p] = str(ds.getValue(r, "g" + p)) === "Y";
      rows.push(o);
    }
    var dayClosed = false;
    try{ dayClosed = str(D.ai.lookup("dmSelectDayAtteFinYn").getValue("atteDdlnYn")) === "Y"; }catch(e){}
    return {ok: true, ymd: str(dm.getValue("atteYmd")), grd: str(dm.getValue("grd")), cls: str(dm.getValue("clsCd")),
            ayr: str(dm.getValue("ayr")), dayClosed: dayClosed || rows.some(function(x){ return x.closed; }), rows: rows};
  }

  // 계획 실행: [{row, no, name, set:{col:value}}]
  function applyPlan(msg){
    var D = findDaily();
    if(!D) return {ok: false, error: "no_screen"};
    var st = readState();
    if(st.ymd !== msg.ymd || st.grd !== msg.grd || st.cls !== msg.cls) return {ok: false, error: "screen_changed", state: st};
    if(st.dayClosed) return {ok: false, error: "closed", state: st};
    var done = [], allowed = {chulgyulGb: 1, atteRmkCn: 1};
    SLOT_COLS.forEach(function(c){ allowed[c] = 1; });
    for(var k = 0; k < msg.plan.length; k++){                 // 쓰기 전에 전부 검사
      var bad = Object.keys(msg.plan[k].set || {}).filter(function(col){ return !allowed[col]; });
      if(bad.length) return {ok: false, error: "write_failed", detail: "허용되지 않은 칸: " + bad.join(","), done: [], state: st};
    }
    for(var i = 0; i < msg.plan.length; i++){
      var it = msg.plan[i], cur = st.rows[it.row];
      if(!cur || cur.no !== it.no || cur.name !== it.name) return {ok: false, error: "row_mismatch", at: it, done: done, state: readState()};
      try{
        Object.keys(it.set).forEach(function(col){
          if(!allowed[col]) throw new Error("허용되지 않은 칸: " + col);
          D.ds.setValue(it.row, col, it.set[col]);
        });
        done.push(it.no);
      }catch(e){ return {ok: false, error: "write_failed", detail: e.message, at: it, done: done, state: readState()}; }
    }
    try{ if(D.grid){ D.grid.redraw && D.grid.redraw(); if(msg.plan.length) D.grid.selectRows(msg.plan.map(function(x){ return x.row; })); } }catch(e){}
    showBadge("앱 내용 " + done.length + "명을 채웠습니다. 확인 후 [저장]을 직접 눌러 주세요.");
    return {ok: true, done: done, state: readState()};
  }

  // 나이스 화면 오른쪽 아래 작은 안내
  var badge = null;
  function showBadge(text){
    if(!badge){
      badge = document.createElement("div");
      badge.style.cssText = "position:fixed;z-index:2147483646;right:16px;bottom:16px;max-width:360px;background:#0f766e;color:#fff;border-radius:12px;padding:12px 14px;font:600 13px/1.5 sans-serif;box-shadow:0 8px 30px rgba(0,0,0,.25);cursor:pointer";
      badge.title = "눌러서 닫기";
      badge.onclick = function(){ badge.remove(); badge = null; };
      document.body.appendChild(badge);
    }
    badge.textContent = "출결 앱 · " + text;
  }

  var win = null;
  function open(){
    if(!findDaily()){ alert("나이스 [학급담임 → 출결관리 → 일일출결관리(담임용)] 화면에서 날짜를 고르고 [조회]한 뒤 눌러 주세요."); return; }
    var w = 560, h = Math.min(1040, screen.availHeight - 40);
    win = window.open(APP_URL, "attend_reflect", "width=" + w + ",height=" + h + ",left=" + Math.max(0, screen.availWidth - w - 10) + ",top=10");
    if(!win){ alert("팝업이 차단되었습니다. 주소창 오른쪽의 팝업 차단 아이콘에서 이 사이트의 팝업을 허용한 뒤 다시 눌러 주세요."); return; }
    try{ win.focus(); }catch(e){}
    showBadge("반영 창과 연결했습니다.");
  }

  window.addEventListener("message", function(e){
    if(e.origin !== APP_ORIGIN || !e.data || e.data.app !== "attend") return;
    var m = e.data, reply = function(o){ o.app = "attend"; o.id = m.id; e.source.postMessage(o, APP_ORIGIN); };
    if(m.type === "read") reply({type: "state", state: readState()});
    else if(m.type === "fill") reply({type: "filled", result: applyPlan(m)});
  });

  window.__attendAgent = {open: open};
  open();
})();
