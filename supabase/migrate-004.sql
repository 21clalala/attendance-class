-- =====================================================================
-- 변경 004: 학생 표시(예: 자습반) — 명단에서 이름 뒤에 (자습반) 처럼 적으면 교과선생님 화면에 표시
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
alter table students add column if not exists tag text;

create or replace function get_today(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_now    timestamp := kst_now();
  v_d      date      := v_now::date;
  v_period int;
  v_next   jsonb;
begin
  perform check_key(p_key);
  v_period := current_period(v_now);

  select jsonb_build_object('period', s.period, 'start', to_char(s.start_t, 'HH24:MI'))
    into v_next
    from schedule_for(v_d) s
   where s.start_t > v_now::time
   order by s.start_t limit 1;

  return jsonb_build_object(
    'date',    v_d,
    'now',     to_char(v_now, 'HH24:MI'),
    'label',   (select value from config where key = 'class_label'),
    'period',  v_period,
    'teacher', case when v_period is null then null else teacher_for(v_d, v_period) end,
    'next',    v_next,
    'schedule', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'period', s.period,
                 'start',  to_char(s.start_t, 'HH24:MI'),
                 'end',    to_char(s.end_t,   'HH24:MI'),
                 'teacher', teacher_for(v_d, s.period)) order by s.period)
          from schedule_for(v_d) s), '[]'::jsonb),
    'students', coalesce((
        select jsonb_agg(jsonb_build_object('no', no, 'name', name, 'excluded', excluded, 'tag', tag) order by no)
          from students), '[]'::jsonb),
    'neis', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'slot', slot))
          from neis_marks where d = v_d), '[]'::jsonb),
    'marks', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'period', period, 'kind', kind))
          from teacher_marks where d = v_d), '[]'::jsonb)
  );
end $$;

grant execute on function get_today(text) to anon, authenticated;
