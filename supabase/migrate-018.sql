-- =====================================================================
-- 변경 018: [제출 완료] 시 비고의 "미제출" 문구를 지우고, 원래 비고를 보관(취소하면 되돌림)
--  · doc_submit 에 서류 종류(doc)와 원래 비고(prev_note) 저장
--  · 비고에서 "미제출"이 지워져도 제출 완료 목록에는 계속 보이도록 doc_list 수정
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================
alter table doc_submit add column if not exists doc text;
alter table doc_submit add column if not exists prev_note text;

create or replace function doc_list_raw(p_class int, p_from date, p_to date)
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
  select s.d, s.student_no, st.name, s.kind, s.note, coalesce(doc_kind(s.kind, s.note), ds.doc),
         ds.d is not null, ds.at,
         school_days_between(p_class, s.d, (now() at time zone 'Asia/Seoul')::date)
    from src s
    left join students st on st.class_id = p_class and st.no = s.student_no
    left join doc_submit ds on ds.class_id = p_class and ds.d = s.d and ds.student_no = s.student_no
   where doc_kind(s.kind, s.note) is not null or (ds.d is not null and ds.doc is not null)
   order by s.d, s.student_no
$$;
revoke execute on function doc_list_raw(int, date, date) from public, anon, authenticated;
