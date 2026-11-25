-- =====================================================================
-- 변경 028: 카카오톡 챗봇 — 카카오 계정 기억(연결) 없애고 매번 학번·이름으로 조회
--  · 학생이 "30215 홍길동"처럼 학번·이름을 보낼 때마다 그 학생 기록을 바로 안내
--  · 027 의 kakao_link(연결 기록)와 연결 함수는 삭제
--  · 학번·이름이 틀린 시도는 지금처럼 카카오 계정당 하루 5번까지 (맞게 조회한 것은 세지 않음)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
drop function if exists kakao_link_student(text, text, int, text);
drop function if exists kakao_trip_status(text);
drop function if exists kakao_unlink(text);
drop table if exists kakao_link;

-- 반환 {ok:false, reason:'locked'|'mismatch'} | {ok:true, label, no, name, ay, limit, today, used, trips:[…]}
create or replace function kakao_trip_lookup(p_uid text, p_label text, p_no int, p_name text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  c classes; s students;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_ay int := kakao_ay((now() at time zone 'Asia/Seoul')::date);
begin
  if coalesce(p_uid, '') = '' then raise exception 'no_user'; end if;
  if (select count(*) from kakao_fail where kakao_user_id = p_uid and at > now() - interval '1 day') >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;

  select * into c from classes where norm_label(label) = norm_label(p_label) limit 1;
  if c.id is not null then
    select * into s from students
     where class_id = c.id and no = p_no
       and replace(name, ' ', '') = replace(coalesce(p_name, ''), ' ', '');
  end if;

  if s.no is null then
    insert into kakao_fail(kakao_user_id) values (p_uid);
    delete from kakao_fail where at < now() - interval '7 days';
    return jsonb_build_object('ok', false, 'reason', 'mismatch');
  end if;

  return jsonb_build_object(
    'ok',     true,
    'label',  c.label,
    'no',     s.no,
    'name',   s.name,
    'ay',     v_ay,
    'limit',  20,
    'today',  v_today,
    'used',   coalesce((select sum(days) from trip where class_id = c.id and student_no = s.no and ay = v_ay), 0),
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
       where t.class_id = c.id and t.student_no = s.no and t.ay = v_ay), '[]'::jsonb)
  );
end $$;

revoke execute on function kakao_trip_lookup(text, text, int, text) from public, anon, authenticated;
grant execute on function kakao_trip_lookup(text, text, int, text) to service_role;
