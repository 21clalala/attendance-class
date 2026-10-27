-- =====================================================================
-- 변경 019: 휴일(공휴일·재량휴업일·수능일 등)
--  · 휴일에는 기본 시정이 적용되지 않아 "수업 없는 날"이 됨
--    → 조회 QR·교과 입력이 열리지 않고, 08:00 알림·경과 수업일·체험학습 일수에서 빠짐
--  · 그날 [시간표 변경]에서 시정을 따로 저장하면 그 시정이 우선
--  · 관리: 관리자 페이지 [학교 관리 → 시간표·시정 → 휴일] (전체 관리자)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
create table if not exists holiday (
  d    date primary key,
  name text not null
);
do $$
begin
  execute 'alter table holiday enable row level security';
  execute 'drop policy if exists common_read on holiday';
  execute 'drop policy if exists common_write on holiday';
  execute 'create policy common_read on holiday for select to authenticated using (is_admin())';
  execute 'create policy common_write on holiday for all to authenticated using (is_super()) with check (is_super())';
  execute 'revoke all on holiday from anon';
end $$;

insert into holiday(d, name) values
  ('2026-03-02', '삼일절 대체공휴일'),
  ('2026-04-06', '개교기념일'),
  ('2026-05-01', '근로자의 날'),
  ('2026-05-04', '재량휴업일'),
  ('2026-05-05', '어린이날'),
  ('2026-05-25', '부처님오신날 대체공휴일'),
  ('2026-06-03', '지방선거'),
  ('2026-07-17', '제헌절'),
  ('2026-08-17', '광복절 대체공휴일'),
  ('2026-09-24', '추석연휴'),
  ('2026-09-25', '추석연휴'),
  ('2026-10-05', '개천절 대체공휴일'),
  ('2026-10-09', '한글날'),
  ('2026-12-25', '크리스마스'),
  ('2027-01-01', '신정')
on conflict (d) do nothing;

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
       and not exists (select 1 from holiday where d = p_d)
  ) s order by 1
$$;
