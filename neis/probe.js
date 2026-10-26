/* 나이스 화면 구조 조사 2차 (읽기 전용) — eXBuilder6(cpr) 앱·그리드·데이터셋 구조
   아무것도 클릭·입력·저장하지 않음. 한글 글자(이름·사유 등)는 가리고, 영문 ID·코드는 그대로 둠 */
(function(){
  var APP = "https://21clalala.github.io/attendance-class/";
  var OK = /^(\/|Ø|미마감|출석|결석|지각|조퇴|결과|질병|미인정|기타|출석인정|(질병|미인정|기타|출석인정)(결석|지각|조퇴|결과)|번호|성명|마감|조회|종례|사유|[1-9]교시|적용|닫기|저장|출결마감|마감취소|확인|취소|깨끗이|종류|구분)$/;
  function m(t){
    if(t === null) return "null"; if(t === undefined) return "undef";
    if(typeof t === "number" || typeof t === "boolean") return String(t);
    t = String(t).replace(/\s+/g, " ").trim();
    if(!t) return "''";
    if(OK.test(t)) return t;
    if(/^\d{1,2}학년 \d{1,2}반 \d{4}\./.test(t)) return t.slice(0, 30);
    if(/\d{7,}/.test(t) && !/^(J|S)\d{9}$|^\d{8}$|^20\d{8}$/.test(t)) return "〔숫자" + t.length + "〕";   // 주민번호 등 긴 숫자는 가림
    if(/^[\x20-\x7e]{1,40}$/.test(t)) return t;                 // 영문·숫자·기호(코드값)는 그대로
    return "〔" + t.length + "〕";
  }
  var out = [], add = function(s){ out.push(s); };
  var safe = function(f, d){ try{ return f(); }catch(e){ return d === undefined ? "ERR:" + e.message : d; } };
  add("나이스 화면 조사 2차 · " + new Date().toLocaleString("ko-KR"));
  add("브라우저: " + navigator.userAgent.replace(/.*(Edg\/[\d.]+|Chrome\/[\d.]+).*/, "$1"));
  var cpr = window.cpr;
  add("cpr: " + (cpr ? "있음 · 하위=" + Object.keys(cpr).join(",") : "없음"));
  if(cpr && cpr.core) add("cpr.core: " + Object.keys(cpr.core).slice(0, 40).join(","));
  add("화면 제목: " + safe(function(){ return m(document.querySelector("h3.cl-text").textContent); }));

  // 1) 실행 중인 앱 인스턴스
  var apps = safe(function(){ return cpr.core.Platform.INSTANCE.getAllRunningAppInstances(); }, null);
  if(!apps){ apps = []; add("앱 목록 실패: " + safe(function(){ return cpr.core.Platform.INSTANCE ? "INSTANCE 함수=" + Object.keys(Object.getPrototypeOf(cpr.core.Platform.INSTANCE)).join(",") : "INSTANCE 없음"; })); }
  add("실행 중 앱 " + apps.length + "개");

  apps.forEach(function(ai, n){
    var appId = safe(function(){ return ai.app.id; });
    var ctrls = safe(function(){ return ai.getContainer().getAllRecursiveChildren(); }, []);
    var datas = safe(function(){ return ai.getAllDataControls(); }, []);
    var hasGrid = ctrls.some(function(c){ return c.type === "grid"; }), hasRadio = ctrls.some(function(c){ return c.type === "radio"; });
    add("\n=== 앱" + n + ": " + appId + " · 컨트롤 " + ctrls.length + " · 데이터 " + datas.length + (hasGrid ? " · 그리드 있음" : "") + (hasRadio ? " · 라디오 있음" : ""));
    if(!hasGrid && !hasRadio && ctrls.length > 400) return;
    // 데이터 컨트롤
    datas.forEach(function(ds){
      var cols = safe(function(){ return ds.getColumnNames(); }, []);
      var rc = safe(function(){ return ds.getRowCount(); }, "-");
      add("  [데이터] " + ds.id + " (" + ds.type + ") 행=" + rc + " 열=" + cols.join(","));
      if(ds.type === "dataset" && rc > 0 && cols.length){
        var pick = [0];
        for(var r = 0; r < rc; r++){ if(cols.some(function(c){ var v = safe(function(){ return ds.getValue(r, c); }, ""); return v === "/" || v === "Ø"; })){ pick.push(r); break; } }
        for(var r2 = 0; r2 < rc; r2++){ if(cols.some(function(c){ var v = String(safe(function(){ return ds.getValue(r2, c); }, "")); return /(지각|조퇴|결과|결석)$/.test(v); })){ if(pick.indexOf(r2) < 0) pick.push(r2); break; } }
        var SENS = /rrno|brdt|ipaddr|telno|addr|email|userid|invlno/i;
        pick.forEach(function(r){ add("    " + r + "행: " + cols.map(function(c){ return c + "=" + (SENS.test(c) ? "〔가림〕" : m(safe(function(){ return ds.getValue(r, c); }))); }).join(" | ")); });
        add("    행 상태(0행): " + safe(function(){ return ds.getRowState(0); }));
      }
      if(ds.type === "datamap"){ add("    값: " + cols.map(function(c){ return c + "=" + (/rrno|brdt|ipaddr|telno|addr|email|userid|invlno|userDtcNo/i.test(c) ? "〔가림〕" : m(safe(function(){ return ds.getValue(c); }))); }).join(" | ")); }
    });
    // 그리드
    ctrls.filter(function(c){ return c.type === "grid"; }).forEach(function(g){
      add("  [그리드] id=" + g.id + " 데이터셋=" + safe(function(){ return g.dataSet.id; }) + " 행=" + safe(function(){ return g.getViewingEndRowIndex ? g.rowCount : g.dataSet.getRowCount(); }));
      add("    그리드 함수 일부: " + safe(function(){ var p = Object.getPrototypeOf(g), ks = []; while(p && ks.length < 400){ ks = ks.concat(Object.getOwnPropertyNames(p)); p = Object.getPrototypeOf(p); } return ks.filter(function(k){ return /^(get|set|select|focus|click|update|refresh|dispatch|fire)/.test(k); }).filter(function(k, i, a){ return a.indexOf(k) === i; }).slice(0, 90).join(","); }));
      var ccount = safe(function(){ return g.detail.cellCount; }, 0);
      add("    상세 칸 수=" + ccount);
      for(var i = 0; i < Math.min(ccount || 0, 20); i++){
        add("    칸" + i + ": " + safe(function(){ var c = g.detail.getColumn(i); return "열=" + c.columnName + " 컨트롤=" + (c.control ? c.control.type + (c.control.readOnly ? "(읽기전용)" : "") : "-") + " 편집=" + c.columnType; }));
      }
      var hc = safe(function(){ return g.header.cellCount; }, 0);
      add("    머리글: " + Array.from({length: Math.min(hc || 0, 20)}, function(_, i){ return safe(function(){ var c = g.header.getColumn(i); return m(c.text || c.value); }); }).join(" | "));
      var ev = safe(function(){ return Object.keys(g._eventListeners || g._listeners || {}).join(","); });
      add("    이벤트: " + ev);
    });
    // 라디오·입력·버튼 (마감 창 등)
    ctrls.filter(function(c){ return /radio|combobox|inputbox|textarea|checkbox|button/.test(c.type) && c.visible !== false; }).slice(0, 40).forEach(function(c){
      var info = "  [" + c.type + "] id=" + c.id;
      if(c.type === "radio" || c.type === "combobox") info += " 항목=" + safe(function(){ var a = []; for(var i = 0; i < c.getItemCount(); i++){ var it = c.getItem(i); a.push(m(it.label) + ":" + m(it.value)); } return a.join(","); }) + " 값=" + m(safe(function(){ return c.value; }));
      if(c.type === "button") info += " 글자=" + m(c.value || c.text);
      if(c.type === "inputbox" || c.type === "textarea") info += " 값=" + m(safe(function(){ return c.value; })) + (c.readOnly ? " 읽기전용" : "");
      info += " 바인딩=" + safe(function(){ var b = c.getBindInfo ? c.getBindInfo("value") : null; return b ? JSON.stringify(b).slice(0, 80) : "-"; });
      add(info);
    });
  });

  // 2) 스크립트 불러오기 시험 (나중에 북마클릿을 짧게 만들 수 있는지)
  var box = document.createElement("div");
  box.style.cssText = "position:fixed;z-index:2147483647;right:16px;top:16px;width:560px;max-width:92vw;background:#fff;border:2px solid #0f766e;border-radius:12px;box-shadow:0 10px 40px rgba(0,0,0,.3);padding:14px;font:13px/1.5 sans-serif;color:#111";
  box.innerHTML = '<b style="font-size:15px">출결 앱 · 나이스 화면 조사 2차</b><div id="__st" style="margin:6px 0;color:#9a5b00">스크립트 불러오기 시험 중…</div><textarea id="__out" style="width:100%;height:320px;font:12px monospace;box-sizing:border-box"></textarea><div style="margin-top:8px;display:flex;gap:8px"><button id="__cp" style="padding:6px 12px;background:#0f766e;color:#fff;border:0;border-radius:6px;cursor:pointer">결과 복사</button><button id="__cl" style="padding:6px 12px;border:1px solid #ccc;background:#fff;border-radius:6px;cursor:pointer">닫기</button></div><div style="margin-top:6px;color:#666">읽기만 했습니다. 한글 이름·사유는 〔글자 수〕로 가렸습니다.</div>';
  document.body.appendChild(box);
  var ta = box.querySelector("#__out"), st = box.querySelector("#__st");
  var show = function(){ ta.value = out.join("\n"); }; show();
  box.querySelector("#__cl").onclick = function(){ box.remove(); };
  box.querySelector("#__cp").onclick = function(){ ta.select(); try{ document.execCommand("copy"); }catch(e){} if(navigator.clipboard) navigator.clipboard.writeText(ta.value).catch(function(){}); this.textContent = "복사됨 ✓"; };
  var fin = false, end = function(msg){ if(fin) return; fin = true; add("\n[외부 스크립트] " + msg); st.textContent = "외부 스크립트: " + msg; show(); };
  window.__attendLoadTest = function(){ end("성공 (짧은 북마클릿 가능)"); };
  var s = document.createElement("script");
  s.src = APP + "neis/loadtest.js?" + Date.now();
  s.onerror = function(){ end("실패 (나이스 보안 설정이 막음 → 북마클릿에 전체 코드를 넣는 방식으로)"); };
  document.head.appendChild(s);
  setTimeout(function(){ end("응답 없음 (막힌 것으로 봄)"); }, 6000);
})();
