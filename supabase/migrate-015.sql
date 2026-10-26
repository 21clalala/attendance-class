-- =====================================================================
-- 변경 015: 나이스 반영 기록 (날짜별 [반영 완료])
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
create table if not exists neis_reflect (
  class_id  int  references classes(id) on delete cascade,
  d         date,
  at        timestamptz default now(),
  by_email  text,
  summary   jsonb,
  primary key (class_id, d)
);
do $$
begin
  execute 'alter table neis_reflect enable row level security';
  execute 'drop policy if exists class_rw on neis_reflect';
  execute 'create policy class_rw on neis_reflect for all to authenticated using (can_manage(class_id)) with check (can_manage(class_id))';
  execute 'revoke all on neis_reflect from anon';
end $$;
