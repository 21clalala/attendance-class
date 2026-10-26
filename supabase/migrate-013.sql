-- =====================================================================
-- 변경 013: 조회 시간(기본 08:00~08:50) — 담임이 교실 QR로 조회 출결 입력
--  · 수업이 있는 날, 담임 이름이 있는 반에만 열림
--  · 저장하면 담임 직접 입력(homeroom_marks)으로 들어가고 알림은 보내지 않음
--  · 시각은 config 의 morning_start / morning_end (관리자 페이지 [시간표·시정]에서 변경)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

insert into config(key, value) values ('morning_start', '08:00'), ('morning_end', '08:50') on conflict (key) do nothing;

create or replace function morning_window() returns table(s time, e time)
language sql stable security definer set search_path = public as $$
  select coalesce((select value from config where key = 'morning_start'), '08:00')::time,
         coalesce((select value from config where key = 'morning_end'),   '08:50')::time
$$;

create or replace function in_morning(p_class int, p_now timestamp) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from morning_window() mw where p_now::time >= mw.s and p_now::time < mw.e)
     and exists (select 1 from classes where id = p_class and nullif(trim(homeroom), '') is not null)
     and exists (select 1 from schedule_for(p_class, p_now::date))
$$;

revoke execute on function morning_window(), in_morning(int,timestamp) from public, anon, authenticated;
grant execute on function morning_window() to authenticated;   -- 관리자 페이지 타임라인 표시용

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
    'marks', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'period', period, 'kind', kind))
          from teacher_marks where class_id = c.id and d = v_d), '[]'::jsonb)
  );
end $$;






