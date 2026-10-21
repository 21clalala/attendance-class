// 나이스 "일일출석부" 엑셀(시트를 2차원 배열로 읽은 것)을 해석
// 반환: { date: "YYYY-MM-DD", students: [{no, name, kind, note, slots:["조회","1",…,"종례"], excluded}] }
(function (root) {
  function parseNeis(rows) {
    const reDate = /(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})\./;
    let date = null, cols = null;
    const students = new Map();
    for (const r of rows) {
      if (!r) continue;
      if (!date) {
        for (const c of r) {
          const m = String(c ?? "").match(reDate);
          if (m) { date = `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`; break; }
        }
      }
      const first = String(r[0] ?? "").trim();
      if (first === "번호") {                       // 머리글 (쪽마다 반복될 수 있음)
        cols = { slots: {} };
        r.forEach((h, i) => {
          h = String(h ?? "").replace(/\s/g, "");
          if (h === "성명") cols.name = i;
          else if (h === "마감") cols.kind = i;
          else if (h === "비고") cols.note = i;
          else if (h === "조회" || h === "종례") cols.slots[h] = i;
          else { const m = h.match(/^(\d)교시$/); if (m) cols.slots[m[1]] = i; }
        });
        continue;
      }
      if (cols && cols.name !== undefined && /^\d+(\.0+)?$/.test(first)) {
        const no = parseInt(first, 10);
        const name = String(r[cols.name] ?? "").trim();
        if (!name) continue;
        const slots = Object.entries(cols.slots)
          .filter(([, i]) => String(r[i] ?? "").trim() !== "")
          .map(([s]) => s);
        students.set(no, {
          no, name,
          kind: cols.kind !== undefined ? String(r[cols.kind] ?? "").trim() : "",
          note: cols.note !== undefined ? String(r[cols.note] ?? "").trim() : "",
          slots,
          excluded: /\(\s*위탁\s*\)/.test(name)
        });
      }
    }
    return { date, students: [...students.values()].sort((a, b) => a.no - b.no) };
  }
  root.parseNeis = parseNeis;
  if (typeof module !== "undefined") module.exports = { parseNeis };
})(typeof window !== "undefined" ? window : globalThis);
