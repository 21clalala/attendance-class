-- =====================================================================
-- 변경 014: 출결신고서 미제출 추적 + 수업일 아침 08:00 ntfy 알림
--  · 미제출 = 비고에 "미제출" 글자가 있는 학생·날짜 (나이스 비고 / 담임 직접 입력 비고, 중복 없이 1건)
--  · 마감 종류에 "미인정"이 들어간 건은 신고서가 필요 없으므로 제외
--  · [제출 완료] 표시는 doc_submit 표에 저장 (다시 누르면 취소)
--  · 경과일 = 해당 날짜 다음 날부터 오늘까지의 수업일 수 (공휴일은 아직 따로 처리하지 않음)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

create table if not exists doc_submit (
  class_id   int  references classes(id) on delete cascade,
  d          date,
  student_no int,
  by_email   text,
  at         timestamptz default now(),
  primary key (class_id, d, student_no)
);

do $$
begin
  execute 'alter table doc_submit enable row level security';
  execute 'drop policy if exists class_rw on doc_submit';
  execute 'create policy class_rw on doc_submit for all to authenticated using (can_manage(class_id)) with check (can_manage(class_id))';
  execute 'revoke all on doc_submit from anon';
end $$;

-- 해당 반의 수업일 수 (p_from 초과 ~ p_to 이하)
create or replace function school_days_between(p_class int, p_from date, p_to date) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from generate_series(p_from + 1, p_to, interval '1 day') g
   where exists (select 1 from schedule_for(p_class, g::date))
$$;

-- 미제출 목록 (기간 내, 제출 여부 포함) — 내부용
create or replace function doc_list_raw(p_class int, p_from date, p_to date)
returns table(d date, student_no int, name text, kind text, note text, submitted boolean, submitted_at timestamptz, elapsed int)
language sql stable security definer set search_path = public as $$
  with src as (
    select coalesce(m.class_id, n.class_id) class_id, coalesce(m.d, n.d) d, coalesce(m.student_no, n.student_no) student_no,
           case when m.student_no is not null then m.kind else n.kind end kind,
           case when m.student_no is not null then m.note else n.note end note
      from (select * from day_manual where class_id = p_class and d between p_from and p_to) m
      full join (select * from neis_day where class_id = p_class and d between p_from and p_to) n
        on n.d = m.d and n.student_no = m.student_no
  )
  select s.d, s.student_no, st.name, s.kind, s.note,
         ds.d is not null, ds.at,
         school_days_between(p_class, s.d, (now() at time zone 'Asia/Seoul')::date)
    from src s
    left join students st on st.class_id = p_class and st.no = s.student_no
    left join doc_submit ds on ds.class_id = p_class and ds.d = s.d and ds.student_no = s.student_no
   where coalesce(s.note, '') like '%미제출%'
     and coalesce(s.kind, '') not like '%미인정%'
     and coalesce(s.note, '') not like '%미인정%'
   order by s.d, s.student_no
$$;
revoke execute on function doc_list_raw(int, date, date), school_days_between(int, date, date) from public, anon, authenticated;

-- 관리자 페이지용: 자기 반만
create or replace function doc_list(p_class int, p_from date, p_to date)
returns table(d date, student_no int, name text, kind text, note text, submitted boolean, submitted_at timestamptz, elapsed int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_manage(p_class) then raise exception 'forbidden'; end if;
  return query select * from doc_list_raw(p_class, p_from, p_to);
end $$;
revoke execute on function doc_list(int, date, date) from public, anon;
grant execute on function doc_list(int, date, date) to authenticated;

-- "질병결석(감기)" 형태로 정리 (비고의 "미제출" 글자는 뺌)
create or replace function doc_label(p_kind text, p_note text) returns text
language sql immutable as $$
  select case when n = '' then coalesce(p_kind, '')
              when p_kind is null or p_kind = '' or n like p_kind || '%' then n
              else p_kind || '(' || n || ')' end
    from (select btrim(regexp_replace(coalesce(p_note, ''), '\s*미제출\s*', ' ', 'g')) n) x
$$;

-- 아침 알림: 수업이 있는 날, 남은 미제출(경과 1수업일 이상)이 있을 때만
create or replace function send_doc_alerts() returns int
language plpgsql security definer set search_path = public as $$
declare
  c classes; v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_lines text[]; v_cnt int; v_sent int := 0;
begin
  for c in select * from classes where coalesce(ntfy_topic, '') <> '' loop
    if not exists (select 1 from schedule_for(c.id, v_today)) then continue; end if;
    select array_agg(format('%s/%s %s번 %s · %s · %s일 경과', extract(month from l.d), extract(day from l.d), l.student_no, coalesce(l.name, ''),
                            doc_label(l.kind, l.note), l.elapsed) order by l.d, l.student_no),
           count(*)
      into v_lines, v_cnt
      from doc_list_raw(c.id, v_today - 180, v_today - 1) l
     where not l.submitted and l.elapsed >= 1;
    if coalesce(v_cnt, 0) = 0 then continue; end if;
    perform notify_ntfy(c.ntfy_topic, c.label || ' 출결신고서 미제출 ' || v_cnt || '건',
                        array_to_string(v_lines, E'\n'), 3, array['page_facing_up']);
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end $$;
revoke execute on function send_doc_alerts() from public, anon, authenticated;

-- 매주 월~금 08:00 (KST) = 일~목 23:00 (UTC). 수업 없는 날은 함수 안에서 건너뜀
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname = 'doc-alerts';
  perform cron.schedule('doc-alerts', '0 23 * * 0-4', 'select public.send_doc_alerts()');
exception when others then
  raise notice 'pg_cron 설정 실패: % — Database → Extensions 에서 pg_cron 을 켠 뒤 이 블록만 다시 실행하세요', sqlerrm;
end $$;