create or replace function save_marks(p_key text, p_period int, p_teacher text, p_absent int[], p_present int[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  c         classes   := class_by_key(p_key);
  v_now     timestamp := kst_now();
  v_d       date      := v_now::date;
  v_period  int;
  v_teacher text;
  r         record;
  v_neis    boolean;
  n_abs     text[] := '{}';
  n_pre     text[] := '{}';
  c_pre     text[] := '{}';
  c_abs     text[] := '{}';
  v_parts   text[] := '{}';
  v_body    text[] := '{}';
  v_cnt     int;
begin
  v_period := coalesce(case when in_morning(c.id, v_now) then 0 end, current_period(c.id, v_now));
  if v_period is null then raise exception 'not_in_class'; end if;
  if p_period is distinct from v_period then raise exception 'period_changed'; end if;

  -- 조회 시간: 담임이 QR로 입력 → 담임 입력(homeroom_marks)으로 저장, 알림 없음
  if v_period = 0 then
    v_teacher := nullif(trim(c.homeroom), '');
    if v_teacher is null then raise exception 'no_teacher'; end if;
    if p_teacher is distinct from v_teacher then raise exception 'not_your_period'; end if;
    for r in select s.no from students s
              where s.class_id = c.id and s.no = any(coalesce(p_absent, '{}')) and not s.excluded loop
      if not base_absent(c.id, v_d, r.no, '조회') then
        if exists (select 1 from neis_marks where class_id = c.id and d = v_d and student_no = r.no and slot = '조회')
          then delete from homeroom_marks where class_id = c.id and d = v_d and student_no = r.no and slot = '조회';
          else insert into homeroom_marks(class_id, d, student_no, slot, state, by_email) values (c.id, v_d, r.no, '조회', 'absent', 'QR')
               on conflict (class_id, d, student_no, slot) do update set state = 'absent', by_email = 'QR', at = now();
        end if;
        insert into mark_log(class_id, d, period, slot, student_no, action, teacher, before, after, by_email)
        values (c.id, v_d, null, '조회', r.no, 'hr_set', v_teacher, 'none', 'absent', 'QR');
        n_abs := n_abs || r.no::text;
      end if;
    end loop;
    for r in select s.no from students s
              where s.class_id = c.id and s.no = any(coalesce(p_present, '{}')) and not s.excluded loop
      if base_absent(c.id, v_d, r.no, '조회') then
        if exists (select 1 from neis_marks where class_id = c.id and d = v_d and student_no = r.no and slot = '조회')
          then insert into homeroom_marks(class_id, d, student_no, slot, state, by_email) values (c.id, v_d, r.no, '조회', 'present', 'QR')
               on conflict (class_id, d, student_no, slot) do update set state = 'present', by_email = 'QR', at = now();
          else delete from homeroom_marks where class_id = c.id and d = v_d and student_no = r.no and slot = '조회';
        end if;
        insert into mark_log(class_id, d, period, slot, student_no, action, teacher, before, after, by_email)
        values (c.id, v_d, null, '조회', r.no, 'hr_set', v_teacher, 'absent', 'present', 'QR');
        n_pre := n_pre || r.no::text;
      end if;
    end loop;
    if cardinality(n_abs) + cardinality(n_pre) = 0 then
      insert into mark_log(class_id, d, period, slot, student_no, action, teacher, by_email)
      values (c.id, v_d, null, '조회', 0, 'check', v_teacher, 'QR');
    end if;
    return jsonb_build_object('period', 0, 'absent', cardinality(n_abs), 'present', cardinality(n_pre), 'corrected', 0, 'quiet', true);
  end if;
  v_teacher := teacher_for(c.id, v_d, v_period);
  if v_teacher is null then raise exception 'no_teacher'; end if;
  if p_teacher is distinct from v_teacher then raise exception 'not_your_period'; end if;

  for r in select s.no, s.name from students s
            where s.class_id = c.id and s.no = any(coalesce(p_absent, '{}')) and not s.excluded order by s.no loop
    v_neis := base_absent(c.id, v_d, r.no, v_period::text);
    if v_neis then
      delete from teacher_marks where class_id = c.id and d = v_d and period = v_period and student_no = r.no and kind = 'present';
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        c_abs := c_abs || (r.no || '번 ' || r.name);
        insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, r.no, 'unpresent', v_teacher);
      end if;
    else
      insert into teacher_marks(class_id, d, period, student_no, teacher, kind) values (c.id, v_d, v_period, r.no, v_teacher, 'absent')
      on conflict do nothing;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        n_abs := n_abs || (r.no || '번 ' || r.name);
        insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, r.no, 'add', v_teacher);
      end if;
    end if;
  end loop;

  for r in select s.no, s.name from students s
            where s.class_id = c.id and s.no = any(coalesce(p_present, '{}')) and not s.excluded order by s.no loop
    v_neis := base_absent(c.id, v_d, r.no, v_period::text);
    if v_neis then
      insert into teacher_marks(class_id, d, period, student_no, teacher, kind) values (c.id, v_d, v_period, r.no, v_teacher, 'present')
      on conflict do nothing;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        n_pre := n_pre || (r.no || '번 ' || r.name);
        insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, r.no, 'present', v_teacher);
      end if;
    else
      delete from teacher_marks where class_id = c.id and d = v_d and period = v_period and student_no = r.no and kind = 'absent';
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        c_pre := c_pre || (r.no || '번 ' || r.name);
        insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, r.no, 'remove', v_teacher);
      end if;
    end if;
  end loop;

  if cardinality(n_abs) + cardinality(n_pre) + cardinality(c_pre) + cardinality(c_abs) = 0 then
    insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, 0, 'check', v_teacher);
  else
    if cardinality(n_abs) > 0 then
      v_parts := v_parts || ('없음 ' || cardinality(n_abs) || '명');
      v_body  := v_body  || ('없음: ' || array_to_string(n_abs, ', '));
    end if;
    if cardinality(n_pre) > 0 then
      v_parts := v_parts || ('출석 확인 ' || cardinality(n_pre) || '명');
      v_body  := v_body  || ('출석 확인(미리 표시된 / 해제): ' || array_to_string(n_pre, ', '));
    end if;
    if cardinality(c_pre) + cardinality(c_abs) > 0 then
      v_parts := v_parts || ('정정 ' || (cardinality(c_pre) + cardinality(c_abs)) || '명');
      if cardinality(c_pre) > 0 then v_body := v_body || ('정정 → 출석: ' || array_to_string(c_pre, ', ')); end if;
      if cardinality(c_abs) > 0 then v_body := v_body || ('정정 → 다시 없음: ' || array_to_string(c_abs, ', ')); end if;
    end if;
    v_body := v_body || (v_teacher || ' 선생님 · ' || to_char(v_now, 'HH24:MI'));
    perform notify_ntfy(c.ntfy_topic,
      format('%s %s교시 · %s', c.label, v_period, array_to_string(v_parts, ' · ')),
      array_to_string(v_body, E'\n'),
      case when cardinality(n_abs) > 0 then 5 else 4 end,
      case when cardinality(n_abs) > 0 then array['rotating_light'] else array['pencil2'] end);
  end if;

  return jsonb_build_object('period', v_period,
    'absent', cardinality(n_abs), 'present', cardinality(n_pre),
    'corrected', cardinality(c_pre) + cardinality(c_abs));
end $$;




grant execute on function get_today(text), save_marks(text,int,text,int[],int[]) to anon, authenticated;
