-- =====================================================================
-- 변경 022: 이전 기록의 보고서 제출 여부 추적
--  · report_track = true 이면 이전 기록도 보고서 미제출/제출을 관리 (앱 등록 회차와 같게)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
alter table trip add column if not exists report_track boolean not null default false;
