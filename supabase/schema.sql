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


-- ===== 변경 003 =====
create or replace function demo_notify(p_key text, p_period int, p_teacher text,
                                       p_absent text[], p_present text[], p_corrected text[])
returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  v_label text := (select value from config where key = 'class_label');
  v_parts text[] := '{}';
  v_body  text[] := '{}';
  a text[] := coalesce(p_absent[1:20], '{}');
  p text[] := coalesce(p_present[1:20], '{}');
  c text[] := coalesce(p_corrected[1:20], '{}');
begin
  perform check_key(p_key);
  if cardinality(a) > 0 then
    v_parts := v_parts || ('없음 ' || cardinality(a) || '명');
    v_body  := v_body  || ('없음: ' || left(array_to_string(a, ', '), 300));
  end if;
  if cardinality(p) > 0 then
    v_parts := v_parts || ('출석 확인 ' || cardinality(p) || '명');
    v_body  := v_body  || ('출석 확인(나이스 / 해제): ' || left(array_to_string(p, ', '), 300));
  end if;
  if cardinality(c) > 0 then
    v_parts := v_parts || ('정정 ' || cardinality(c) || '명');
    v_body  := v_body  || ('정정: ' || left(array_to_string(c, ', '), 300));
  end if;
  if cardinality(v_parts) = 0 then return; end if;
  v_body := v_body || (left(coalesce(p_teacher, ''), 20) || ' 선생님 · ' || to_char(kst_now(), 'HH24:MI'));
  perform notify_ntfy(
    format('[체험] %s %s교시 · %s', v_label, coalesce(p_period, 0), array_to_string(v_parts, ' · ')),
    array_to_string(v_body, E'\n'),
    case when cardinality(a) > 0 then 5 else 4 end,
    case when cardinality(a) > 0 then array['rotating_light'] else array['pencil2'] end);
end $$;

revoke execute on function demo_notify(text,int,text,text[],text[],text[]) from public;
grant  execute on function demo_notify(text,int,text,text[],text[],text[]) to anon, authenticated;


-- ===== 변경 004 =====
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


-- ===== 변경 005 =====

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
    'teachers', coalesce((
        select jsonb_agg(t order by t) from (
          select teacher as t from timetable
          union select teacher from teacher_override where d >= v_d - 7) x), '[]'::jsonb),
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


drop function if exists save_marks(text, int, int[], int[]);

-- p_absent : 이 교시에 "없음"으로 바꿀 학생 / p_present : "출석"으로 바꿀 학생
create or replace function save_marks(p_key text, p_period int, p_teacher text, p_absent int[], p_present int[])
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
  v_teacher := teacher_for(v_d, v_period);
  if v_teacher is null then raise exception 'no_teacher'; end if;
  if p_teacher is distinct from v_teacher then raise exception 'not_your_period'; end if;

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


revoke execute on function save_marks(text,int,text,int[],int[]) from public;
grant  execute on function get_today(text), save_marks(text,int,text,int[],int[]) to anon, authenticated;


-- ===== 변경 006 (여러 반) =====
-- ---------- 반 ----------
create table if not exists classes (
  id          serial primary key,
  label       text not null unique,
  access_key  text not null unique default replace(gen_random_uuid()::text, '-', ''),
  ntfy_topic  text not null default 'att-' || replace(gen_random_uuid()::text, '-', ''),
  created_at  timestamptz not null default now()
);

insert into classes(id, label, access_key, ntfy_topic)
select 1,
       coalesce((select value from config where key = 'class_label'), '3-2'),
       coalesce((select value from config where key = 'access_key'), replace(gen_random_uuid()::text, '-', '')),
       coalesce((select value from config where key = 'ntfy_topic'), 'att-' || replace(gen_random_uuid()::text, '-', ''))
where not exists (select 1 from classes);
do $$ begin perform setval(pg_get_serial_sequence('classes', 'id'), greatest((select max(id) from classes), 1)); end $$;

-- ---------- 관리자: class_id 가 비어 있으면 전체 관리자 ----------
alter table admins add column if not exists class_id int references classes(id) on delete cascade;
alter table admins add column if not exists id bigserial;
alter table admins drop constraint if exists admins_pkey;
alter table admins add primary key (id);
create unique index if not exists admins_email_class_uq on admins (lower(email), coalesce(class_id, 0));

