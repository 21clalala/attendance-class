-- =====================================================================
-- 변경 025: 체험학습 보고서를 회차 단위로 [제출처리] 했으면 08:00 알림에서 뺌
--  · 지금까지는 날짜마다 제출 기록(doc_submit)이 있어야 알림에서 빠졌음
--    → 나이스 업로드로만 들어온 날, 비고가 "…미제출"(보고서 글자 없음)인 날은
--      회차를 제출 처리해도 기록이 안 생겨 알림이 계속 감
--  · 이제 회차에 보고서 제출(trip.report_at)이 있으면 그 기간의 보고서 줄은 알림 제외
--    (관리자 화면 [증빙서류]와 같은 기준)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
create or replace function send_doc_alerts() returns int
language plpgsql security definer set search_path = public as $$
declare
  c classes; v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_lines text[]; v_cnt int; v_sent int := 0;
begin
  for c in select * from classes where coalesce(ntfy_topic, '') <> '' loop
    if not exists (select 1 from schedule_for(c.id, v_today)) then continue; end if;
    with l as (
      select x.*, t.id trip_id
        from doc_list_raw(c.id, v_today - 180, v_today - 1) x
        left join lateral (
          select t.id, t.report_at from trip t
           where t.class_id = c.id and t.start_d is not null and t.student_no = x.student_no
             and x.doc = '보고서' and x.d between t.start_d and t.end_d
           order by t.id limit 1) t on true
       where not x.submitted
         and t.report_at is null
    ), g as (
      select min(d) d1, max(d) d2, student_no, max(name) name, doc, min(kind) kind, min(note) note, min(elapsed) elapsed
        from l group by coalesce(trip_id::text, d::text || ':' || student_no), student_no, doc
    )
    select array_agg(format('%s %s번 %s · %s · %s · %s일 경과',
                            case when d1 = d2 then to_char(d1, 'FMMM/FMDD') else to_char(d1, 'FMMM/FMDD') || '~' || to_char(d2, 'FMMM/FMDD') end,
                            student_no, coalesce(name, ''), doc, doc_label(kind, note), elapsed) order by d1, student_no),
           count(*)
      into v_lines, v_cnt
      from g where elapsed >= 1;
    if coalesce(v_cnt, 0) = 0 then continue; end if;
    perform notify_ntfy(c.ntfy_topic, c.label || ' 증빙서류 미제출 ' || v_cnt || '건',
                        array_to_string(v_lines, E'\n'), 3, array['page_facing_up']);
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end $$;
revoke execute on function send_doc_alerts() from public, anon, authenticated;
