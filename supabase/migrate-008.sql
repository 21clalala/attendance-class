-- =====================================================================
-- 변경 008: 컴시간 동기화 전용 토큰
--  · GitHub 에는 Supabase 비밀 키 대신 "동기화 토큰"만 넣습니다.
--  · 이 토큰으로는 컴시간 시간표 자료(comci_*)만 쓸 수 있고, 학생·출결 자료는 건드릴 수 없습니다.
--  · 토큰은 전체 관리자만 [컴시간] 탭에서 보고 새로 만들 수 있습니다.
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

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
