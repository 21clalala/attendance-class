/* 나이스 화면 구조 조사 (읽기 전용) — 아무것도 클릭·입력·저장하지 않음
   이름·사유 등 글자는 가리고 구조만 뽑아 화면에 보여 줌 */
(function(){
  var APP = "https://21clalala.github.io/attendance-class/";
  var OK_WORDS = /^(\/|Ø|미마감|출석|결석|지각|조퇴|결과|질병|미인정|기타|출석인정|질병결석|질병지각|질병조퇴|질병결과|미인정결석|미인정지각|미인정조퇴|미인정결과|기타결석|기타지각|기타조퇴|기타결과|출석인정결석|출석인정지각|출석인정조퇴|출석인정결과|번호|성명|마감|조회|종례|사유|[1-9]교시|적용|닫기|저장|출결마감|마감취소|조회하기|확인|취소|깨끗이)$/;
  function mask(t){
    t = String(t == null ? "" : t).replace(/\s+/g, " ").trim();
    if(!t) return "";
    if(OK_WORDS.test(t)) return t;
    if(/^\d{1,2}$/.test(t)) return t;                       // 번호
    if(/^\d{1,2}학년 \d{1,2}반 \d{4}\.\d{1,2}\.\d{1,2}\./.test(t)) return t.slice(0, 40);
    if(/^\d{4}[.\-]\d{2}[.\-]\d{2}/.test(t)) return t.slice(0, 12);
    return "〔글자" + t.length + "〕";
  }
  var out = [], add = function(s){ out.push(s); };
  function desc(el){
    if(!el || !el.tagName) return String(el);
    var a = el.tagName.toLowerCase();
    if(el.id) a += "#" + el.id;
    if(el.className && typeof el.className === "string") a += "." + el.className.trim().split(/\s+/).slice(0, 4).join(".");
    ["type","role","readonly","disabled","name","col_id","colid","data-col","data-colid","data-row","aria-colindex","aria-rowindex","title"].forEach(function(k){
      if(el.hasAttribute && el.hasAttribute(k)) a += "[" + k + "=" + mask(el.getAttribute(k)).slice(0, 30) + "]";
    });
    return a;
  }
  function path(el){ var p = []; for(var i = 0; el && el.tagName && i < 6; i++, el = el.parentElement) p.unshift(desc(el)); return p.join(" > "); }

  function scanDoc(doc, label){
    add("\n=== 문서: " + label + " ===");
    var w = doc.defaultView;
    add("주소: " + doc.location.href.split("?")[0]);
    add("제목: " + mask(doc.title));
    try{
      var libs = ["WebSquare","$p","scwin","nexacro","jQuery","$","Ext","angular","React","Vue","sbux","IBSheet","AUIGrid","w2ui"].filter(function(k){ return w[k] !== undefined; });
      add("라이브러리: " + (libs.join(", ") || "없음"));
      if(w.WebSquare) add("WebSquare 버전: " + (w.WebSquare.version || w.WebSquare.ver || "?"));
    }catch(e){ add("라이브러리 확인 실패: " + e.message); }

    // 1) 그리드 객체 찾기 (getCellData 같은 함수를 가진 전역 객체)
    try{
      var found = 0;
      Object.keys(w).forEach(function(k){
        var o; try{ o = w[k]; }catch(e){ return; }
        if(!o || typeof o !== "object") return;
        var fn = ["getCellData","setCellData","getRowCount","getColumnID","getColumnCount","getDataList","setFocusedCell","getCellDisplayData","setCellChecked","getAllJSON","getRowJSON"].filter(function(f){ try{ return typeof o[f] === "function"; }catch(e){ return false; } });
        if(fn.length < 2) return;
        found++;
        add("\n[객체] " + k + " — 함수: " + fn.join(", "));
        try{
          var cc = o.getColumnCount ? o.getColumnCount() : null, rc = o.getRowCount ? o.getRowCount() : null;
          add("  행 " + rc + " · 열 " + cc);
          if(cc && o.getColumnID){
            var ids = []; for(var i = 0; i < cc; i++){ try{ ids.push(i + ":" + o.getColumnID(i)); }catch(e){} }
            add("  열 ID: " + ids.join(" | "));
            if(rc){
              for(var r = 0; r < Math.min(rc, 2); r++){
                var vals = []; for(var j = 0; j < cc; j++){ try{ vals.push(o.getColumnID(j) + "=" + mask(o.getCellData(r, j))); }catch(e){} }
                add("  " + r + "행: " + vals.join(" | "));
              }
              // "/" 가 있는 첫 행
              outer: for(var r2 = 0; r2 < rc; r2++){ for(var j2 = 0; j2 < cc; j2++){ var v; try{ v = o.getCellData(r2, j2); }catch(e){ continue; }
                if(v === "/" || v === "Ø"){ var vv = []; for(var j3 = 0; j3 < cc; j3++){ try{ vv.push(o.getColumnID(j3) + "=" + mask(o.getCellData(r2, j3))); }catch(e){} } add("  ('/' 있는 행 " + r2 + "): " + vv.join(" | ")); break outer; } } }
            }
          }
        }catch(e){ add("  읽기 오류: " + e.message); }
      });
      // WebSquare 컴포넌트 목록
      try{
        if(w.$p && w.$p.getComponentById === undefined && w.WebSquare && w.WebSquare.util && w.WebSquare.util.getComponentById) add("WebSquare.util.getComponentById 있음");
        if(w.$p) add("$p 함수: " + Object.keys(w.$p).filter(function(k){ return typeof w.$p[k] === "function"; }).slice(0, 40).join(", "));
      }catch(e){}
      add("그리드처럼 보이는 전역 객체: " + found + "개");
    }catch(e){ add("객체 조사 실패: " + e.message); }

    // 2) 화면 표에서 머리글 찾기
    try{
      var heads = [].slice.call(doc.querySelectorAll("th,td,div,span")).filter(function(e){ var t = (e.textContent || "").trim(); return (t === "1교시" || t === "마감" || t === "사유") && e.children.length <= 2; });
      add("\n머리글 후보 " + heads.length + "개");
      heads.slice(0, 6).forEach(function(h){ add("  " + mask(h.textContent) + " ← " + path(h)); });
      // 첫 학생 줄의 칸들
      var cellsSlash = [].slice.call(doc.querySelectorAll("td,div,span,input")).filter(function(e){ var t = e.tagName === "INPUT" ? e.value : (e.children.length ? "" : (e.textContent || "").trim()); return t === "/" || t === "미마감"; });
      add("'/' 또는 '미마감' 칸 " + cellsSlash.length + "개");
      cellsSlash.slice(0, 3).forEach(function(c){ add("  [" + mask(c.tagName === "INPUT" ? c.value : c.textContent) + "] " + path(c)); });
      if(cellsSlash[0]){
        var row = cellsSlash[0].closest("tr") || cellsSlash[0].parentElement.parentElement;
        add("그 줄 구조: " + desc(row));
        [].slice.call(row.children).slice(0, 14).forEach(function(c, i){
          var inp = c.querySelector("input,textarea,select");
          add("  칸" + i + ": " + desc(c) + " | 글자=" + mask(c.textContent) + (inp ? " | 입력칸=" + desc(inp) + " 값=" + mask(inp.value) : ""));
        });
      }
      var inputs = [].slice.call(doc.querySelectorAll("input[type=text],input:not([type]),textarea"));
      add("글 입력칸 " + inputs.length + "개 (앞 3개): " + inputs.slice(0, 3).map(desc).join(" , "));
      var btns = [].slice.call(doc.querySelectorAll("button,input[type=button],a,[role=button]")).filter(function(b){ return /^(저장|출결마감|마감취소|조회|적용|닫기)$/.test((b.textContent || b.value || "").trim()); });
      add("버튼: " + btns.map(function(b){ return mask(b.textContent || b.value) + "=" + desc(b); }).join(" , "));
      var head = [].slice.call(doc.querySelectorAll("*")).filter(function(e){ return e.children.length === 0 && /\d학년 \d+반 \d{4}\./.test(e.textContent || ""); })[0];
      add("반·날짜 표시: " + (head ? mask(head.textContent) + " ← " + desc(head) : "못 찾음"));
    }catch(e){ add("화면 조사 실패: " + e.message); }

    // 3) 하위 프레임
    var fr = doc.querySelectorAll("iframe,frame");
    add("프레임 " + fr.length + "개");
    [].slice.call(fr).forEach(function(f, i){
      try{ if(f.contentDocument) scanDoc(f.contentDocument, label + " > 프레임" + i + (f.id ? "#" + f.id : "")); else add("프레임" + i + ": 접근 불가"); }
      catch(e){ add("프레임" + i + ": 접근 불가(" + e.name + ")"); }
    });
  }

  add("나이스 화면 조사 결과 · " + new Date().toLocaleString("ko-KR"));
  add("브라우저: " + navigator.userAgent.replace(/.*(Edg\/[\d.]+|Chrome\/[\d.]+).*/, "$1"));
  try{ scanDoc(document, "최상위"); }catch(e){ add("조사 실패: " + e.message); }

  // 4) 마감 창(팝업) 구조 — 지금 열려 있으면 같이 읽음
  try{
    var radios = document.querySelectorAll("input[type=radio]");
    add("\n라디오 버튼 " + radios.length + "개: " + [].slice.call(radios).slice(0, 10).map(function(r){ var l = r.closest("label") || document.querySelector("label[for='" + r.id + "']"); return desc(r) + "(" + mask(l ? l.textContent : "") + ")"; }).join(" , "));
  }catch(e){}

  // 5) 앱 창과 연결 시험 (같은 브라우저 두 창 방식)
  var box = document.createElement("div");
  box.style.cssText = "position:fixed;z-index:2147483647;right:16px;top:16px;width:520px;max-width:92vw;background:#fff;border:2px solid #0f766e;border-radius:12px;box-shadow:0 10px 40px rgba(0,0,0,.3);padding:14px;font:13px/1.5 sans-serif;color:#111";
  box.innerHTML = '<b style="font-size:15px">출결 앱 · 나이스 화면 조사</b><div id="__pmst" style="margin:6px 0;color:#9a5b00">앱 창 연결 시험 중…</div><textarea id="__pbout" style="width:100%;height:300px;font:12px monospace;box-sizing:border-box"></textarea><div style="margin-top:8px;display:flex;gap:8px"><button id="__pbcopy" style="padding:6px 12px;background:#0f766e;color:#fff;border:0;border-radius:6px;cursor:pointer">결과 복사</button><button id="__pbclose" style="padding:6px 12px;border:1px solid #ccc;background:#fff;border-radius:6px;cursor:pointer">닫기</button></div><div style="margin-top:6px;color:#666">읽기만 했습니다. 이름·사유는 〔글자n〕으로 가렸습니다.</div>';
  document.body.appendChild(box);
  var ta = box.querySelector("#__pbout"), st = box.querySelector("#__pmst");
  function show(){ ta.value = out.join("\n"); }
  show();
  box.querySelector("#__pbclose").onclick = function(){ box.remove(); };
  box.querySelector("#__pbcopy").onclick = function(){ ta.select(); try{ document.execCommand("copy"); }catch(e){} if(navigator.clipboard) navigator.clipboard.writeText(ta.value).catch(function(){}); this.textContent = "복사됨 ✓"; };

  var done = false, win = null;
  function finish(msg){ if(done) return; done = true; add("\n[두 창 연결] " + msg); st.textContent = "두 창 연결: " + msg; st.style.color = /성공/.test(msg) ? "#0f766e" : "#c92a2a"; show(); try{ win && win.close(); }catch(e){} window.removeEventListener("message", onMsg); }
  function onMsg(e){ if(e.origin !== "https://21clalala.github.io") return; if(e.data && e.data.type === "attend-pong") finish("성공 (나이스 → 앱 창 → 나이스 메시지 왕복 OK, 앱 창 opener " + (e.data.opener ? "있음" : "없음") + ")"); }
  window.addEventListener("message", onMsg);
  try{
    win = window.open(APP + "neis/ping.html", "attend_ping", "width=360,height=200");
    if(!win) finish("실패 — 팝업이 차단되었습니다. 주소창 오른쪽의 팝업 차단 아이콘에서 이 사이트 팝업을 허용한 뒤 다시 눌러 주세요.");
  }catch(e){ finish("실패 — 창 열기 오류: " + e.message); }
  setTimeout(function(){ finish("실패 — 8초 안에 응답 없음 (나이스 보안 설정이 창 연결을 끊었을 수 있음)"); }, 8000);
})();
