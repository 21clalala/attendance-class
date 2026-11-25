-- =====================================================================
-- 변경 027: 카카오톡 챗봇 — 학생이 본인 교외체험학습 사용 일수 조회
--  · students.kakao_code : 학생별 4자리 확인 코드 (담임이 학생에게 나눠 줌)
--      반·번호·이름만으로는 친구가 대신 연결할 수 있어서 코드를 함께 받음
--  · kakao_link : 카카오 사용자 ID ↔ 학생 (처음 한 번 연결하면 다음부터 바로 조회)
--  · kakao_fail : 연결 실패 기록 (카카오 계정당 하루 5번까지만 시도)
--  · kakao_link_student() / kakao_trip_status() / kakao_unlink()
--      Edge Function(kakao-attendance)만 부를 수 있음 (service_role 전용)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

-- 확인 코드: 기존 학생은 이 줄을 실행할 때 학생마다 다른 코드가 생김, 새 학생도 자동 생성
alter table students add column if not exists kakao_code text
  default lpad((floor(random() * 10000))::int::text, 4, '0');

create table if not exists kakao_link (
  kakao_user_id text primary key,
  class_id      int  not null references classes(id) on delete cascade,
  student_no    int  not null,
  name          text not null,                  -- 연결할 때 이름 (명단이 바뀌면 연결 해제)
  linked_at     timestamptz not null default now(),
  last_used_at  timestamptz
);
create index if not exists kakao_link_student on kakao_link(class_id, student_no);

create table if not exists kakao_fail (
  id            bigserial primary key,
  kakao_user_id text not null,
  at            timestamptz not null default now()
);
create index if not exists kakao_fail_uid on kakao_fail(kakao_user_id, at);

do $$
begin
  execute 'alter table kakao_link enable row level security';
  execute 'alter table kakao_fail enable row level security';
  execute 'drop policy if exists class_rw on kakao_link';
  -- 담임(반 관리자)은 자기 반 연결 목록을 보고 해제할 수 있음
  execute 'create policy class_rw on kakao_link for all to authenticated using (can_manage(class_id)) with check (can_manage(class_id))';
  execute 'revoke all on kakao_link from anon';
  execute 'revoke all on kakao_fail from anon, authenticated';
end $$;

-- 학년도 (3월 시작, 한국 시간)
create or replace function kakao_ay(p_d date) returns int
language sql immutable as $$
  select case when extract(month from p_d) >= 3 then extract(year from p_d)::int else extract(year from p_d)::int - 1 end
$$;

-- 연결: 반("3-2"), 번호, 이름, 확인 코드
-- 반환 {ok:true, label, no, name} | {ok:false, reason:'locked'|'mismatch'}
create or replace function kakao_link_student(p_uid text, p_label text, p_no int, p_name text, p_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c classes; s students;
begin
  if coalesce(p_uid, '') = '' then raise exception 'no_user'; end if;
  if (select count(*) from kakao_fail where kakao_user_id = p_uid and at > now() - interval '1 day') >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;

  select * into c from classes where norm_label(label) = norm_label(p_label) limit 1;
  if c.id is not null then
    select * into s from students
     where class_id = c.id and no = p_no
       and replace(name, ' ', '') = replace(coalesce(p_name, ''), ' ', '')
       and kakao_code = trim(coalesce(p_code, ''));
  end if;

  if s.no is null then
    insert into kakao_fail(kakao_user_id) values (p_uid);
    delete from kakao_fail where at < now() - interval '7 days';
    return jsonb_build_object('ok', false, 'reason', 'mismatch');
  end if;

  insert into kakao_link(kakao_user_id, class_id, student_no, name)
  values (p_uid, c.id, s.no, s.name)
  on conflict (kakao_user_id) do update
    set class_id = excluded.class_id, student_no = excluded.student_no, name = excluded.name,
        linked_at = now(), last_used_at = null;
  delete from kakao_fail where kakao_user_id = p_uid;
  return jsonb_build_object('ok', true, 'label', c.label, 'no', s.no, 'name', s.name);
end $$;

-- 조회: 연결된 학생의 이번 학년도 교외체험학습
-- 반환 {linked:false} | {linked:true, label, no, name, ay, limit, used, trips:[…]}
create or replace function kakao_trip_status(p_uid text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  l kakao_link; c classes; s students;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_ay int := kakao_ay((now() at time zone 'Asia/Seoul')::date);
begin
  select * into l from kakao_link where kakao_user_id = p_uid;
  if l.kakao_user_id is null then return jsonb_build_object('linked', false); end if;

  select * into s from students where class_id = l.class_id and no = l.student_no;
  -- 명단에서 빠졌거나 그 번호의 이름이 바뀌었으면 연결 해제
  if s.no is null or s.name is distinct from l.name then
    delete from kakao_link where kakao_user_id = p_uid;
    return jsonb_build_object('linked', false, 'reset', true);
  end if;
  select * into c from classes where id = l.class_id;
  update kakao_link set last_used_at = now() where kakao_user_id = p_uid;

  return jsonb_build_object(
    'linked', true,
    'label',  c.label,
    'no',     s.no,
    'name',   s.name,
    'ay',     v_ay,
    'limit',  20,
    'today',  v_today,
    'used',   coalesce((select sum(days) from trip where class_id = l.class_id and student_no = s.no and ay = v_ay), 0),
    'trips',  coalesce((
      select jsonb_agg(jsonb_build_object(
               'start',  t.start_d,
               'end',    t.end_d,
               'days',   t.days,
               'half',   t.half,
               'source', t.source,
               'report', case
                           when t.source = 'import' and not t.report_track then null
                           when t.report_at is not null then 'done'
                           when t.end_d >= v_today then 'ongoing'
                           else 'missing' end)
             order by t.start_d nulls first, t.id)
        from trip t
       where t.class_id = l.class_id and t.student_no = s.no and t.ay = v_ay), '[]'::jsonb)
  );
end $$;

create or replace function kakao_unlink(p_uid text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  delete from kakao_link where kakao_user_id = p_uid;
  return found;
end $$;

revoke execute on function kakao_link_student(text, text, int, text, text), kakao_trip_status(text), kakao_unlink(text)
  from public, anon, authenticated;
grant execute on function kakao_link_student(text, text, int, text, text), kakao_trip_status(text), kakao_unlink(text)
  to service_role;
