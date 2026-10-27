-- =====================================================================
-- 변경 020: 학교장허가 교외체험학습 (회차 관리)
--  · trip: 회차(학생·기간·하루 종일/일부 교시·사용 일수·보고서 제출)
--      source 'app'    = 앱에서 등록 (출석부에 자동 입력)
--      source 'import' = 이전 기록 (누적 일수 계산에만 사용)
--  · school_days_list(): 기간 안의 수업일과 그날 교시 (주말·휴일·수업 없는 날 제외)
--  · 08:00 알림: 체험학습 보고서는 회차당 한 줄 (끝난 다음 수업일부터)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
create table if not exists trip (
  id         bigserial primary key,
  class_id   int  references classes(id) on delete cascade,
  student_no int  not null,
  ay         int  not null,                 -- 학년도 (3월 시작)
  start_d    date,                          -- 이전 기록 중 일수만 있는 경우 null
  end_d      date,
  half       boolean not null default false, -- 일부 교시
  slots      text[],                        -- 일부 교시일 때 빠진 칸 (조회, 1~7, 종례)
  kind       text,                          -- 마감 종류 (출석인정결석/지각/조퇴/결과)
  days       numeric(4,1) not null,         -- 사용 일수 (반일 0.5)
  source     text not null default 'app' check (source in ('app', 'import')),
  memo       text,
  report_at  timestamptz,                   -- 보고서 제출 완료 시각
  by_email   text,
  created_at timestamptz default now()
);
alter table trip add column if not exists kind text;
create index if not exists trip_class_ay on trip(class_id, ay);
do $$
begin
  execute 'alter table trip enable row level security';
  execute 'drop policy if exists class_rw on trip';
  execute 'create policy class_rw on trip for all to authenticated using (can_manage(class_id)) with check (can_manage(class_id))';
  execute 'revoke all on trip from anon';
end $$;

-- 기간 안의 수업일과 그날의 교시 목록
create or replace function school_days_list(p_class int, p_from date, p_to date)
returns table(d date, periods int[])
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_manage(p_class) then raise exception 'forbidden'; end if;
  if p_to - p_from > 120 then raise exception 'range_too_long'; end if;
  return query
    select g::date, array(select s.period from schedule_for(p_class, g::date) s order by 1)
      from generate_series(p_from, p_to, interval '1 day') g
     where exists (select 1 from schedule_for(p_class, g::date));
end $$;
revoke execute on function school_days_list(int, date, date) from public, anon;
grant execute on function school_days_list(int, date, date) to authenticated;

-- 아침 알림: 체험학습 보고서는 회차로 묶어서 한 줄
create or replace function send_doc_alerts() returns int
language plpgsql security definer set search_path = public as $$
declare
  c classes; v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_lines text[]; v_cnt int; v_sent int := 0;
begin
  for c in select * from classes where coalesce(ntfy_topic, '') <> '' loop
    if not exists (select 1 from schedule_for(c.id, v_today)) then continue; end if;
    with l as (
      select x.*, (select t.id from trip t
                    where t.class_id = c.id and t.source = 'app' and t.student_no = x.student_no
                      and x.doc = '보고서' and x.d between t.start_d and t.end_d limit 1) trip_id
        from doc_list_raw(c.id, v_today - 180, v_today - 1) x
       where not x.submitted
    ), g as (
      select min(d) d1, max(d) d2, student_no, max(name) name, doc, min(kind) kind, min(note) note, min(elapsed) elapsed
        from l group by coalesce(trip_id::text, d::text || ':' || student_no), student_no, doc
    )
    select array_agg(format('%s %s번 %s · %s · %s · %s일 경과',
                            case when d1 = d2 then to_char(d1, 'FMMM/FMDD') else to_char(d1, 'FMMM/FMDD') || '~' || to_char(d2, 'FMMM/FMDD') end,
                            student_no, coalesce(name, ''), doc, doc_label(kind, note), elapsed) order by d1, student_no),
           count(*)
      into v_lines, v_cnt
      from g where elapsed >= 1;
    if coalesce(v_cnt, 0) = 0 then continue; end if;
    perform notify_ntfy(c.ntfy_topic, c.label || ' 증빙서류 미제출 ' || v_cnt || '건',
                        array_to_string(v_lines, E'\n'), 3, array['page_facing_up']);
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end $$;
revoke execute on function send_doc_alerts() from public, anon, authenticated;
