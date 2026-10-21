-- =====================================================================
-- 3-2 수업 출결 체크 — Supabase 스키마
-- Supabase 대시보드 → SQL Editor 에 전체를 붙여 넣고 Run.
-- 맨 아래 "관리자 이메일" 한 줄만 본인 이메일로 바꾸세요.
-- =====================================================================

create extension if not exists pg_net;

-- ---------- 테이블 ----------
create table if not exists config (
  key   text primary key,
  value text not null
);

create table if not exists admins (
  email text primary key
);

create table if not exists students (
  no       int primary key,
  name     text not null,
  excluded boolean not null default false      -- (위탁) 등: 입력·알림 제외
);

create table if not exists bell_default (           -- 기본 시정표
  period  int primary key check (period between 1 and 9),
  start_t time not null,
  end_t   time not null
);

create table if not exists weekday_max (            -- 요일별 마지막 교시 (1=월 … 5=금)
  weekday    int primary key check (weekday between 1 and 7),
  max_period int not null check (max_period between 0 and 9)
);

create table if not exists timetable (              -- 기본 시간표: 요일 × 교시 → 선생님
  weekday int  not null check (weekday between 1 and 7),
  period  int  not null check (period between 1 and 9),
  teacher text not null,
  primary key (weekday, period)
);

create table if not exists day_schedule (           -- 날짜별 시정 변경 (있으면 그날은 이것만 사용)
  d       date primary key,
  periods jsonb not null default '[]',              -- [{"p":1,"s":"08:50","e":"09:40"}, …]  빈 배열 = 수업 없음
  note    text
);

create table if not exists teacher_override (       -- 날짜별 교체·대강
  d       date not null,
  period  int  not null,
  teacher text not null,
  primary key (d, period)
);

create table if not exists neis_day (               -- 업로드한 나이스 출석부의 마감 유형·비고 (담임만 열람)
  d          date not null,
  student_no int  not null,
  kind       text,
  note       text,
  primary key (d, student_no)
);

create table if not exists neis_marks (             -- 업로드한 나이스 "/" (slot: '조회','1'~'9','종례')
  d          date not null,
  student_no int  not null,
  slot       text not null,
  primary key (d, student_no, slot)
);

create table if not exists teacher_marks (          -- 교과선생님이 새로 찍은 "/"
  d          date not null,
  period     int  not null,
  student_no int  not null,
  teacher    text not null,
  created_at timestamptz not null default now(),
  primary key (d, period, student_no)
);

create table if not exists mark_log (               -- 입력·정정 기록
  id         bigserial primary key,
  d          date not null,
  period     int  not null,
  student_no int  not null,
  action     text not null,                         -- 'add' | 'remove' | 'admin_remove'
  teacher    text,
  at         timestamptz not null default now()
);

-- ---------- 기본값 ----------
insert into config(key, value) values
  ('class_label', '3-2'),
  ('access_key',  replace(gen_random_uuid()::text, '-', '')),
  ('ntfy_topic',  'att32-' || replace(gen_random_uuid()::text, '-', ''))
on conflict (key) do nothing;

insert into bell_default(period, start_t, end_t) values
  (1,'08:50','09:40'), (2,'09:50','10:40'), (3,'10:50','11:40'), (4,'11:50','12:40'),
  (5,'13:40','14:30'), (6,'14:40','15:30'), (7,'15:40','16:30')
on conflict (period) do nothing;

insert into weekday_max(weekday, max_period) values
  (1,7), (2,7), (3,6), (4,6), (5,6)
on conflict (weekday) do nothing;

-- ---------- 내부 함수 ----------
create or replace function kst_now() returns timestamp
language sql stable as $$ select (now() at time zone 'Asia/Seoul') $$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = lower(auth.jwt() ->> 'email'))
$$;

-- 그날의 시정 (날짜별 변경이 있으면 그것, 없으면 기본 시정표 + 요일별 교시 수)
create or replace function schedule_for(p_d date)
returns table(period int, start_t time, end_t time)
language sql stable security definer set search_path = public as $$
  select * from (
    select (x->>'p')::int, (x->>'s')::time, (x->>'e')::time
      from day_schedule ds, jsonb_array_elements(ds.periods) x
     where ds.d = p_d
    union all
    select b.period, b.start_t, b.end_t
      from bell_default b
      join weekday_max w on w.weekday = extract(isodow from p_d)::int
     where b.period <= w.max_period
       and not exists (select 1 from day_schedule where d = p_d)
  ) s order by 1
$$;

create or replace function teacher_for(p_d date, p_period int) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select teacher from teacher_override where d = p_d and period = p_period),
    (select teacher from timetable where weekday = extract(isodow from p_d)::int and period = p_period))
$$;

create or replace function current_period(p_now timestamp) returns int
language sql stable security definer set search_path = public as $$
  select period from schedule_for(p_now::date)
   where p_now::time >= start_t and p_now::time < end_t
   order by period limit 1
$$;