-- ---------- 반별 테이블에 class_id 추가 (기존 행은 1번 반) ----------
do $$
declare t text;
begin
  foreach t in array array['students','timetable','teacher_override','neis_day','neis_marks','teacher_marks','mark_log'] loop
    execute format('alter table %I add column if not exists class_id int not null default 1 references classes(id) on delete cascade', t);
    execute format('alter table %I alter column class_id drop default', t);
  end loop;
end $$;

alter table students         drop constraint if exists students_pkey;
alter table students         add primary key (class_id, no);
alter table timetable        drop constraint if exists timetable_pkey;
alter table timetable        add primary key (class_id, weekday, period);
alter table teacher_override drop constraint if exists teacher_override_pkey;
alter table teacher_override add primary key (class_id, d, period);
alter table neis_day         drop constraint if exists neis_day_pkey;
alter table neis_day         add primary key (class_id, d, student_no);
alter table neis_marks       drop constraint if exists neis_marks_pkey;
alter table neis_marks       add primary key (class_id, d, student_no, slot);
alter table teacher_marks    drop constraint if exists teacher_marks_pkey;
alter table teacher_marks    add primary key (class_id, d, period, student_no);
create index if not exists mark_log_class_d on mark_log (class_id, d);

-- ---------- 이전 함수 정리 ----------
drop function if exists teacher_for(date, int);
drop function if exists check_key(text);
drop function if exists notify_ntfy(text, text, int, text[]);
drop function if exists admin_test_notify();
drop function if exists admin_schedule(date);

-- ---------- 권한 함수 ----------
create or replace function my_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = my_email())
$$;

create or replace function is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = my_email() and class_id is null)
$$;

create or replace function can_manage(p_class int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = my_email() and (class_id is null or class_id = p_class))
$$;

-- ---------- 내부 함수 ----------
create or replace function class_by_key(p_key text) returns classes
language plpgsql stable security definer set search_path = public as $$
declare c classes;
begin
  select * into c from classes where access_key = p_key;
  if p_key is null or c.id is null then raise exception 'invalid_key'; end if;
  return c;
end $$;

create or replace function teacher_for(p_class int, p_d date, p_period int) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select teacher from teacher_override where class_id = p_class and d = p_d and period = p_period),
    (select teacher from timetable where class_id = p_class and weekday = extract(isodow from p_d)::int and period = p_period))
$$;

create or replace function notify_ntfy(p_topic text, p_title text, p_msg text, p_priority int, p_tags text[])
returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_topic, '') = '' then return; end if;
  perform net.http_post(
    url     := 'https://ntfy.sh/',
    body    := jsonb_build_object('topic', p_topic, 'title', p_title, 'message', p_msg,
                                  'priority', p_priority, 'tags', to_jsonb(p_tags)),
    headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;

-- ---------- 교과선생님용 ----------
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
          union select teacher from teacher_override where class_id = c.id and d >= v_d - 7) x), '[]'::jsonb),
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
  v_period := current_period(v_now);
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

create or replace function demo_notify(p_key text, p_period int, p_teacher text,
                                       p_absent text[], p_present text[], p_corrected text[])
returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  c classes := class_by_key(p_key);
  v_parts text[] := '{}';
  v_body  text[] := '{}';
  a text[] := coalesce(p_absent[1:20], '{}');
  p text[] := coalesce(p_present[1:20], '{}');
  x text[] := coalesce(p_corrected[1:20], '{}');
begin
  if cardinality(a) > 0 then v_parts := v_parts || ('없음 ' || cardinality(a) || '명'); v_body := v_body || ('없음: ' || left(array_to_string(a, ', '), 300)); end if;
  if cardinality(p) > 0 then v_parts := v_parts || ('출석 확인 ' || cardinality(p) || '명'); v_body := v_body || ('출석 확인(나이스 / 해제): ' || left(array_to_string(p, ', '), 300)); end if;
  if cardinality(x) > 0 then v_parts := v_parts || ('정정 ' || cardinality(x) || '명'); v_body := v_body || ('정정: ' || left(array_to_string(x, ', '), 300)); end if;
  if cardinality(v_parts) = 0 then return; end if;
  v_body := v_body || (left(coalesce(p_teacher, ''), 20) || ' 선생님 · ' || to_char(kst_now(), 'HH24:MI'));
  perform notify_ntfy(c.ntfy_topic,
    format('[체험] %s %s교시 · %s', c.label, coalesce(p_period, 0), array_to_string(v_parts, ' · ')),
    array_to_string(v_body, E'\n'),
    case when cardinality(a) > 0 then 5 else 4 end,
    case when cardinality(a) > 0 then array['rotating_light'] else array['pencil2'] end);
