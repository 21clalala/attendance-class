-- =====================================================================
-- 변경 003: 체험 모드 알림 (출결 데이터에는 아무것도 기록하지 않음)
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
create or replace function demo_notify(p_key text, p_period int, p_teacher text,
                                       p_absent text[], p_present text[], p_corrected text[])
returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  v_label text := (select value from config where key = 'class_label');
  v_parts text[] := '{}';
  v_body  text[] := '{}';
  a text[] := coalesce(p_absent[1:20], '{}');
  p text[] := coalesce(p_present[1:20], '{}');
  c text[] := coalesce(p_corrected[1:20], '{}');
begin
  perform check_key(p_key);
  if cardinality(a) > 0 then
    v_parts := v_parts || ('없음 ' || cardinality(a) || '명');
    v_body  := v_body  || ('없음: ' || left(array_to_string(a, ', '), 300));
  end if;
  if cardinality(p) > 0 then
    v_parts := v_parts || ('출석 확인 ' || cardinality(p) || '명');
    v_body  := v_body  || ('출석 확인(나이스 / 해제): ' || left(array_to_string(p, ', '), 300));
  end if;
  if cardinality(c) > 0 then
    v_parts := v_parts || ('정정 ' || cardinality(c) || '명');
    v_body  := v_body  || ('정정: ' || left(array_to_string(c, ', '), 300));
  end if;
  if cardinality(v_parts) = 0 then return; end if;
  v_body := v_body || (left(coalesce(p_teacher, ''), 20) || ' 선생님 · ' || to_char(kst_now(), 'HH24:MI'));
  perform notify_ntfy(
    format('[체험] %s %s교시 · %s', v_label, coalesce(p_period, 0), array_to_string(v_parts, ' · ')),
    array_to_string(v_body, E'\n'),
    case when cardinality(a) > 0 then 5 else 4 end,
    case when cardinality(a) > 0 then array['rotating_light'] else array['pencil2'] end);
end $$;

revoke execute on function demo_notify(text,int,text,text[],text[],text[]) from public;
grant  execute on function demo_notify(text,int,text,text[],text[],text[]) to anon, authenticated;
