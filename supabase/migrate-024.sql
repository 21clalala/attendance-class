-- =====================================================================
-- 변경 024: 컴시간 동기화를 한국 시간 07:00 정시에 시작
--  · GitHub 예약 실행은 몇 시간씩 늦어지므로, Supabase(pg_cron)가 07:00에
--    GitHub Actions 의 [Run workflow] 를 대신 눌러 줌
--  · GitHub 토큰은 Supabase Vault 에 'github_dispatch_token' 이름으로 먼저 저장해 두어야 함
--    (토큰은 이 파일에 넣지 마세요)
--  · GitHub 쪽 예약(07:10)은 그대로 둠 — 늦게라도 한 번 더 돌면 그사이 바뀐 교체까지 반영
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
create or replace function comci_dispatch() returns bigint
language plpgsql security definer set search_path = public as $$
declare v_token text; v_id bigint;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'github_dispatch_token' limit 1;
  if coalesce(v_token, '') = '' then
    raise notice 'Vault 에 github_dispatch_token 이 없습니다';
    return null;
  end if;
  select net.http_post(
    url     := 'https://api.github.com/repos/21clalala/attendance-class/actions/workflows/comci-sync.yml/dispatches',
    body    := jsonb_build_object('ref', 'main'),
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || v_token,
                 'Accept', 'application/vnd.github+json',
                 'X-GitHub-Api-Version', '2022-11-28',
                 'User-Agent', 'attendance-class-cron',
                 'Content-Type', 'application/json')
  ) into v_id;
  return v_id;
end $$;
revoke execute on function comci_dispatch() from public, anon, authenticated;

-- 한국 월~금 07:00 (= UTC 일~목 22:00)
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'comci-dispatch';
  perform cron.schedule('comci-dispatch', '0 22 * * 0-4', 'select public.comci_dispatch()');
exception when others then
  raise notice 'pg_cron 설정 실패: %', sqlerrm;
end $$;