end $$;

-- ---------- 관리자용 ----------
create or replace function admin_test_notify(p_class int) returns void
language plpgsql security definer set search_path = public as $$
declare c classes;
begin
  if not can_manage(p_class) then raise exception 'not_admin'; end if;
  select * into c from classes where id = p_class;
  perform notify_ntfy(c.ntfy_topic, c.label || ' 알림 테스트', '출결 알림이 정상적으로 연결되었습니다.', 3, array['white_check_mark']);
end $$;

create or replace function admin_schedule(p_class int, p_d date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_manage(p_class) then raise exception 'not_admin'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'period', s.period,
             'start',  to_char(s.start_t, 'HH24:MI'),
             'end',    to_char(s.end_t,   'HH24:MI'),
             'teacher', teacher_for(p_class, p_d, s.period)) order by s.period)
      from schedule_for(p_d) s), '[]'::jsonb);
end $$;

-- ---------- 등록된 이메일만 계정 생성 가능 ----------
create or replace function invite_only() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from admins where lower(email) = lower(new.email)) then
    raise exception '등록되지 않은 이메일입니다. 전체 관리자에게 등록을 요청하세요.';
  end if;
  return new;
end $$;
do $$
begin
  drop trigger if exists attend_invite_only on auth.users;
  create trigger attend_invite_only before insert on auth.users
    for each row execute function invite_only();
exception when others then
  raise notice '초대제 트리거를 만들지 못했습니다(계정은 대시보드에서 직접 만들어야 합니다): %', sqlerrm;
end $$;

-- ---------- 권한(RLS) ----------
revoke all on all tables in schema public from anon;
revoke execute on function kst_now(), schedule_for(date), current_period(timestamp),
                           class_by_key(text), teacher_for(int,date,int), notify_ntfy(text,text,text,int,text[])
  from public, anon, authenticated;
revoke execute on function my_email() from public, anon;
grant  execute on function my_email() to authenticated;
revoke execute on function admin_test_notify(int), admin_schedule(int,date), is_admin(), is_super(), can_manage(int)
  from public, anon;
grant  execute on function get_today(text), save_marks(text,int,text,int[],int[]),
                           demo_notify(text,int,text,text[],text[],text[]) to anon, authenticated;
grant  execute on function admin_test_notify(int), admin_schedule(int,date), is_admin(), is_super(), can_manage(int)
  to authenticated;

do $$
declare t text; p record;
begin
  -- 기존 정책 모두 제거
  for p in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy if exists %I on %I', p.policyname, p.tablename);
  end loop;

  foreach t in array array['classes','admins','config','students','bell_default','weekday_max','timetable',
                           'day_schedule','teacher_override','neis_day','neis_marks','teacher_marks','mark_log'] loop
    execute format('alter table %I enable row level security', t);
  end loop;

  -- 반별 데이터: 그 반 관리자 + 전체 관리자
  foreach t in array array['students','timetable','teacher_override','neis_day','neis_marks','teacher_marks','mark_log'] loop
    execute format('create policy class_rw on %I for all to authenticated using (can_manage(class_id)) with check (can_manage(class_id))', t);
  end loop;

  -- 학교 공통: 관리자 누구나 읽기, 전체 관리자만 쓰기
  foreach t in array array['bell_default','weekday_max','day_schedule'] loop
    execute format('create policy common_read on %I for select to authenticated using (is_admin())', t);
    execute format('create policy common_write on %I for all to authenticated using (is_super()) with check (is_super())', t);
  end loop;

  create policy cls_read on classes for select to authenticated using (can_manage(id));
  create policy cls_upd  on classes for update to authenticated using (can_manage(id)) with check (can_manage(id));
  create policy cls_ins  on classes for insert to authenticated with check (is_super());
  create policy cls_del  on classes for delete to authenticated using (is_super());

  create policy adm_read on admins for select to authenticated using (is_super() or lower(email) = my_email());
  create policy adm_write on admins for all to authenticated using (is_super()) with check (is_super());

  create policy cfg_super on config for all to authenticated using (is_super()) with check (is_super());
end $$;

do $$
begin
  begin execute 'alter publication supabase_realtime add table teacher_marks'; exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table neis_marks';    exception when others then null; end;
end $$;


-- ===== 변경 007 (컴시간 연동) =====
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


