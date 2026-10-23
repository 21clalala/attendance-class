-- =====================================================================
-- 변경 010: 담임 시간 (기본: 금요일 5·6교시는 담임 선생님)
--  · 반마다 담임 이름(classes.homeroom), 학교 공통 담임 시간(homeroom_slot)
--  · 선생님 결정 순서: 직접 입력한 교체·대강 > 컴시간 교체 수업 > 담임 시간 > 컴시간 > 직접 입력한 시간표
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

alter table classes add column if not exists homeroom text;

create table if not exists homeroom_slot (
  weekday int not null check (weekday between 1 and 7),
  period  int not null check (period between 1 and 12),
  primary key (weekday, period)
);
do $$
begin
  if not exists (select 1 from homeroom_slot) then   -- 처음 만들 때만 기본값(금 5·6교시)
    insert into homeroom_slot values (5, 5), (5, 6);
  end if;
end $$;

alter table homeroom_slot enable row level security;
drop policy if exists common_read on homeroom_slot;
drop policy if exists common_write on homeroom_slot;
create policy common_read on homeroom_slot for select to authenticated using (is_admin());
create policy common_write on homeroom_slot for all to authenticated using (is_super()) with check (is_super());
revoke all on homeroom_slot from anon;

-- 이 교시가 담임 시간인가 (담임 이름이 있을 때만)
create or replace function homeroom_for(p_class int, p_d date, p_period int) returns text
language sql stable security definer set search_path = public as $$
  select nullif(trim(c.homeroom), '') from classes c
   where c.id = p_class
     and exists (select 1 from homeroom_slot h where h.weekday = extract(isodow from p_d)::int and h.period = p_period)
$$;

create or replace function teacher_base(p_class int, p_d date, p_period int) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_label text; v_home text; v_idx int; v_chg boolean; v_found boolean := false;
begin
  select norm_label(label) into v_label from classes where id = p_class;
  v_home := homeroom_for(p_class, p_d, p_period);
  if exists (select 1 from comci_config where enabled)
     and exists (select 1 from comci_slot where label = v_label and d = p_d) then
    select teacher_idx, changed, true into v_idx, v_chg, v_found
      from comci_slot where label = v_label and d = p_d and period = p_period;
    if v_home is not null and not coalesce(v_chg, false) then return v_home; end if;   -- 담임 시간
    if v_found and v_idx is not null then return comci_name(v_idx); end if;
    return v_home;                                                                     -- 컴시간에 수업 없음
  end if;
  if v_home is not null then return v_home; end if;
  return (select teacher from timetable where class_id = p_class and weekday = extract(isodow from p_d)::int and period = p_period);
end $$;

create or replace function get_today(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        classes := class_by_key(p_key);
  v_now    timestamp := kst_now();
  v_d      date      := v_now::date;
  v_period int       := current_period(v_now);
  v_next   jsonb;
begin
  select jsonb_build_object('period', s.period, 'start', to_char(s.start_t, 'HH24:MI'))
    into v_next
    from schedule_for(v_d) s
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
          from schedule_for(v_d) s), '[]'::jsonb),
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
      from schedule_for(p_d) s
      left join comci_slot cs on cs.label = v_label and cs.d = p_d and cs.period = s.period), '[]'::jsonb);
end $$;

revoke execute on function homeroom_for(int,date,int) from public, anon, authenticated;
grant  execute on function get_today(text) to anon, authenticated;
grant  execute on function admin_schedule(int,date) to authenticated;
