/* 출결신고서 자동 작성 (원본: 출결신고서 만들기 V2) — HWPX 양식에 학생당 1쪽씩 채움 */
// 출결신고서 자동 작성 핵심 로직 (브라우저/Node 공용)
(function (root) {
  const HP = 'http://www.hancom.co.kr/hwpml/2011/paragraph';
  const TYPES = ['결석', '지각', '조퇴', '결과'];           // 제목 동그라미 순서(왼→오)
  const SYMPTOMS = ['복통', '두통', '감기', '외과 진료', '안과 진료', '이비인후 통증'];
  const INFECT = /코로나|인플루엔자|독감|법정|감염/;
  const FAMILY = /경조|조문|장례|사망|결혼|혼례|[부모형제매자손]상|조부|조모|외조/;
  const PERIODS = ['조회', '1', '2', '3', '4', '5', '6', '7', '종례'];   // 출결 앱: 7교시까지

  // ---------- 1) 나이스 엑셀(행 배열) 해석 ----------
  function parseNeis(aoa) {
    let grade = '', cls = '', date = null, col = null;
    const rows = [];
    for (const r of aoa) {
      const cells = r.map(v => (v == null ? '' : String(v).trim()));
      const joined = cells.join(' ');
      const m = joined.match(/(\d+)학년\s*(\d+)반\s*(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})/);
      if (m) { grade = m[1]; cls = m[2]; date = { y: +m[3], m: +m[4], d: +m[5] }; continue; }
      if (cells.includes('번호') && cells.includes('마감')) {
        col = {};
        cells.forEach((c, i) => { const k = c.replace(/교시$/, ''); if (c && !(k in col)) col[k] = i; });
        continue;
      }
      if (!col) continue;
      const no = Number(cells[col['번호']]);
      if (!Number.isInteger(no) || no <= 0) continue;
      const kind = cells[col['마감']] || '';
      if (!kind) continue;
      const rawName = cells[col['성명']] || '';
      rows.push({
        no, rawName,
        name: rawName.replace(/\(.*?\)/g, '').trim(),
        kind,
        note: cells[col['비고'] ?? col['사유']] || '',
        marks: PERIODS.map(p => (cells[col[p]] || '') !== ''),
      });
    }
    return { grade, cls, date, rows: rows.map(classify) };
  }

  function classify(r) {
    const type = TYPES.find(t => r.kind.endsWith(t)) || '';
    const cat = type ? r.kind.slice(0, -type.length) : r.kind;      // 질병 / 출석인정 / 미인정 / 기타
    const inside = (r.note.match(/\(([^)]*)\)/) || [, ''])[1];
    const reason = inside.split('/').map(s => s.trim())
      .filter(s => s && !/교시|조회|종례/.test(s)).join('/');
    const idx = r.marks.map((v, i) => (v ? i : -1)).filter(i => i >= 0);
    const label = i => PERIODS[i];
    // 나이스 표기 그대로: 표시된 첫 칸 ~ 마지막 칸 (조회/1~6/종례), 결석은 조회~종례 1일간
    let from = '', to = '', days = '';
    if (type === '결석') { from = '조회'; to = '종례'; days = 1; }
    else if (type && idx.length) { from = label(idx[0]); to = label(idx[idx.length - 1]); }
    // 출석인정은 생리통·경조사·법정감염병만 신고서 작성 (대회·고사응시 등 그 밖의 사유는 제외)
    const checks = deriveChecks(cat, reason);
    const aiOk = cat === '출석인정' && AI_KEYS.some(k => checks.on[k]);
    const include = !!type && (cat === '질병' || (cat === '출석인정' && aiOk));
    let skip = '';
    if (!type) skip = '유형 인식 불가';
    else if (cat === '미인정') skip = '미인정(신고서 불필요)';
    else if (cat === '출석인정' && !aiOk) skip = '출석인정 그 밖의 사유(신고서 불필요)';
    else if (!include) skip = `'${cat}' 구분(현재 규칙 밖)`;
    return { ...r, type, cat, reason, from, to, days, include, skip, checks };
  }

  // ---------- 1-1) 비고 사유 → 양식 체크 항목 ----------
  // 띄어쓰기를 무시하고 양식의 체크박스 이름과 맞춰 봄 (예: '이비인후통증' = '이비인후 통증')
  const AI_KEYS = ['생리통', '경조사', '법정감염병', '코로나19', '인플루엔자', '감염기타'];
  const looseRe = t => new RegExp(t.replace(/\s/g, '').split('').map(c => c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('\\s*'), 'g');
  const leftover = (txt, words) => {
    let t = txt; words.forEach(w => { t = t.replace(w instanceof RegExp ? w : looseRe(w), ' '); });
    return t.replace(/[,\/·、;:()\[\]\-]+/g, ' ').replace(/\s+/g, ' ').trim();
  };
  function deriveChecks(cat, reason) {
    const on = {}, text = {}; reason = reason || '';
    if (cat === '질병') {
      const hit = SYMPTOMS.filter(x => looseRe(x).test(reason));
      hit.forEach(x => { on[x] = true; });
      const rest = leftover(reason, hit);
      if (rest) { on['질병기타'] = true; text['질병기타'] = rest; }
    } else if (cat === '출석인정') {
      if (/생\s*리/.test(reason)) on['생리통'] = true;
      if (/코\s*로\s*나/.test(reason)) on['코로나19'] = true;
      if (/인\s*플\s*루\s*엔\s*자|독\s*감/.test(reason)) on['인플루엔자'] = true;
      if (FAMILY.test(reason.replace(/\s/g, ''))) {
        on['경조사'] = true;
        const t = leftover(reason, [/경\s*조\s*사?/g]); if (t) text['경조사'] = t;
      }
      if (!on['코로나19'] && !on['인플루엔자'] && INFECT.test(reason.replace(/\s/g, ''))) {
        on['감염기타'] = true;
        const t = leftover(reason, [/법\s*정\s*감\s*염\s*병|감\s*염\s*병|법\s*정/g]); if (t) text['감염기타'] = t;
      }
      if (on['코로나19'] || on['인플루엔자'] || on['감염기타']) on['법정감염병'] = true;
    }
    return { on, text };
  }
  // 표에 보여줄 요약
  function describe(cat, c) {
    if (cat !== '질병' && cat !== '출석인정') return '사유 미지정';
    const parts = [];
    if (cat === '질병') {
      SYMPTOMS.forEach(x => c.on[x] && parts.push(x));
      if (c.on['질병기타']) parts.push('기타: ' + (c.text['질병기타'] || ''));
    } else {
      if (c.on['생리통']) parts.push('생리통');
      if (c.on['경조사']) parts.push('경조사: ' + (c.text['경조사'] || ''));
      const inf = [c.on['코로나19'] && '코로나19', c.on['인플루엔자'] && '인플루엔자', c.on['감염기타'] && ('기타: ' + (c.text['감염기타'] || ''))].filter(Boolean);
      if (c.on['법정감염병'] || inf.length) parts.push('법정감염병' + (inf.length ? '(' + inf.join(', ') + ')' : ''));
    }
    return '☑' + cat + (parts.length ? ' · ' + parts.map(p => p.trim()).join(' · ') : '');
  }

  // ---------- 2) 텍스트 노드 색인 (여러 <hp:t>를 이어 붙인 문자열처럼 다룸) ----------
  class TextIndex {
    constructor(els) { this.els = els; this.rebuild(); }
    rebuild() {
      this.nodes = []; let s = '';
      const walk = n => {
        for (let c = n.firstChild; c; c = c.nextSibling) {
          if (c.nodeType === 3 && c.parentNode.localName === 't') { this.nodes.push({ n: c, at: s.length, para: cur }); s += c.data; }
          else if (c.nodeType === 1) walk(c);
        }
      };
      let cur = null;
      this.els.forEach(e => { cur = e; walk(e); }); this.str = s;
    }
    loc(i) { for (let k = this.nodes.length - 1; k >= 0; k--) if (this.nodes[k].at <= i) return { n: this.nodes[k].n, off: i - this.nodes[k].at, para: this.nodes[k].para }; }
    setChar(i, ch) { const { n, off } = this.loc(i); const v = n.data; n.data = v.slice(0, off) + ch + v.slice(off + 1); this.rebuild(); }
    insertAt(i, text) { const { n, off } = this.loc(i - 1); const v = n.data; n.data = v.slice(0, off + 1) + text + v.slice(off + 1); this.rebuild(); }
    find(s, from = 0) { return this.str.indexOf(s, from); }
    delAt(i) { const { n, off } = this.loc(i); const v = n.data; n.data = v.slice(0, off) + v.slice(off + 1); this.rebuild(); }
  }

  // label 앞의 가장 가까운 □ 를 ☑ 로. anchors: 순서대로 찾아가며 위치를 좁힘
  function check(ti, label, anchors = []) {
    let from = 0;
    for (const a of anchors) { const p = ti.find(a, from); if (p < 0) throw new Error('양식에서 찾을 수 없음: ' + a); from = p + a.length; }
    const pos = ti.find(label, from);
    if (pos < 0) throw new Error('양식에서 찾을 수 없음: ' + label);
    for (let i = pos - 1; i >= Math.max(0, pos - 4); i--) {
      const ch = ti.str[i];
      if (ch === '□' || ch === '☑') { ti.lastBox = ti.loc(i).n; ti.setChar(i, '☑'); return pos; }
      if (ch.trim()) break;
    }
    throw new Error('체크박스를 찾을 수 없음: ' + label);
  }
  function appendAfter(ti, pos, label, text) { ti.insertAt(pos + label.length, text); }

  const pad = (gap, val) => {
    val = String(val ?? ''); if (!val) return gap;
    const L = gap.length, left = Math.max(1, Math.floor((L - val.length) / 2));
    return ' '.repeat(left) + val + ' '.repeat(Math.max(1, L - left - val.length));
  };
  // 겹쳐쓰기: 공백을 글자 폭만큼(한글 2칸, 그 외 1칸) 지우고 그 자리에 씀 → (인) 위치 고정
  const wid = t => [...t].reduce((a, c) => a + (/[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]/.test(c) ? 2 : 1), 0);
  const overwrite = (gap, val) => {
    const w = wid(val), L = gap.length; if (!val || w > L - 2) return ' ' + val + ' ';
    const left = Math.floor((L - w) / 2);
    return ' '.repeat(left) + val + ' '.repeat(L - w - left);
  };
  // 수정(겹쳐쓰기) 모드: 빈칸 폭 그대로 두고 그 안에 씀 (한글 2칸, 그 외 1칸)
  const fit = (gap, val) => {
    val = String(val ?? ''); if (!val) return gap;
    const w = wid(val), L = gap.length; if (w >= L) return val;
    const left = Math.ceil((L - w) / 2);
    return ' '.repeat(left) + val + ' '.repeat(L - w - left);
  };
  // pos 뒤의 공백(여러 텍스트 조각에 걸쳐 있어도)을 이름 폭만큼 지우고 그 자리에 씀
  function overwriteAfter(ti, pos, val) {
    let i = pos; if (ti.str[i] === ' ') i++;
    const para = ti.loc(Math.max(0, i - 1)).para;   // 같은 문단 안의 공백만 씀
    let k = 0; while (ti.str[i + k] === ' ' && ti.loc(i + k).para === para) k++;
    const del = Math.min(wid(val), k);
    for (let n = 0; n < del; n++) ti.delAt(i);
    ti.insertAt(i, val);
  }
  // 조회·종례는 '교시'를 붙이지 않음: (4)교시 ~ (종례)
  const per = p => (p === '조회' || p === '종례' ? '' : '교시');
  function replaceInNodes(ti, re, fn) {
    for (const { n } of ti.nodes) if (re.test(n.data)) { n.data = n.data.replace(re, fn); ti.rebuild(); return true; }
    return false;
  }

  // ---------- 3) 한 학생 분량(문단 묶음)에 내용 채우기 ----------
  // form: 'report'(출결신고서) | 'parent'(학부모확인서)
  function fillOne(paras, info, rec, opts = {}, form = 'report') {
    info = rec.info || info;
    const all = [];
    paras.forEach(p => all.push(...Array.from(p.getElementsByTagNameNS(HP, '*'))));
    const ti = new TextIndex(paras);

    // (1) 동그라미: 제목 괄호 안 순서(양식마다 다름)대로 가로 위치를 대응
    const om = ti.str.match(/\(\s*(결석|지각|조퇴|결과)\s*,\s*(결석|지각|조퇴|결과)\s*,\s*(결석|지각|조퇴|결과)\s*,\s*(결석|지각|조퇴|결과)\s*\)/);
    const order = om ? om.slice(1, 5) : TYPES;
    const ells = all.filter(e => e.localName === 'ellipse').map(e => {
      const pos = Array.from(e.getElementsByTagNameNS(HP, 'pos'))[0];
      return { e, x: +pos.getAttribute('horzOffset') };
    }).sort((a, b) => a.x - b.x);
    if (ells.length !== 4) throw new Error('양식의 동그라미가 4개가 아닙니다: ' + ells.length);
    ells.forEach((o, i) => { if (order[i] !== rec.type) o.e.parentNode.removeChild(o.e); });

    // 양식에 남아 있는 ☑ 는 모두 □ 로 초기화
    for (let i = ti.str.indexOf('☑'); i >= 0; i = ti.str.indexOf('☑', i + 1)) ti.setChar(i, '□');

    // (2)~(3-1) 학부모확인서는 '수정' 모드(칸이 늘어나지 않게), 신고서는 기존 방식
    const fixed = form === 'parent';
    const P = fixed ? fit : pad;
    const d = info.date, yy = String(d.y).slice(2);

    // (2) 학년 반 번, 성명
    replaceInNodes(ti, /제(\s+)학년(\s+)반(\s+)번/, (_, a, b, c) => `제${P(a, info.grade)}학년${P(b, info.cls)}반${P(c, rec.no)}번`);
    if (fixed) { const ni = ti.find('성명:'); if (ni >= 0) overwriteAfter(ti, ni + 3, rec.name); }
    else {
      const ni = ti.find('성명: '); if (ni >= 0) ti.insertAt(ni + 4, rec.name);
      else replaceInNodes(ti, /성명:/, () => '성명: ' + rec.name);
    }

    // (3) 기간 / 출결 발생일
    const yr = g => fixed ? (wid(g) >= 2 ? '26'.replace('26', yy) + ' '.repeat(g.length - 2) : yy) : `${yy} `;
    const perSeg = (gap, val) => {           // "(   )교시" 한 덩어리
      const body = `(${P(gap, val)})${per(val)}`;
      if (!fixed) return body;
      const lack = wid(`(${gap})교시`) - wid(body);
      return body + ' '.repeat(Math.max(0, lack));
    };
    replaceInNodes(ti,
      /20(\s+)년(\s+)월(\s+)일(\s*)\((\s*)\)교시(\s*)~(\s+)월(\s+)일(\s*)\((\s*)\)교시(\s*)\[(\s+)일간\]/,
      (_, y, m1, d1, s1, p1, sp, m2, d2, s2, p2, sp2, n) =>
        `20${yr(y)}년${P(m1, d.m)}월${P(d1, d.d)}일${s1}${perSeg(p1, rec.from)}${sp}~${P(m2, d.m)}월${P(d2, d.d)}일${s2}${perSeg(p2, rec.to)}${sp2}[${P(n, rec.days)}일간]`);

    // (3-1) 하단 날짜 = 출결 발생일, 학생 서명란 = 이름(칸 폭 유지)
    while (replaceInNodes(ti, /20(\s+)년(\s+)월(\s+)일(?!\s*\()/, (_, y, m1, d1) => `20${yr(y)}년${P(m1, d.m)}월${P(d1, d.d)}일`)) {}
    replaceInNodes(ti, /학\s*생:(\s+)\(인\)/, (s, g) => s.replace(g, overwrite(g, rec.name)));

    const c = rec.checks || deriveChecks(rec.cat, rec.reason);
    const T = k => ((c.text && c.text[k]) || '').trim();
    const anyInfect = c.on['법정감염병'] || c.on['코로나19'] || c.on['인플루엔자'] || c.on['감염기타'];

    if (form === 'parent') {
      // 학부모확인서: 출결 유형만 체크, 사유 칸은 비움
      if (rec.cat === '질병') check(ti, '질병', ['유형']);
      else if (rec.cat === '출석인정') {
        check(ti, '출석인정', ['유형']);
        if (c.on['생리통']) check(ti, '생리통', ['유형', '출석인정']);
        if (c.on['경조사']) check(ti, '경조사', ['유형', '출석인정']);
        if (anyInfect) check(ti, '법정감염병', ['유형', '출석인정']);
      }
      return;
    }

    // (3-2) 확인 방법: 학부모 확인 (굴림 칸이라 ☑ 표시용 글꼴로 바꿈)
    if (ti.find('학부모 확인') >= 0) {
      check(ti, '학부모 확인', ['방법']);
      if (opts.boxCharPr) { const run = ti.lastBox.parentNode.parentNode; if (run.localName === 'run') run.setAttribute('charPrIDRef', opts.boxCharPr); }
    }

    // (4) 사유 체크 (rec.checks 기준 — 화면에서 고친 내용 그대로)
    if (rec.cat === '질병') {
      check(ti, '질병', ['사유']);
      SYMPTOMS.forEach(x => { if (c.on[x]) check(ti, x, ['사유', '질병']); });
      if (c.on['질병기타']) { const p = check(ti, '기타:', ['사유', '질병']); if (T('질병기타')) appendAfter(ti, p, '기타:', ' ' + T('질병기타')); }
    } else if (rec.cat === '출석인정') {
      check(ti, '출석', ['사유']);
      if (c.on['생리통']) check(ti, '생리통', ['사유', '출석']);
      if (c.on['경조사']) { const p = check(ti, '경조사:', ['사유', '출석']); if (T('경조사')) appendAfter(ti, p, '경조사:', ' ' + T('경조사')); }
      if (anyInfect) check(ti, '법정감염병', ['사유', '출석']);
      if (c.on['코로나19']) check(ti, '코로나', ['사유', '법정감염병']);
      if (c.on['인플루엔자']) check(ti, '인플루엔자', ['사유', '법정감염병']);
      if (c.on['감염기타']) { const p = check(ti, '기타:', ['사유', '법정감염병']); if (T('감염기타')) appendAfter(ti, p, '기타:', ' ' + T('감염기타')); }
    }
  }

  // 생리통 출석인정은 학부모확인서를 신고서 뒤에 붙임
  const needsParent = rec => rec.cat === '출석인정' && !!(rec.checks && rec.checks.on['생리통']);

  // ---------- 4) 여러 학생을 한 파일로 (학생당 신고서 1쪽 [+ 학부모확인서 1쪽]) ----------
  function buildSection(xmlText, info, recs, { DOMParser, XMLSerializer }, opts = {}) {
    const doc = new DOMParser().parseFromString(xmlText, 'application/xml');
    const sec = doc.documentElement;
    const kids = d => Array.from(d.documentElement.childNodes).filter(n => n.nodeType === 1 && n.localName === 'p');
    const tpl = kids(doc);
    tpl.forEach(p => sec.removeChild(p));
    const ptpl = opts.parentXml ? kids(new DOMParser().parseFromString(opts.parentXml, 'application/xml')).map(p => doc.importNode(p, true)) : null;
    let page = 0;
    const clonePage = src => {
      const paras = src.map(p => p.cloneNode(true));
      if (page > 0) {
        const first = paras[0];
        Array.from(first.getElementsByTagNameNS(HP, 'secPr')).forEach(e => e.parentNode.removeChild(e));
        Array.from(first.getElementsByTagNameNS(HP, 'ctrl')).forEach(e => e.parentNode.removeChild(e));
        first.setAttribute('pageBreak', '1');
        paras.forEach(p => Array.from(p.getElementsByTagNameNS(HP, '*')).forEach(e => {
          if ((e.localName === 'tbl' || e.localName === 'ellipse') && e.getAttribute('id')) e.setAttribute('id', String(+e.getAttribute('id') + page * 1000));
          if (e.getAttribute('instid')) e.setAttribute('instid', String(+e.getAttribute('instid') + page * 1000));
        }));
      }
      page++;
      return paras;
    };
    recs.forEach(rec => {
      const paras = clonePage(tpl);
      fillOne(paras, info, rec, opts, 'report');
      paras.forEach(p => sec.appendChild(p));
      if (ptpl && needsParent(rec)) {
        const pp = clonePage(ptpl);
        fillOne(pp, info, rec, opts, 'parent');
        pp.forEach(p => sec.appendChild(p));
      }
    });
    // 줄 배치 캐시 제거 → 한글이 열 때 다시 계산
    Array.from(sec.getElementsByTagNameNS(HP, 'linesegarray')).forEach(e => e.parentNode.removeChild(e));
    let out = new XMLSerializer().serializeToString(doc);
    if (!out.startsWith('<?xml')) out = '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>' + out;
    return out;
  }

  // ---------- 5) 두 번째 양식의 서식(글꼴·테두리·글자·문단 모양)을 첫 양식 header에 덧붙이기 ----------
  const LANGS = ['HANGUL', 'LATIN', 'HANJA', 'JAPANESE', 'OTHER', 'SYMBOL', 'USER'];
  const items = (xml, tag) => xml.match(new RegExp(`<hh:${tag}\\b[^>]*/>|<hh:${tag}\\b[\\s\\S]*?</hh:${tag}>`, 'g')) || [];
  const ids = arr => arr.map(x => +x.match(/\bid="(\d+)"/)[1]);
  function appendItems(head, wrapTag, tag, newItems) {
    const re = new RegExp(`(<hh:${wrapTag} itemCnt=")(\\d+)(")`);
    head = head.replace(re, (_, a, n, b) => a + (+n + newItems.length) + b);
    return head.replace(`</hh:${wrapTag}>`, newItems.join('') + `</hh:${wrapTag}>`);
  }
  function mergeHeader(head, phead, psec) {
    // 글꼴: 언어별 목록 뒤에 붙임
    const fontOff = {};
    LANGS.forEach(L => {
      const rb = head.match(new RegExp(`<hh:fontface lang="${L}"[\\s\\S]*?</hh:fontface>`));
      const pb = phead.match(new RegExp(`<hh:fontface lang="${L}"[\\s\\S]*?</hh:fontface>`));
      if (!rb || !pb) { fontOff[L] = 0; return; }
      const rf = items(rb[0], 'font'), pf = items(pb[0], 'font');
      const off = (rf.length ? Math.max(...ids(rf)) + 1 : 0) - (pf.length ? Math.min(...ids(pf)) : 0);
      fontOff[L] = off;
      const moved = pf.map(f => f.replace(/\bid="(\d+)"/, (_, n) => `id="${+n + off}"`));
      const nb = rb[0].replace(/fontCnt="(\d+)"/, (_, n) => `fontCnt="${+n + moved.length}"`).replace('</hh:fontface>', moved.join('') + '</hh:fontface>');
      head = head.replace(rb[0], nb);
    });
    const offOf = tag => { const r = items(head, tag), p = items(phead, tag); return (r.length ? Math.max(...ids(r)) + 1 : 0) - (p.length ? Math.min(...ids(p)) : 0); };
    const bOff = offOf('borderFill'), cOff = offOf('charPr'), tOff = offOf('tabPr'), pOff = offOf('paraPr');
    const reId = (x, off) => x.replace(/\bid="(\d+)"/, (_, n) => `id="${+n + off}"`);
    const bf = items(phead, 'borderFill').map(x => reId(x, bOff));
    const cp = items(phead, 'charPr').map(x => reId(x, cOff)
      .replace(/<hh:fontRef([^>]*)\/>/, (m, attrs) => '<hh:fontRef' + attrs.replace(/(\w+)="(\d+)"/g, (mm, k, v) => { const L = k.toUpperCase(); return L in fontOff ? `${k}="${+v + fontOff[L]}"` : mm; }) + '/>')
      .replace(/borderFillIDRef="(\d+)"/g, (_, n) => `borderFillIDRef="${+n + bOff}"`));
    const tp = items(phead, 'tabPr').map(x => reId(x, tOff));
    const pp = items(phead, 'paraPr').map(x => reId(x, pOff)
      .replace(/tabPrIDRef="(\d+)"/g, (_, n) => `tabPrIDRef="${+n + tOff}"`)
      .replace(/borderFillIDRef="(\d+)"/g, (_, n) => `borderFillIDRef="${+n + bOff}"`));
    head = appendItems(head, 'borderFills', 'borderFill', bf);
    head = appendItems(head, 'charProperties', 'charPr', cp);
    head = appendItems(head, 'tabProperties', 'tabPr', tp);
    head = appendItems(head, 'paraProperties', 'paraPr', pp);
    psec = psec.replace(/charPrIDRef="(\d+)"/g, (_, n) => `charPrIDRef="${+n + cOff}"`)
      .replace(/paraPrIDRef="(\d+)"/g, (_, n) => `paraPrIDRef="${+n + pOff}"`)
      .replace(/borderFillIDRef="(\d+)"/g, (_, n) => `borderFillIDRef="${+n + bOff}"`);
    return { head, psec };
  }

  async function buildHwpx(JSZip, templateBuf, info, recs, xml, parentBuf) {
    const src = await JSZip.loadAsync(templateBuf);
    const secXml = await src.file('Contents/section0.xml').async('string');
    let head = await src.file('Contents/header.xml').async('string');
    const opts = {};
    const cm = head.match(/<hh:charProperties itemCnt="(\d+)"/);
    const c25 = head.match(/<hh:charPr id="25"[\s\S]*?<\/hh:charPr>/);
    if (cm && c25) {
      const nid = String(Math.max(...ids(items(head, 'charPr'))) + 1);
      const fontId = (head.match(/<hh:fontface lang="HANGUL"[\s\S]*?<\/hh:fontface>/)[0].match(/<hh:font id="(\d+)" face="함초롬바탕"/) || [, '3'])[1];
      const clone = c25[0].replace('id="25"', `id="${nid}"`).replace(/<hh:fontRef[^>]*\/>/, `<hh:fontRef hangul="${fontId}" latin="${fontId}" hanja="${fontId}" japanese="${fontId}" other="${fontId}" symbol="${fontId}" user="${fontId}"/>`);
      head = appendItems(head, 'charProperties', 'charPr', [clone]);
      opts.boxCharPr = nid;
    }
    if (parentBuf && recs.some(needsParent)) {
      const ps = await JSZip.loadAsync(parentBuf);
      const m = mergeHeader(head, await ps.file('Contents/header.xml').async('string'), await ps.file('Contents/section0.xml').async('string'));
      head = m.head; opts.parentXml = m.psec;
    }
    const newSec = buildSection(secXml, info, recs, xml, opts);
    const out = new JSZip();
    out.file('mimetype', await src.file('mimetype').async('uint8array'), { compression: 'STORE' });
    for (const name of Object.keys(src.files)) {
      const f = src.files[name];
      if (f.dir || name === 'mimetype') continue;
      if (name === 'Contents/section0.xml') out.file(name, newSec);
      else if (name === 'Contents/header.xml') out.file(name, head);
      else out.file(name, await f.async('uint8array'));
    }
    return out;
  }

  const api = { PERIODS, parseNeis, classify, deriveChecks, describe, needsParent, buildSection, buildHwpx, TYPES, SYMPTOMS };
  if (typeof module !== 'undefined') module.exports = api; else root.AttendForm = api;
})(this);
