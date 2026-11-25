// 카카오톡 챗봇(오픈빌더 스킬) → 학생 본인의 교외체험학습 사용 일수 안내
//
// 배포: Supabase 대시보드 → Edge Functions → 이 파일 내용 그대로 붙여 넣기 (함수 이름 kakao-attendance)
//   · 함수 설정에서 "Verify JWT" 끄기 (카카오는 Supabase 로그인 토큰을 보내지 않음)
//   · Edge Functions → Secrets 에 KAKAO_SKILL_SECRET (아무 긴 문자열) 추가
//   · 오픈빌더 스킬 URL: https://<프로젝트>.supabase.co/functions/v1/kakao-attendance?key=<KAKAO_SKILL_SECRET>
// DB 쪽은 supabase/migrate-027.sql 이 먼저 실행되어 있어야 함.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SKILL_SECRET = Deno.env.get("KAKAO_SKILL_SECRET") || "";

const HOW_TO_LINK =
  "처음 한 번만 본인 확인이 필요해요.\n" +
  "아래처럼 [반 번호 이름 확인코드]를 보내 주세요.\n\n" +
  "예) 3-2 15 홍길동 1234\n\n" +
  "확인코드 4자리는 담임선생님께 받을 수 있어요.";

const QUICK = [
  { label: "현체 며칠 썼어?", action: "message", messageText: "현체 며칠 썼어?" },
];

function reply(text: string, quick = true) {
  return new Response(
    JSON.stringify({
      version: "2.0",
      template: { outputs: [{ simpleText: { text } }], ...(quick ? { quickReplies: QUICK } : {}) },
    }),
    { headers: { "Content-Type": "application/json; charset=utf-8" } },
  );
}

async function rpc(fn: string, args: Record<string, unknown>) {
  const headers: Record<string, string> = { apikey: SERVICE_KEY, "Content-Type": "application/json" };
  if (SERVICE_KEY.startsWith("eyJ")) headers.Authorization = `Bearer ${SERVICE_KEY}`;
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: "POST", headers, body: JSON.stringify(args) });
  if (!r.ok) throw new Error(`${fn} ${r.status}: ${await r.text()}`);
  return r.json();
}

const fmtDays = (n: number) => (Number.isInteger(+n) ? String(+n) : (+n).toFixed(1));
const md = (d: string) => {
  const dt = new Date(d + "T00:00:00Z");
  return `${dt.getUTCMonth() + 1}/${dt.getUTCDate()}(${"일월화수목금토"[dt.getUTCDay()]})`;
};

type Trip = { start: string | null; end: string | null; days: number; half: boolean; source: string; report: string | null };

function summary(s: any): string {
  const used = +s.used, limit = +s.limit;
  const left = Math.max(0, limit - used);
  const lines = [
    `${s.label} ${s.no}번 ${s.name} · ${s.ay}학년도`,
    `교외체험학습 ${fmtDays(used)}일 사용 / ${limit}일`,
    `남은 일수: ${fmtDays(left)}일`,
  ];
  const trips: Trip[] = s.trips || [];
  if (trips.length) {
    lines.push("");
    trips.forEach((t, i) => {
      const when = !t.start ? "이전 기록" : t.start === t.end ? md(t.start) : `${md(t.start)}~${md(t.end!)}`;
      const status =
        t.start && t.start > s.today ? "예정"
        : t.report === "done" ? "보고서 제출"
        : t.report === "ongoing" ? "진행 중"
        : t.report === "missing" ? "보고서 미제출"
        : "";
      lines.push(`${i + 1}) ${when} · ${fmtDays(t.days)}일${t.half ? "(일부 교시)" : ""}${status ? " · " + status : ""}`);
    });
  } else {
    lines.push("", "이번 학년도에 등록된 체험학습이 없어요.");
  }
  if (trips.some((t) => t.report === "missing")) lines.push("", "보고서는 담임선생님께 제출해 주세요.");
  lines.push("", "기록이 다르면 담임선생님께 말씀해 주세요.");
  return lines.join("\n");
}

// "3-2 15 홍길동 1234" / "3학년 2반 15번 홍길동 1234"
const LINK_RE = /(\d)\s*(?:-|학년)\s*(\d{1,2})\s*반?\s*(\d{1,2})\s*번?\s*([가-힣]{2,6})\s*(\d{4})/;

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (!SKILL_SECRET || url.searchParams.get("key") !== SKILL_SECRET) return new Response("forbidden", { status: 403 });
  if (req.method !== "POST") return new Response("ok");

  let body: any;
  try { body = await req.json(); } catch { return reply("요청을 읽지 못했어요."); }
  const uid: string = body?.userRequest?.user?.id || "";
  const text: string = String(body?.userRequest?.utterance || "").replace(/\s+/g, " ").trim();
  if (!uid) return reply("카카오 사용자 정보를 받지 못했어요.");

  try {
    if (/연결\s*해제|로그아웃/.test(text)) {
      await rpc("kakao_unlink", { p_uid: uid });
      return reply("연결을 해제했어요.\n\n" + HOW_TO_LINK, false);
    }

    const m = text.match(LINK_RE);
    if (m) {
      const r = await rpc("kakao_link_student", {
        p_uid: uid, p_label: `${m[1]}-${+m[2]}`, p_no: +m[3], p_name: m[4], p_code: m[5],
      });
      if (!r.ok) {
        return reply(r.reason === "locked"
          ? "확인에 여러 번 실패해서 오늘은 더 시도할 수 없어요. 내일 다시 해 주세요."
          : "반·번호·이름·확인코드가 맞지 않아요. 다시 확인해 주세요.\n\n예) 3-2 15 홍길동 1234", false);
      }
      const s = await rpc("kakao_trip_status", { p_uid: uid });
      return reply(`${r.label} ${r.no}번 ${r.name} 학생으로 연결했어요.\n다음부터는 그냥 물어보면 돼요.\n\n` + summary(s));
    }

    const s = await rpc("kakao_trip_status", { p_uid: uid });
    if (!s.linked) {
      return reply((s.reset ? "학생 명단이 바뀌어서 다시 확인이 필요해요.\n\n" : "") + HOW_TO_LINK, false);
    }
    return reply(summary(s));
  } catch (e) {
    console.error(e);
    return reply("지금은 기록을 불러오지 못했어요. 잠시 후 다시 물어봐 주세요.");
  }
});
