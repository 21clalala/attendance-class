-- =====================================================================
-- 변경 006: 여러 반 지원 + 전체 관리자 / 반 관리자 권한
--  · 기존 데이터(명단·시간표·출결·QR 주소·알림 토픽)는 1번 반으로 그대로 옮겨집니다.
--  · 시정표·단축수업(날짜별 시정)은 학교 공통 — 전체 관리자만 수정
--  · 등록된 이메일만 계정을 만들 수 있게 막습니다(초대제).
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

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