create or replace function check_key(p_key text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_key is null or p_key is distinct from (select value from config where key = 'access_key') then
    raise exception 'invalid_key';
  end if;
end $$;

create or replace function notify_ntfy(p_title text, p_msg text, p_priority int, p_tags text[])
returns void
language plpgsql security definer set search_path = public as $$
declare v_topic text := (select value from config where key = 'ntfy_topic');
begin
  if coalesce(v_topic, '') = '' then return; end if;
  perform net.http_post(
    url     := 'https://ntfy.sh/',
    body    := jsonb_build_object('topic', v_topic, 'title', p_title, 'message', p_msg,
                                  'priority', p_priority, 'tags', to_jsonb(p_tags)),
    headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;

-- ---------- 교과선생님용 공개 함수 (access_key 필요) ----------
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
        select jsonb_agg(jsonb_build_object('no', no, 'name', name, 'excluded', excluded) order by no)
          from students), '[]'::jsonb),
    'neis', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'slot', slot))
          from neis_marks where d = v_d), '[]'::jsonb),
    'marks', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'period', period))
          from teacher_marks where d = v_d), '[]'::jsonb)
  );
end $$;

-- 저장: 현재 교시에 대해 추가/취소를 한 번에 반영하고 알림 1~2건 발송
create or replace function save_marks(p_key text, p_period int, p_add int[], p_remove int[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_now     timestamp := kst_now();
  v_d       date      := v_now::date;
  v_period  int;
  v_teacher text;
  v_label   text := (select value from config where key = 'class_label');
  v_added   text[];
  v_removed text[];
begin
  perform check_key(p_key);
  v_period := current_period(v_now);
  if v_period is null then raise exception 'not_in_class'; end if;
  if p_period is distinct from v_period then raise exception 'period_changed'; end if;
  v_teacher := coalesce(teacher_for(v_d, v_period), '시간표 미등록');

  -- 추가: 위탁 등 제외 학생, 나이스에 이미 "/"가 있는 칸은 무시
  with ins as (
    insert into teacher_marks(d, period, student_no, teacher)
    select v_d, v_period, s.no, v_teacher
      from students s
     where s.no = any(coalesce(p_add, '{}'))
       and not s.excluded
       and not exists (select 1 from neis_marks n
                        where n.d = v_d and n.student_no = s.no and n.slot = v_period::text)
    on conflict do nothing
    returning student_no
  ), lg as (
    insert into mark_log(d, period, student_no, action, teacher)
    select v_d, v_period, student_no, 'add', v_teacher from ins
  )
  select array_agg(i.student_no || '번 ' || s.name order by i.student_no)
    into v_added
    from ins i join students s on s.no = i.student_no;

  -- 취소
  with del as (
    delete from teacher_marks
     where d = v_d and period = v_period and student_no = any(coalesce(p_remove, '{}'))
    returning student_no
  ), lg as (
    insert into mark_log(d, period, student_no, action, teacher)
    select v_d, v_period, student_no, 'remove', v_teacher from del
  )
  select array_agg(x.student_no || '번 ' || coalesce(s.name, '') order by x.student_no)
    into v_removed
    from del x left join students s on s.no = x.student_no;

  if v_added is not null then
    perform notify_ntfy(
      format('%s %s교시 없는 학생 %s명', v_label, v_period, cardinality(v_added)),
      array_to_string(v_added, ', ') || E'\n' || v_teacher || ' 선생님 · ' || to_char(v_now, 'HH24:MI'),
      5, array['rotating_light']);
  end if;
  if v_removed is not null then
    perform notify_ntfy(
      format('%s %s교시 정정 %s명', v_label, v_period, cardinality(v_removed)),
      array_to_string(v_removed, ', ') || ' → 출석으로 정정' || E'\n' || v_teacher || ' 선생님 · ' || to_char(v_now, 'HH24:MI'),
      3, array['pencil2']);
  end if;

  return jsonb_build_object('period', v_period,
                            'added',   coalesce(cardinality(v_added), 0),
                            'removed', coalesce(cardinality(v_removed), 0));
end $$;

-- ---------- 관리자용 함수 ----------
create or replace function admin_test_notify() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  perform notify_ntfy((select value from config where key = 'class_label') || ' 알림 테스트',
                      '출결 알림이 정상적으로 연결되었습니다.', 3, array['white_check_mark']);
end $$;

create or replace function admin_schedule(p_d date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'period', s.period,
             'start',  to_char(s.start_t, 'HH24:MI'),
             'end',    to_char(s.end_t,   'HH24:MI'),
             'teacher', teacher_for(p_d, s.period)) order by s.period)
      from schedule_for(p_d) s), '[]'::jsonb);
end $$;

-- ---------- 권한 ----------
revoke all on all tables in schema public from anon;
revoke execute on function kst_now(), schedule_for(date), teacher_for(date,int), current_period(timestamp),
                           check_key(text), notify_ntfy(text,text,int,text[])
  from public, anon, authenticated;
revoke execute on function admin_test_notify(), admin_schedule(date) from public, anon;
grant  execute on function get_today(text), save_marks(text,int,int[],int[]) to anon, authenticated;
grant  execute on function admin_test_notify(), admin_schedule(date), is_admin() to authenticated;

