-- =====================================================================
-- 변경 009: 반별 "처음 설정" 체크리스트 상태 + 마지막 나이스 업로드 날짜
-- Supabase → SQL Editor 에 붙여 넣고 Run (한 번만)
-- =====================================================================
alter table classes add column if not exists setup jsonb not null default '{}'::jsonb;
