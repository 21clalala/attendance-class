-- =====================================================================
-- 변경 007: 컴시간알리미 연동
--  · GitHub Actions 가 컴시간 시간표(이번 주·다음 주, 교체 반영)를 받아 comci_slot 에 저장
--  · 선생님 결정 순서: 직접 입력한 교체·대강 > 컴시간 > 직접 입력한 기본 시간표
--  · 컴시간 선생님 번호 → 실명 은 관리자 페이지 [컴시간] 탭에서 한 번 입력
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

create table if not exists comci_config (
  id           int primary key default 1 check (id = 1),
  school_name  text,
  school_code  int,
  enabled      boolean not null default true,
  last_run_at  timestamptz,
  last_ok      boolean,
  last_message text
);
insert into comci_config(id) values (1) on conflict do nothing;

create table if not exists comci_teacher (       -- 컴시간 선생님 번호 → 이름
  idx        int primary key,
  web_name   text,                                -- 컴시간 웹에 보이는 이름(가려졌을 수 있음)
  name       text,                                -- 관리자가 입력한 실명 (있으면 이것을 사용)
  subjects   text,
  updated_at timestamptz not null default now()
);

create table if not exists comci_slot (          -- 날짜·반·교시별 컴시간 수업
  label       text not null,                      -- '3-2'
  d           date not null,
  period      int  not null,
  subject     text,
  teacher_idx int,
  changed     boolean not null default false,     -- 교체된 수업
  synced_at   timestamptz not null default now(),
  primary key (label, d, period)
);
create index if not exists comci_slot_d on comci_slot (d);

-- '3학년 2반', '3-2', '3 - 02' → '3-2'
create or replace function norm_label(p text) returns text
language sql immutable as $$
  select case when p ~ '\d+\D+\d+'
              then (regexp_match(p, '(\d+)\D+(\d+)'))[1]::int || '-' || (regexp_match(p, '(\d+)\D+(\d+)'))[2]::int
              else trim(p) end
$$;

create or replace function comci_name(p_idx int) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(name), ''), nullif(trim(web_name), '')) from comci_teacher where idx = p_idx
$$;

-- 교체·대강을 뺀 기본 선생님 (컴시간 자료가 있는 날은 컴시간, 없으면 직접 입력한 시간표)
create or replace function teacher_base(p_class int, p_d date, p_period int) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_label text; v_idx int; v_found boolean;
begin
  select norm_label(label) into v_label from classes where id = p_class;
  if exists (select 1 from comci_config where enabled)
     and exists (select 1 from comci_slot where label = v_label and d = p_d) then
    select teacher_idx, true into v_idx, v_found from comci_slot where label = v_label and d = p_d and period = p_period;
    if v_found and v_idx is not null then return comci_name(v_idx); end if;
    return null;                                   -- 컴시간에 그 교시 수업 없음
  end if;
  return (select teacher from timetable where class_id = p_class and weekday = extract(isodow from p_d)::int and period = p_period);
end $$;

create or replace function teacher_for(p_class int, p_d date, p_period int) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select teacher from teacher_override where class_id = p_class and d = p_d and period = p_period),
    teacher_base(p_class, p_d, p_period))
$$;

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


drop function if exists admin_schedule(int, date);
create or replace function admin_schedule(p_class int, p_d date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_label text;
begin
  if not can_manage(p_class) then raise exception 'not_admin'; end if;
  select norm_label(label) into v_label from classes where id = p_class;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'period',  s.period,
             'start',   to_char(s.start_t, 'HH24:MI'),
             'end',     to_char(s.end_t,   'HH24:MI'),
             'teacher', teacher_for(p_class, p_d, s.period),
             'base',    teacher_base(p_class, p_d, s.period),
             'subject', cs.subject,
             'changed', coalesce(cs.changed, false),
             'source',  case when exists (select 1 from comci_slot where label = v_label and d = p_d)
                                  and (select enabled from comci_config) then 'comci' else 'manual' end
           ) order by s.period)
      from schedule_for(p_d) s
      left join comci_slot cs on cs.label = v_label and cs.d = p_d and cs.period = s.period), '[]'::jsonb);
end $$;

-- 한 반의 컴시간 주간표 (관리자 화면용)
create or replace function admin_comci_week(p_class int, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_manage(p_class) then raise exception 'not_admin'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('d', s.d, 'period', s.period, 'subject', s.subject,
                                        'teacher', comci_name(s.teacher_idx), 'idx', s.teacher_idx,
                                        'changed', s.changed) order by s.d, s.period)
      from comci_slot s join classes c on norm_label(c.label) = s.label
     where c.id = p_class and s.d between p_from and p_to), '[]'::jsonb);
end $$;

-- 권한
revoke all on comci_config, comci_teacher, comci_slot from anon;
revoke execute on function teacher_base(int,date,int), comci_name(int) from public, anon, authenticated;
revoke execute on function admin_comci_week(int,date,date), admin_schedule(int,date) from public, anon;
grant  execute on function admin_comci_week(int,date,date), admin_schedule(int,date) to authenticated;
grant  execute on function get_today(text) to anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['comci_config','comci_teacher','comci_slot'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists common_read on %I', t);
    execute format('drop policy if exists common_write on %I', t);
    execute format('create policy common_read on %I for select to authenticated using (is_admin())', t);
    execute format('create policy common_write on %I for all to authenticated using (is_super()) with check (is_super())', t);
  end loop;
end $$;
