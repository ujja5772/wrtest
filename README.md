# 오늘의 영어 쓰기 (Today's English Writing) — 설치 안내

학생(`/`), 교사(`/teacher`), 관리자(`/admin`) 세 화면이 있는 영어 쓰기 웹앱입니다.
넷리파이(무료) + Supabase(무료) + Gemini(무료 키) + Unsplash(선택, 무료)로 돌아갑니다.

## 들어 있는 파일

| 파일 | 하는 일 |
|---|---|
| `index.html` | 앱 화면 전체 (학생·교사·관리자) |
| `netlify/functions/api.js` | 서버 함수: Gemini AI(대화·단어·예시 문장·첨삭), Unsplash 사진 검색 |
| `netlify.toml` | 넷리파이 설정 (`/teacher`, `/admin` 주소 연결) |
| `supabase/schema.sql` | 데이터베이스 표·보안 함수·사진 저장소를 한 번에 만드는 SQL |
| `supabase/update-v4.sql` | 모든 학급의 AI 키를 한곳에서 관리하는 SQL. `update-v3.sql` 다음에 실행 |
| `supabase/update-v3.sql` | 천천히 쓰기·바로 쓰기의 첨삭과 게시를 따로 저장하는 SQL. `update-v2.sql` 다음에 실행 |
| `supabase/update-v2.sql` | v2 기능(교사 단원, 여러 학년 학급, 첨삭→다듬기→게시, 의견함)을 더하는 SQL. `schema.sql` 다음에 실행 |

## 1. Supabase 준비 (10분)

1. **새 Supabase 프로젝트**를 만드세요. 이미 쓰는 프로젝트에 `submissions` 같은 같은 이름의 표가 있으면 충돌할 수 있어서 새 프로젝트를 권해요.
2. 왼쪽 메뉴 **SQL Editor → New query**에 `supabase/schema.sql` 내용을 전부 붙여 넣고 **Run**. 이어서 `supabase/update-v2.sql`, `update-v3.sql`, `update-v4.sql`도 차례로 같은 방법으로 **Run**.
   `Success. No rows returned`가 나오면 끝입니다.
3. **Project Settings → API Keys**에서 세 가지를 메모하세요.
   - Project URL (예: `https://abcd.supabase.co`)
   - `anon`(또는 `publishable`) 키 → 공개돼도 되는 키
   - `service_role`(또는 `secret`) 키 → **절대 index.html에 넣지 마세요.** 넷리파이 환경변수에만 넣어요.

## 2. index.html 두 줄 바꾸기

`index.html`에서 `const CONFIG` 부분을 찾아 두 줄만 바꿔요.

```js
SUPABASE_URL: 'https://abcd.supabase.co',
SUPABASE_ANON_KEY: 'anon 또는 publishable 키',
```

따옴표와 쉼표는 지우지 마세요.

## 3. GitHub → 넷리파이 배포

1. GitHub 새 저장소에 폴더 구조 그대로 올려요 (`netlify/functions/api.js` 경로가 중요해요).
2. 넷리파이 **Add new site → Import an existing project → GitHub** → 저장소 선택.
   Build command는 비워 두고, Publish directory는 `.` 그대로 두면 됩니다.
3. **Site configuration → Environment variables**에 추가:

| 이름 | 값 |
|---|---|
| `SUPABASE_URL` | Supabase Project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role(secret) 키 |
| `UNSPLASH_ACCESS_KEY` | (선택) Unsplash Access Key |

4. 환경변수를 넣은 뒤에는 **Deploys → Trigger deploy → Deploy site**로 한 번 더 배포해야 반영돼요.

## 4. 처음 쓰는 순서

1. `내사이트주소/admin` → 마스터 PIN **1234**로 로그인 → ⚙️ 설정에서 **PIN부터 바꾸기**. 교사 가입 코드(기본 `teacher2026`)도 확인·변경.
2. `내사이트주소/teacher` → "처음 오셨나요?"에서 가입 코드, 학교 이름(예: 행복초등학교), 학년, 반을 골라 학급 만들기.
3. 🔑 AI 키 등록 → Google AI Studio에서 키 발급 → 등록 → "모든 학급에 이 키 공유".
4. 🛠️ 교사 관리 → 학습 활동 설정(주제, AI 대화 가이드, 핵심 표현, 단어, 평가 기준) 저장.
5. 학생에게 `내사이트주소`와 학급 코드(예: `행복초등학교-5-1`)를 알려 주면 끝.

## 문제가 생기면

- **학생 화면에 "CONFIG에 Supabase 주소와 키를 넣어 주세요"** → 2단계 확인.
- **AI 기능에서 "서버 설정이 비어 있어요"** → 넷리파이 환경변수 이름 철자 확인 후 다시 배포.
- **AI 기능에서 404** → `netlify/functions/api.js` 폴더 경로가 맞는지 확인. 앱은 `/.netlify/functions/api` 주소를 직접 부릅니다.
- **"AI 응답이 너무 오래 걸려요"** → 넷리파이 무료 서버 함수는 약 10초 제한이 있어요. 잠시 뒤 다시 누르면 대부분 해결돼요.
- **모델을 바꾸고 싶을 때** → `api.js` 맨 위 `MODELS` 목록의 순서를 바꾸거나 모델 이름을 추가하세요. 없는 모델이면 자동으로 다음 모델로 넘어가요.

## 알아 두면 좋은 점

- 학생의 PIN, 교사 비밀번호, 관리자 PIN은 데이터베이스에 암호화되어 저장되고, 확인은 모두 서버(Supabase 함수)에서 해요.
- 모든 표는 브라우저에서 직접 읽고 쓸 수 없게 막혀 있고, 정해진 함수로만 접근해요.
- 대화 기록, 쓰던 글(천천히 쓰기·바로 쓰기 따로), 대화·첨삭 횟수는 학생 기기의 브라우저에 저장돼요. 같은 크롬북·같은 계정으로 들어오면 이어서 할 수 있어요.
- 학급이 삭제돼도 Supabase Storage의 사진 파일은 남아요. 용량이 걱정되면 Storage → `student-photos`에서 정리해 주세요.
