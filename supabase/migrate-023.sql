-- =====================================================================
-- 변경 023: 교과선생님 출결 화면에 담임이 입력한 "마감"(종류만) 표시
--  · get_today 에 days: [{no, kind}] 추가 — 사유(비고)는 보내지 않음
--  · 담임 입력(day_manual)이 있으면 그것, 없으면 업로드한 나이스 마감(neis_day)
--  · QR·주소는 그대로
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
create or replace function get_today(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        classes := class_by_key(p_key);
  v_now    timestamp := kst_now();
  v_d      date      := v_now::date;
  v_period int       := coalesce(case when in_morning(c.id, v_now) then 0 end, current_period(c.id, v_now));
  v_next   jsonb;
begin
  select jsonb_build_object('period', s.period, 'start', to_char(s.start_t, 'HH24:MI'))
    into v_next
    from schedule_for(c.id, v_d) s
   where s.start_t > v_now::time
   order by s.start_t limit 1;

  return jsonb_build_object(
    'date',    v_d,
    'now',     to_char(v_now, 'HH24:MI'),
    'label',   c.label,
    'period',  v_period,
    'teacher', case when v_period is null then null when v_period = 0 then nullif(trim(c.homeroom), '') else teacher_for(c.id, v_d, v_period) end,
    'slot',    case when v_period = 0 then '조회' else v_period::text end,
    'next',    v_next,
    'teachers', coalesce((
        select jsonb_agg(t order by t) from (
          select teacher as t from timetable where class_id = c.id
          union select teacher from teacher_override where class_id = c.id and d >= v_d - 7
          union select nullif(trim(c.homeroom), '')
          union select comci_name(s.teacher_idx) from comci_slot s
                 where s.label = norm_label(c.label) and s.d between v_d - 7 and v_d + 14 and s.teacher_idx is not null) x
          where t is not null and t <> ''), '[]'::jsonb),
    'schedule', (select coalesce(jsonb_agg(jsonb_build_object('period', 0, 'label', '조회', 'start', to_char(mw.s, 'HH24:MI'),
                                               'end', to_char(mw.e, 'HH24:MI'), 'teacher', nullif(trim(c.homeroom), ''))), '[]'::jsonb)
                   from morning_window() mw
                  where nullif(trim(c.homeroom), '') is not null and exists (select 1 from schedule_for(c.id, v_d)))
              || coalesce((
        select jsonb_agg(jsonb_build_object(
                 'period', s.period,
                 'start',  to_char(s.start_t, 'HH24:MI'),
                 'end',    to_char(s.end_t,   'HH24:MI'),
                 'teacher', teacher_for(c.id, v_d, s.period)) order by s.period)
          from schedule_for(c.id, v_d) s), '[]'::jsonb),
    'students', coalesce((
        select jsonb_agg(jsonb_build_object('no', no, 'name', name, 'excluded', excluded, 'tag', tag) order by no)
          from students where class_id = c.id), '[]'::jsonb),
    'neis', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'slot', slot))
          from (select student_no, slot from neis_marks where class_id = c.id and d = v_d
                union select student_no, slot from homeroom_marks where class_id = c.id and d = v_d and state = 'absent'
                except select student_no, slot from homeroom_marks where class_id = c.id and d = v_d and state = 'present') b), '[]'::jsonb),
    'days', coalesce((
        select jsonb_agg(jsonb_build_object('no', x.no, 'kind', x.kind) order by x.no)
          from (select coalesce(m.student_no, n.student_no) no,
                       case when m.student_no is not null then m.kind else n.kind end kind
                  from (select * from day_manual where class_id = c.id and d = v_d) m
                  full join (select * from neis_day where class_id = c.id and d = v_d) n
                    on n.student_no = m.student_no) x
         where coalesce(trim(x.kind), '') <> ''), '[]'::jsonb),
    'marks', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'period', period, 'kind', kind))
          from teacher_marks where class_id = c.id and d = v_d), '[]'::jsonb)
  );
end $$;

grant execute on function get_today(text) to anon, authenticated;