do $$
declare t text;
begin
  foreach t in array array['config','admins','students','bell_default','weekday_max','timetable',
                           'day_schedule','teacher_override','neis_day','neis_marks','teacher_marks','mark_log']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (is_admin()) with check (is_admin())', t);
  end loop;
end $$;

-- 관리자 화면 실시간 갱신
do $$
begin
  begin execute 'alter publication supabase_realtime add table teacher_marks'; exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table neis_marks';    exception when others then null; end;
end $$;

-- ---------- 관리자 이메일 (본인 이메일로 바꾸기) ----------
insert into admins(email) values ('여기에_관리자_이메일@example.com') on conflict do nothing;


-- ===== 변경 002 (새로 설치할 때도 함께 적용) =====
alter table teacher_marks add column if not exists kind text not null default 'absent';
do $$ begin
  alter table teacher_marks add constraint teacher_marks_kind_chk check (kind in ('absent','present'));
exception when duplicate_object then null; end $$;

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
        select jsonb_agg(jsonb_build_object('no', no, 'name', name, 'excluded', excluded) order by no)
          from students), '[]'::jsonb),
    'neis', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'slot', slot))
          from neis_marks where d = v_d), '[]'::jsonb),
    'marks', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'period', period, 'kind', kind))
          from teacher_marks where d = v_d), '[]'::jsonb)
  );
end $$;

drop function if exists save_marks(text, int, int[], int[]);

-- p_absent : 이 교시에 "없음"으로 바꿀 학생 / p_present : "출석"으로 바꿀 학생
create or replace function save_marks(p_key text, p_period int, p_absent int[], p_present int[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_now     timestamp := kst_now();
  v_d       date      := v_now::date;
  v_period  int;
  v_teacher text;
  v_label   text := (select value from config where key = 'class_label');
  r         record;
  v_neis    boolean;
  n_abs     text[] := '{}';   -- 새로 없음
  n_pre     text[] := '{}';   -- 나이스 "/" 해제 (출석 확인)
  c_pre     text[] := '{}';   -- 정정: 없음 → 출석
  c_abs     text[] := '{}';   -- 정정: 출석 확인 취소 → 다시 없음
  v_parts   text[] := '{}';
  v_body    text[] := '{}';
  v_cnt     int;
begin
  perform check_key(p_key);
  v_period := current_period(v_now);
  if v_period is null then raise exception 'not_in_class'; end if;
  if p_period is distinct from v_period then raise exception 'period_changed'; end if;
  v_teacher := coalesce(teacher_for(v_d, v_period), '시간표 미등록');

  -- 없음으로
  for r in select s.no, s.name from students s
            where s.no = any(coalesce(p_absent, '{}')) and not s.excluded order by s.no loop
    v_neis := exists (select 1 from neis_marks n where n.d = v_d and n.student_no = r.no and n.slot = v_period::text);
    if v_neis then
      delete from teacher_marks where d = v_d and period = v_period and student_no = r.no and kind = 'present';
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        c_abs := c_abs || (r.no || '번 ' || r.name);
        insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, r.no, 'unpresent', v_teacher);
      end if;
    else
      insert into teacher_marks(d, period, student_no, teacher, kind) values (v_d, v_period, r.no, v_teacher, 'absent')
      on conflict do nothing;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        n_abs := n_abs || (r.no || '번 ' || r.name);
        insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, r.no, 'add', v_teacher);
      end if;
    end if;
  end loop;

  -- 출석으로
  for r in select s.no, s.name from students s
            where s.no = any(coalesce(p_present, '{}')) and not s.excluded order by s.no loop
    v_neis := exists (select 1 from neis_marks n where n.d = v_d and n.student_no = r.no and n.slot = v_period::text);
    if v_neis then
      insert into teacher_marks(d, period, student_no, teacher, kind) values (v_d, v_period, r.no, v_teacher, 'present')
      on conflict do nothing;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        n_pre := n_pre || (r.no || '번 ' || r.name);
        insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, r.no, 'present', v_teacher);
      end if;
    else
      delete from teacher_marks where d = v_d and period = v_period and student_no = r.no and kind = 'absent';
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        c_pre := c_pre || (r.no || '번 ' || r.name);
        insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, r.no, 'remove', v_teacher);
      end if;
    end if;
  end loop;

  if cardinality(n_abs) + cardinality(n_pre) + cardinality(c_pre) + cardinality(c_abs) = 0 then
    insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, 0, 'check', v_teacher);
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
    perform notify_ntfy(
      format('%s %s교시 · %s', v_label, v_period, array_to_string(v_parts, ' · ')),
      array_to_string(v_body, E'\n'),
      case when cardinality(n_abs) > 0 then 5 else 4 end,
      case when cardinality(n_abs) > 0 then array['rotating_light'] else array['pencil2'] end);
  end if;

  return jsonb_build_object('period', v_period,
    'absent', cardinality(n_abs), 'present', cardinality(n_pre),
    'corrected', cardinality(c_pre) + cardinality(c_abs));
end $$;

revoke execute on function save_marks(text,int,int[],int[]) from public;
grant  execute on function get_today(text), save_marks(text,int,int[],int[]) to anon, authenticated;