-- ===== 변경 008 (동기화 전용 토큰) =====
create table if not exists comci_secret (
  id         int primary key default 1 check (id = 1),
  sync_token text not null default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);
insert into comci_secret(id) values (1) on conflict do nothing;

alter table comci_secret enable row level security;
drop policy if exists super_only on comci_secret;
create policy super_only on comci_secret for all to authenticated using (is_super()) with check (is_super());
revoke all on comci_secret from anon;

create or replace function comci_check_token(p_token text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(length(p_token), 0) < 32
     or p_token is distinct from (select sync_token from comci_secret where id = 1) then
    raise exception 'invalid_sync_token';
  end if;
end $$;

-- 1) 설정 읽기
create or replace function comci_sync_config(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform comci_check_token(p_token);
  return (select jsonb_build_object('school_name', school_name, 'school_code', school_code, 'enabled', enabled)
            from comci_config where id = 1);
end $$;

-- 2) 검색으로 찾은 학교 코드 저장
create or replace function comci_sync_set_school(p_token text, p_code int, p_name text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform comci_check_token(p_token);
  update comci_config set school_code = p_code, school_name = left(p_name, 60) where id = 1;
end $$;

-- 3) 한 주 시간표 교체 (그 날짜들의 기존 자료 삭제 후 저장)
create or replace function comci_sync_week(p_token text, p_dates date[], p_rows jsonb) returns int
language plpgsql volatile security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Asia/Seoul')::date; n int;
begin
  perform comci_check_token(p_token);
  if cardinality(p_dates) > 7 or jsonb_array_length(p_rows) > 6000 then raise exception 'too_large'; end if;
  if exists (select 1 from unnest(p_dates) d where d < v_today - 14 or d > v_today + 35) then raise exception 'bad_date'; end if;

  delete from comci_slot where d = any(p_dates);
  insert into comci_slot(label, d, period, subject, teacher_idx, changed, synced_at)
  select r.label, r.d, r.period, left(r.subject, 30), r.teacher_idx, coalesce(r.changed, false), now()
    from jsonb_to_recordset(p_rows) as r(label text, d date, period int, subject text, teacher_idx int, changed boolean)
   where r.label ~ '^\d{1,2}-\d{1,2}$' and r.d = any(p_dates) and r.period between 1 and 12
  on conflict (label, d, period) do update
    set subject = excluded.subject, teacher_idx = excluded.teacher_idx, changed = excluded.changed, synced_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

-- 4) 선생님 번호·컴시간 표기·과목 (관리자가 넣은 실명은 건드리지 않음)
create or replace function comci_sync_teachers(p_token text, p_rows jsonb) returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  perform comci_check_token(p_token);
  if jsonb_array_length(p_rows) > 2000 then raise exception 'too_large'; end if;
  insert into comci_teacher(idx, web_name, subjects, updated_at)
  select r.idx, left(r.web_name, 30), left(r.subjects, 80), now()
    from jsonb_to_recordset(p_rows) as r(idx int, web_name text, subjects text)
   where r.idx between 1 and 100000
  on conflict (idx) do update set web_name = excluded.web_name, subjects = excluded.subjects, updated_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

-- 5) 결과 기록 + 오래된 자료 정리
create or replace function comci_sync_finish(p_token text, p_ok boolean, p_message text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform comci_check_token(p_token);
  update comci_config set last_run_at = now(), last_ok = p_ok, last_message = left(p_message, 400) where id = 1;
  if p_ok then
    delete from comci_slot where d < (now() at time zone 'Asia/Seoul')::date - 60;
  end if;
end $$;

-- 관리자: 토큰 새로 만들기
create or replace function comci_new_token() returns text
language plpgsql volatile security definer set search_path = public as $$
declare t text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if not is_super() then raise exception 'not_admin'; end if;
  update comci_secret set sync_token = t, created_at = now() where id = 1;
  return t;
end $$;

revoke execute on function comci_check_token(text) from public, anon, authenticated;
revoke execute on function comci_sync_config(text), comci_sync_set_school(text,int,text), comci_sync_week(text,date[],jsonb),
                           comci_sync_teachers(text,jsonb), comci_sync_finish(text,boolean,text), comci_new_token()
  from public;
grant  execute on function comci_sync_config(text), comci_sync_set_school(text,int,text), comci_sync_week(text,date[],jsonb),
                           comci_sync_teachers(text,jsonb), comci_sync_finish(text,boolean,text)
  to anon, authenticated;
grant  execute on function comci_new_token() to authenticated;
