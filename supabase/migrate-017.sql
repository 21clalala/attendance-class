-- =====================================================================
-- 변경 017: 증빙서류 3종 — 출결신고서 / 응시확인증 / 보고서
--  · 비고에 "응시확인증 미제출" → 응시확인증, "보고서 미제출" → 보고서, "(출결신고서) 미제출" → 출결신고서
--  · 그냥 "미제출"만 적힌 경우: 출석인정 중 대학별고사·면접·논술·실기 등 → 응시확인증,
--    교외체험학습 → 보고서, 그 밖에 신고서가 필요한 경우(질병, 출석인정 생리통·경조사·법정감염병) → 출결신고서
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

create or replace function doc_kind(p_kind text, p_note text) returns text
language sql immutable as $$
  select case
    when n !~ '미제출' then null
    when n ~ '응시확인증미제출' then '응시확인증'
    when n ~ '보고서미제출' then '보고서'
    when n ~ '신고서미제출' then '출결신고서'
    when cat like '출석인정%' and n ~ '(대학별고사|대학별|수시|면접|논술|실기|적성고사|응시|입시|전형)' then '응시확인증'
    when cat like '출석인정%' and n ~ '(체험학습|교외체험|현장체험)' then '보고서'
    when doc_needed(p_kind, p_note) then '출결신고서'
    else null end
  from (select regexp_replace(coalesce(p_note, ''), '\s', '', 'g') n,
               coalesce(nullif(btrim(p_kind), ''), btrim(coalesce(p_note, ''))) cat) x
$$;

-- 알림·목록에 보일 "종류(사유)" — 미제출 문구는 뺌
create or replace function doc_label(p_kind text, p_note text) returns text
language sql immutable as $$
  select case when n = '' then coalesce(p_kind, '')
              when p_kind is null or p_kind = '' or n like p_kind || '%' then n
              else p_kind || '(' || n || ')' end
    from (select btrim(regexp_replace(coalesce(p_note, ''), '\s*(출결신고서|신고서|응시확인증|보고서)?\s*미제출\s*', ' ', 'g')) n) x
$$;

drop function if exists doc_list(int, date, date);
drop function if exists doc_list_raw(int, date, date);

create function doc_list_raw(p_class int, p_from date, p_to date)
returns table(d date, student_no int, name text, kind text, note text, doc text, submitted boolean, submitted_at timestamptz, elapsed int)
language sql stable security definer set search_path = public as $$
  with src as (
    select coalesce(m.class_id, n.class_id) class_id, coalesce(m.d, n.d) d, coalesce(m.student_no, n.student_no) student_no,
           case when m.student_no is not null then m.kind else n.kind end kind,
           case when m.student_no is not null then m.note else n.note end note
      from (select * from day_manual where class_id = p_class and d between p_from and p_to) m
      full join (select * from neis_day where class_id = p_class and d between p_from and p_to) n
        on n.d = m.d and n.student_no = m.student_no
  )
  select s.d, s.student_no, st.name, s.kind, s.note, doc_kind(s.kind, s.note),
         ds.d is not null, ds.at,
         school_days_between(p_class, s.d, (now() at time zone 'Asia/Seoul')::date)
    from src s
    left join students st on st.class_id = p_class and st.no = s.student_no
    left join doc_submit ds on ds.class_id = p_class and ds.d = s.d and ds.student_no = s.student_no
   where doc_kind(s.kind, s.note) is not null
   order by s.d, s.student_no
$$;
revoke execute on function doc_list_raw(int, date, date) from public, anon, authenticated;

create function doc_list(p_class int, p_from date, p_to date)
returns table(d date, student_no int, name text, kind text, note text, doc text, submitted boolean, submitted_at timestamptz, elapsed int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_manage(p_class) then raise exception 'forbidden'; end if;
  return query select * from doc_list_raw(p_class, p_from, p_to);
end $$;
revoke execute on function doc_list(int, date, date) from public, anon;
grant execute on function doc_list(int, date, date) to authenticated;

-- 아침 알림: 서류 종류도 함께
create or replace function send_doc_alerts() returns int
language plpgsql security definer set search_path = public as $$
declare
  c classes; v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_lines text[]; v_cnt int; v_sent int := 0;
begin
  for c in select * from classes where coalesce(ntfy_topic, '') <> '' loop
    if not exists (select 1 from schedule_for(c.id, v_today)) then continue; end if;
    select array_agg(format('%s/%s %s번 %s · %s · %s · %s일 경과', extract(month from l.d), extract(day from l.d), l.student_no, coalesce(l.name, ''),
                            l.doc, doc_label(l.kind, l.note), l.elapsed) order by l.d, l.student_no),
           count(*)
      into v_lines, v_cnt
      from doc_list_raw(c.id, v_today - 180, v_today - 1) l
     where not l.submitted and l.elapsed >= 1;
    if coalesce(v_cnt, 0) = 0 then continue; end if;
    perform notify_ntfy(c.ntfy_topic, c.label || ' 증빙서류 미제출 ' || v_cnt || '건',
                        array_to_string(v_lines, E'\n'), 3, array['page_facing_up']);
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end $$;
revoke execute on function send_doc_alerts() from public, anon, authenticated;
