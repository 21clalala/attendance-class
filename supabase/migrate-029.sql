-- =====================================================================
-- 변경 029: 카카오톡 챗봇 — AI(Gemini)가 읽고 답할 "챗봇 안내 자료"
--  · chatbot_doc : 학교 전체 하나 (id = 1). 체험학습 신청 방법·서류·기한 등 안내 글
--  · 관리: 관리자 페이지 [학교 관리 → 카카오 챗봇] (전체 관리자만 수정, 반 관리자는 읽기)
--  · Edge Function(kakao-attendance)이 이 글을 읽어 학생 질문에 답함
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
create table if not exists chatbot_doc (
  id         int primary key default 1 check (id = 1),
  body       text not null default '',
  updated_at timestamptz not null default now(),
  by_email   text
);
insert into chatbot_doc(id) values (1) on conflict (id) do nothing;

do $$
begin
  execute 'alter table chatbot_doc enable row level security';
  execute 'drop policy if exists common_read on chatbot_doc';
  execute 'drop policy if exists common_write on chatbot_doc';
  execute 'create policy common_read on chatbot_doc for select to authenticated using (is_admin())';
  execute 'create policy common_write on chatbot_doc for all to authenticated using (is_super()) with check (is_super())';
  execute 'revoke all on chatbot_doc from anon';
end $$;
