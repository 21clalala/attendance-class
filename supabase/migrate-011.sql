-- =====================================================================
-- 변경 011: 반별 날짜 시정(단축수업 등)
--  · 담임이 [날짜별 변경]에서 수업 시각을 바꾸면 그 반에만 적용
--  · 우선순위: 반별 날짜 시정 > 학교 전체 날짜 시정 > 기본 시정표
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

create table if not exists class_day_schedule (
  class_id int  not null references classes(id) on delete cascade,
  d        date not null,
  periods  jsonb not null default '[]',      -- [{"p":1,"s":"08:50","e":"09:30"}, …]  빈 배열 = 이 반 수업 없음
  primary key (class_id, d)
);
alter table class_day_schedule enable row level security;
drop policy if exists class_rw on class_day_schedule;
create policy class_rw on class_day_schedule for all to authenticated using (can_manage(class_id)) with check (can_manage(class_id));
revoke all on class_day_schedule from anon;

create or replace function schedule_for(p_class int, p_d date)
returns table(period int, start_t time, end_t time)
language plpgsql stable security definer set search_path = public as $$
begin
  if exists (select 1 from class_day_schedule where class_id = p_class and d = p_d) then
    return query
      select (x->>'p')::int, (x->>'s')::time, (x->>'e')::time
        from class_day_schedule cds, jsonb_array_elements(cds.periods) x
       where cds.class_id = p_class and cds.d = p_d
       order by 1;
  else
    return query select * from schedule_for(p_d);
  end if;
end $$;

create or replace function current_period(p_class int, p_now timestamp) returns int
language sql stable security definer set search_path = public as $$
  select period from schedule_for(p_class, p_now::date)
   where p_now::time >= start_t and p_now::time < end_t
   order by period limit 1
$$;

create or replace function get_today(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        classes := class_by_key(p_key);
  v_now    timestamp := kst_now();
  v_d      date      := v_now::date;
  v_period int       := current_period(c.id, v_now);
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
    'teacher', case when v_period is null then null else teacher_for(c.id, v_d, v_period) end,
    'next',    v_next,
    'teachers', coalesce((
        select jsonb_agg(t order by t) from (
          select teacher as t from timetable where class_id = c.id
          union select teacher from teacher_override where class_id = c.id and d >= v_d - 7
          union select nullif(trim(c.homeroom), '')
          union select comci_name(s.teacher_idx) from comci_slot s
                 where s.label = norm_label(c.label) and s.d between v_d - 7 and v_d + 14 and s.teacher_idx is not null) x
          where t is not null and t <> ''), '[]'::jsonb),
    'schedule', coalesce((
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
          from neis_marks where class_id = c.id and d = v_d), '[]'::jsonb),
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
  v_period := current_period(c.id, v_now);
  if v_period is null then raise exception 'not_in_class'; end if;
  if p_period is distinct from v_period then raise exception 'period_changed'; end if;
  v_teacher := teacher_for(c.id, v_d, v_period);
  if v_teacher is null then raise exception 'no_teacher'; end if;
  if p_teacher is distinct from v_teacher then raise exception 'not_your_period'; end if;

  for r in select s.no, s.name from students s
            where s.class_id = c.id and s.no = any(coalesce(p_absent, '{}')) and not s.excluded order by s.no loop
    v_neis := exists (select 1 from neis_marks n where n.class_id = c.id and n.d = v_d and n.student_no = r.no and n.slot = v_period::text);
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
    v_neis := exists (select 1 from neis_marks n where n.class_id = c.id and n.d = v_d and n.student_no = r.no and n.slot = v_period::text);
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
      v_body  := v_body  || ('출석 확인(나이스 / 해제): ' || array_to_string(n_pre, ', '));
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


create or replace function admin_schedule(p_class int, p_d date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_label text; v_comci boolean;
begin
  if not can_manage(p_class) then raise exception 'not_admin'; end if;
  select norm_label(label) into v_label from classes where id = p_class;
  v_comci := (select enabled from comci_config where id = 1) and exists (select 1 from comci_slot where label = v_label and d = p_d);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'period',  s.period,
             'start',   to_char(s.start_t, 'HH24:MI'),
             'end',     to_char(s.end_t,   'HH24:MI'),
             'teacher', teacher_for(p_class, p_d, s.period),
             'base',    teacher_base(p_class, p_d, s.period),
             'subject', cs.subject,
             'changed', coalesce(cs.changed, false),
             'source',  case when homeroom_for(p_class, p_d, s.period) is not null and not coalesce(cs.changed, false) then 'homeroom'
                             when v_comci then 'comci' else 'manual' end
           ) order by s.period)
      from schedule_for(p_class, p_d) s
      left join comci_slot cs on cs.label = v_label and cs.d = p_d and cs.period = s.period), '[]'::jsonb);
end $$;


revoke execute on function schedule_for(int,date), current_period(int,timestamp) from public, anon, authenticated;
grant  execute on function get_today(text), save_marks(text,int,text,int[],int[]) to anon, authenticated;
grant  execute on function admin_schedule(int,date) to authenticated;
