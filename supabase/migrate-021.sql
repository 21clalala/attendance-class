-- =====================================================================
-- 변경 021: 08:00 알림의 체험학습 보고서 묶음을 "앱 등록 + 이전 기록" 회차 기준으로
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
-- 아침 알림: 체험학습 보고서는 회차로 묶어서 한 줄
create or replace function send_doc_alerts() returns int
language plpgsql security definer set search_path = public as $$
declare
  c classes; v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_lines text[]; v_cnt int; v_sent int := 0;
begin
  for c in select * from classes where coalesce(ntfy_topic, '') <> '' loop
    if not exists (select 1 from schedule_for(c.id, v_today)) then continue; end if;
    with l as (
      select x.*, (select t.id from trip t
                    where t.class_id = c.id and t.start_d is not null and t.student_no = x.student_no
                      and x.doc = '보고서' and x.d between t.start_d and t.end_d limit 1) trip_id
        from doc_list_raw(c.id, v_today - 180, v_today - 1) x
       where not x.submitted
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
