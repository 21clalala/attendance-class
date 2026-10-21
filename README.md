# 3-2 수업 출결 체크 — 설치 안내

## 파일 구성
| 파일 | 용도 |
|---|---|
| `index.html` | 교과선생님 페이지 (QR로 접속) |
| `admin.html` | 담임 관리자 페이지 (로그인) |
| `config.js` | Supabase 주소·공개 키 |
| `neis-parse.js` | 나이스 일일출석부 엑셀 해석 |
| `supabase/schema.sql` | DB 테이블·함수·권한 (Supabase에서 한 번 실행) |

GitHub에 올라가는 파일에는 학생 정보가 없습니다. 명단과 출결은 모두 Supabase에만 저장됩니다.

---

## 1. Supabase 프로젝트 만들기
1. Supabase 대시보드 → **New project**
   - Region: **Northeast Asia (Seoul)**
   - DB 비밀번호는 아무 값이나 저장해 두기
2. 만들어질 때까지 1~2분 기다리기

## 2. DB 설치
1. 왼쪽 **SQL Editor** → New query
2. `supabase/schema.sql` 전체를 붙여 넣기
3. **맨 아래 줄**의 `여기에_관리자_이메일@example.com`을 본인 이메일로 바꾸기
4. **Run** → "Success" 확인

## 3. 관리자 계정 만들기
1. **Authentication → Users → Add user → Create new user**
   - 2번에서 넣은 이메일, 비밀번호 입력
   - **Auto Confirm User** 체크
2. **Authentication → Sign In / Providers**에서 **Allow new users to sign up** 끄기
   (다른 사람이 계정을 만들 수 없게. 만들어도 관리자 권한은 없지만 막아 두는 게 깔끔합니다)

## 4. config.js 채우기
**Project Settings → API Keys**에서
- Project URL → `SUPABASE_URL`
- Publishable key(또는 legacy anon key) → `SUPABASE_KEY`

> secret / service_role 키는 절대 넣지 마세요.

## 5. 페이지 주소 (GitHub Pages, `21clalala/attendance-class` 저장소)
- 관리자: `https://21clalala.github.io/attendance-class/admin.html`
- 교과선생님: 관리자 페이지 **설정·QR** 탭에 나오는 주소 (`…/attendance-class/?k=…`)
- `config.js`를 고치면 1~2분 뒤 반영됩니다.

## 6. 처음 설정 (관리자 페이지)
1. **시간표·시정** 탭: 요일×교시 선생님 이름 입력 → 저장
   (시정표와 요일별 교시 수는 월·화 7교시, 수·목·금 6교시로 미리 들어가 있음)
2. **설정·QR** 탭
   - 휴대폰 **ntfy** 앱 설치 → `+` → 화면의 토픽 이름 그대로 구독
   - **테스트 알림** → 휴대폰에 오는지 확인
   - **QR 인쇄** → 종이 출석부에 부착

## 7. 매일 사용
- 아침(또는 중간에): 나이스 **일일출석부** 엑셀 내려받기 → **나이스 업로드** 탭 → 미리보기 확인 → 적용
- 교체·대강, 단축수업, 휴업일: **날짜별 변경** 탭
- 확인: **출석부** 탭 (교과선생님 입력이 실시간 반영, 빨간 "/"를 누르면 삭제)

---

## 동작 규칙
- 교시는 **수업 시간 안에서만** 열립니다 (예: 3교시 10:50~11:40). 쉬는 시간·점심시간엔 입력 불가.
- 시각 판단은 Supabase 서버의 한국 시간 기준 (태블릿 시계와 무관).
- 나이스에서 이미 "/"인 칸, `(위탁)` 학생은 교과선생님이 입력할 수 없습니다.
- 교과선생님은 "/"만 보이고, 결석 유형·비고는 관리자 화면에서만 보입니다.
- 저장 1번에 알림 최대 2건: 새로 없는 학생(긴급) / 정정(보통).
- 관리자 화면에서 교과선생님 입력을 삭제할 때는 알림이 가지 않습니다.

## 알아 둘 점
- **Free 프로젝트는 7일간 사용이 없으면 일시정지**됩니다. 방학이 끝나면 대시보드에서 Resume 하세요.
- QR이 학생에게 노출되면 **설정·QR → 주소 새로 만들기** 후 QR을 다시 인쇄하세요.
- ntfy 공용 서버를 거치므로 알림 내용(번호·이름)은 토픽 이름을 아는 사람만 볼 수 있습니다. 토픽 이름은 추측할 수 없게 자동 생성되어 있습니다.
