-- =====================================================================
-- 변경 016: 출결신고서 대상 기준을 신고서 양식 기준으로 맞춤
--  · 질병(결석·지각·조퇴·결과) 전부
--  · 출석인정 중 생리통·경조사·법정감염병(코로나19·인플루엔자 등)만
--  · 미인정·기타, 그 밖의 출석인정(대회 등)은 신고서가 필요 없어 제외
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

create or replace function doc_needed(p_kind text, p_note text) returns boolean
language sql immutable as $$
  select case
    when coalesce(nullif(btrim(p_kind), ''), btrim(coalesce(p_note, ''))) like '질병%' then true
    when coalesce(nullif(btrim(p_kind), ''), btrim(coalesce(p_note, ''))) like '출석인정%'
      then regexp_replace(coalesce(p_note, ''), '\s', '', 'g') ~ '(생리|경조|조문|장례|사망|결혼|혼례|[부모형제매자손]상|조부|조모|외조|코로나|인플루엔자|독감|법정|감염)'
    else false end
$$;

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
     and doc_needed(s.kind, s.note)
   order by s.d, s.student_no
$$;
revoke execute on function doc_list_raw(int, date, date) from public, anon, authenticated;
