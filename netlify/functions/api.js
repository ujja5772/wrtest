// 영어 쓰기 교실 — 서버 함수 (Netlify Functions)
// 넷리파이 환경변수 필요:
//   SUPABASE_URL                예) https://xxxx.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY   Supabase > Project Settings > API Keys 의 service_role(또는 secret) 키
//   UNSPLASH_ACCESS_KEY         (선택) 사진 검색을 쓸 때만

// 위에서부터 차례로 시도하고, 지원하지 않는 모델이면 자동으로 다음 모델로 넘어갑니다.
const MODELS = ['gemini-flash-lite-latest', 'gemini-flash-latest', 'gemini-2.5-flash', 'gemini-2.0-flash'];

const SB_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SB_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
const UNSPLASH = process.env.UNSPLASH_ACCESS_KEY || '';

const json = (status, body) => ({
  statusCode: status,
  headers: { 'Content-Type': 'application/json; charset=utf-8' },
  body: JSON.stringify(body),
});

async function rpc(name, args) {
  const headers = { apikey: SB_KEY, 'Content-Type': 'application/json' };
  if (SB_KEY.startsWith('eyJ')) headers.Authorization = `Bearer ${SB_KEY}`;
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${name}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const text = await r.text();
  let data; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!r.ok) throw new Error((data && data.message) || `데이터베이스 오류 (${r.status})`);
  return data;
}

// ---------- Gemini ----------
async function gemini(keys, { system, contents, asJson, temperature = 0.7 }) {
  if (!keys || !keys.length) throw new Error('학급에 등록된 AI 키가 없어요. 선생님께 알려 주세요.');
  const start = Math.floor(Math.random() * keys.length);
  const order = keys.map((_, i) => keys[(start + i) % keys.length]);
  let lastErr = 'AI 응답을 받지 못했어요.';
  for (const model of MODELS) {
    for (const key of order) {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 9000);
      try {
        const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
          method: 'POST',
          signal: ctrl.signal,
          headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
          body: JSON.stringify({
            systemInstruction: { parts: [{ text: system }] },
            contents,
            generationConfig: { temperature, ...(asJson ? { responseMimeType: 'application/json' } : {}) },
          }),
        });
        const data = await r.json().catch(() => ({}));
        if (r.ok) {
          const text = (data.candidates?.[0]?.content?.parts || []).map(p => p.text || '').join('').trim();
          if (text) return text;
          lastErr = 'AI가 빈 답을 보냈어요.';
          continue;
        }
        const msg = data.error?.message || '';
        lastErr = `${model}: ${msg || r.status}`;
        // 모델이 없거나 지원 안 함 → 다음 모델로
        if (r.status === 404 || /not found|not supported/i.test(msg)) break;
        // 키 문제·사용량 초과 → 다음 키로
      } catch (e) {
        lastErr = e.name === 'AbortError' ? 'AI 응답이 너무 오래 걸려요.' : e.message;
      } finally {
        clearTimeout(timer);
      }
    }
  }
  throw new Error(lastErr);
}

function parseJson(text) {
  const clean = String(text).replace(/```json|```/g, '').trim();
  const s = clean.indexOf('{');
  const e = clean.lastIndexOf('}');
  return JSON.parse(s >= 0 ? clean.slice(s, e + 1) : clean);
}

const lines = s => String(s || '').split(/\n|,/).map(x => x.trim()).filter(Boolean);
const nlines = s => String(s || '').split('\n').map(x => x.trim()).filter(Boolean);

function classBlock(ctx) {
  return [
    `학생: 초등학교 ${ctx.grade || ''}학년, 영어 학습자(초급).`,
    `단원: ${ctx.unit_name || '(없음)'}`,
    `쓰기 주제: ${ctx.topic || '(없음)'}`,
    `교사가 정한 단어: ${lines(ctx.words).join(', ') || '(없음)'}`,
    `교사가 정한 핵심 표현(글에 꼭 들어가야 함): ${nlines(ctx.key_expressions).join(' / ') || '(없음)'}`,
  ].join('\n');
}

function chatTranscript(history) {
  return (history || []).slice(-24)
    .map(m => `${m.role === 'user' ? '학생' : 'AI'}: ${String(m.text || '').slice(0, 400)}`).join('\n');
}

// ---------- 과제별 처리 ----------
async function taskWords(ctx) {
  const system = `너는 초등학생 영어 선생님이다. JSON으로만 답한다.
${classBlock(ctx)}
주제와 관련된 쉬운 새 영어 단어 8개를 고른다. 교사가 정한 단어와 겹치면 안 된다.
각 단어마다 한국어 뜻과, 초등학생 수준의 아주 짧은 예시 문장(문법 오류 없음)을 준다.
형식: {"words":[{"word":"","meaning":"","example":""}]}`;
  const out = parseJson(await gemini(ctx.keys, { system, contents: [{ role: 'user', parts: [{ text: '단어를 만들어 주세요.' }] }], asJson: true }));
  return { words: (out.words || []).slice(0, 10) };
}

async function taskLookup(ctx, p) {
  const q = String(p.query || '').slice(0, 60);
  const system = `너는 초등학생용 영어 단어 도우미다. JSON으로만 답한다.
${classBlock(ctx)}
학생이 찾는 말(한국어 또는 영어)에 맞는 쉬운 영어 표현을 1~3개 준다. 각각 한국어 뜻과 주제에 어울리는 짧은 예시 문장을 준다.
부적절한 말이면 빈 배열을 준다.
형식: {"items":[{"word":"","meaning":"","example":""}]}`;
  const out = parseJson(await gemini(ctx.keys, { system, contents: [{ role: 'user', parts: [{ text: q }] }], asJson: true, temperature: 0.3 }));
  return { items: (out.items || []).slice(0, 3) };
}

async function taskChat(ctx, p) {
  const history = (p.history || []).slice(-24);
  const turn = history.filter(m => m.role === 'user').length;
  const maxTurns = 6;
  const system = `너는 초등학생과 영어로 대화하며 글쓰기를 준비시키는 친절한 AI 선생님이다.
${classBlock(ctx)}

[교사의 대화 가이드 — 가장 먼저 따를 것]
${ctx.guide || '쓰기 주제에 대해 학생이 좋아하는 것, 이유, 자세한 내용, 느낌을 차례로 물어본다.'}

규칙:
1. 대화 가이드에 나온 주제를 빠짐없이 하나씩 차례로 묻는다. 한 주제마다 "고르기 → 이유 → 자세히 → 느낌" 순서로 학생의 답을 따라간다. 한 주제를 너무 오래 끌지 말고, 남은 대화 수 안에 가이드의 주제를 모두 다룰 수 있게 조절한다.
2. 가이드와 쓰기 주제 밖의 이야기(예: 음식 맛의 세부, 관계없는 잡담)는 묻지 않는다. 학생이 벗어나면 짧게 반응하고 다시 주제로 돌아온다.
3. 한 번에 질문은 하나만. 영어 문장은 짧고 쉽게(1~2문장). 질문 아래 줄에 괄호로 짧은 한국어 도움말을 붙인다.
4. 학생이 한국어로 답하거나 영어가 서툴면, 그 뜻을 영어로 어떻게 말하는지 예시("You can say: ...")를 알려 준 뒤 다음 질문을 한다.
5. 학생의 영어가 틀려도 혼내지 말고, 바른 문장으로 자연스럽게 되받아 준다.
6. 이모지는 1개 이하. 전체 답은 4줄 이내.
7. 지금은 학생의 ${turn}번째 대답 차례까지 왔다(최대 ${maxTurns}번).${turn >= maxTurns ? ' 이번이 마지막이다. 질문하지 말고 칭찬과 함께 "이제 쓰기 단계로 가요!" 라고 마무리한다.' : ''}`;
  let contents;
  if (!history.length || p.start) {
    contents = [{ role: 'user', parts: [{ text: '(대화를 시작해 주세요. 반갑게 인사하고 가이드의 첫 질문을 하세요.)' }] }];
  } else {
    contents = history.map(m => ({ role: m.role === 'user' ? 'user' : 'model', parts: [{ text: String(m.text || '').slice(0, 500) }] }));
    if (contents[0].role === 'model') contents.unshift({ role: 'user', parts: [{ text: '(대화 시작)' }] });
  }
  const reply = await gemini(ctx.keys, { system, contents });
  rpc('svc_log', { p_code: p.class_code, p_kind: 'chat' }).catch(() => {});
  return { reply };
}

async function taskHint(ctx, p) {
  const system = `너는 초등학생의 영어 글쓰기를 돕는 선생님이다. JSON으로만 답한다.
${classBlock(ctx)}

아래 대화에서 학생이 실제로 말한 사실만 이용해, 빈칸(____)이 있는 영어 예시 문장들을 만든다.
규칙:
- 학생이 말하지 않은 사실을 지어내지 않는다.
- 한 문장에 서로 다른 주제(예: 음식과 동물)를 섞지 않는다.
- 교사 핵심 표현이 있으면 반드시 그 표현을 쓴 문장을 포함한다. 교사 표현 안의 괄호 ( ) 부분은 빈칸(____)으로 바꾼다.
- 같은 표현이나 같은 답을 쓴 문장은 하나만 남긴다.
- 빈칸에는 학생이 대화에서 말한 낱말이 들어가게 하고, 그 낱말을 answer에 적는다(한국어로 말했으면 알맞은 영어 낱말).
- 관사, 복수형, 동사 형태 등 문법 오류가 없어야 한다. 문장은 짧고 자연스럽게.
- 문장 수 제한은 없지만, 순서대로 이어 읽으면 연결된 한 단락이 되게 한다(첫 문장은 주제를 소개, 마지막은 느낌이나 마무리).
- 각 문장마다 한국어 뜻(ko)을 짧게 붙인다.
형식: {"sentences":[{"template":"I like ____ .","answer":["math"],"ko":"나는 수학을 좋아해요."}]}`;
  const out = parseJson(await gemini(ctx.keys, {
    system, asJson: true, temperature: 0.4,
    contents: [{ role: 'user', parts: [{ text: `대화 내용:\n${chatTranscript(p.history) || '(대화 없음 — 주제와 핵심 표현만으로 만들기)'}` }] }],
  }));
  const sentences = (out.sentences || [])
    .filter(s => s && typeof s.template === 'string')
    .map(s => ({ template: s.template.replace(/_{2,}/g, '____'), answer: Array.isArray(s.answer) ? s.answer : [], ko: s.ko || '' }))
    .slice(0, 12);
  return { sentences };
}

async function taskFeedback(ctx, p) {
  const text = String(p.text || '').trim().slice(0, 2000);
  if (text.length < 5) throw new Error('글이 너무 짧아요.');
  const system = `너는 초등학생 영어 글을 첨삭하는 다정한 선생님이다. JSON으로만 답한다.
${classBlock(ctx)}
교사의 평가 기준: ${ctx.criteria || '주제에 맞는 내용, 핵심 표현 사용, 문법과 철자, 문장 연결'}

해야 할 일:
1. annotated: 학생 글 원문을 그대로 옮기되, 잘한 부분은 [[good:잘한 부분]], 고쳐야 할 부분은 [[fix:틀린 부분=>고친 부분]] 으로 감싼다. 표시 밖의 글자는 원문과 똑같이 둔다. 잘한 점을 먼저 충분히 찾아 준다.
2. praise: 잘한 점 2~3개 (한국어, 초등학생이 이해하는 말).
3. fixes: 고칠 점 목록 [{"wrong":"","right":"","why":"한국어 짧은 이유"}] (최대 5개, 가장 중요한 것부터).
4. grade: "상", "중", "하" 중 하나. 평가 기준과 핵심 표현 사용 여부를 반영한다.
5. report: 교사가 통지표에 쓸 수 있는 한국어 한 문장(학생 이름 없이, "~함." 체).
6. rewritten: 학생의 내용과 생각을 살려 문법을 바로잡고, 문장들이 자연스럽게 이어지는 한 단락으로 고쳐 쓴 글. 학생 수준을 넘는 어려운 단어는 쓰지 않는다. 핵심 표현이 빠졌다면 넣는다.
7. cheer: 학생에게 주는 한국어 응원 한 문장.
형식: {"annotated":"","praise":[],"fixes":[],"grade":"","report":"","rewritten":"","cheer":""}`;
  const out = parseJson(await gemini(ctx.keys, {
    system, asJson: true, temperature: 0.3,
    contents: [{ role: 'user', parts: [{ text: `학생 글:\n${text}` }] }],
  }));
  const grade = ['상', '중', '하'].includes(out.grade) ? out.grade : '중';
  const feedback = {
    annotated: String(out.annotated || text),
    praise: (out.praise || []).slice(0, 4),
    fixes: (out.fixes || []).slice(0, 6),
    rewritten: String(out.rewritten || ''),
    cheer: String(out.cheer || ''),
  };
  const photo = p.photo || {};
  const saved = await rpc('svc_save_submission', {
    p_code: p.class_code, p_no: p.student_no, p_pin: p.pin,
    d: {
      mode: p.mode || '', text, feedback, grade, report: String(out.report || ''),
      photo_path: photo.path || null, photo_url: photo.url || null,
      photo_credit: photo.credit || null, photo_credit_link: photo.credit_link || null,
    },
  });
  return { feedback, grade, report: out.report || '', saved };
}

// ---------- Unsplash ----------
async function photoSearch(ctx, p) {
  if (!ctx.photo_search_enabled) return { disabled: true, results: [] };
  if (!UNSPLASH) return { disabled: true, results: [] };
  const q = String(p.query || '').slice(0, 50);
  const hangul = /[가-힣]/.test(q);
  const url = `https://api.unsplash.com/search/photos?per_page=12&content_filter=high&query=${encodeURIComponent(q)}${hangul ? '&lang=ko' : ''}`;
  const r = await fetch(url, { headers: { Authorization: `Client-ID ${UNSPLASH}`, 'Accept-Version': 'v1' } });
  if (!r.ok) throw new Error('사진 검색이 잠시 안 돼요. 파일 올리기를 써 주세요.');
  const d = await r.json();
  return {
    results: (d.results || []).map(x => ({
      id: x.id,
      thumb: x.urls?.small,
      url: x.urls?.regular,
      alt: x.alt_description || '',
      author: x.user?.name || 'Unsplash',
      author_link: `${x.user?.links?.html || 'https://unsplash.com'}?utm_source=english_writing_class&utm_medium=referral`,
      download_location: x.links?.download_location,
    })),
  };
}

async function photoTrack(p) {
  const loc = String(p.download_location || '');
  if (!UNSPLASH || !loc.startsWith('https://api.unsplash.com/')) return { ok: false };
  await fetch(loc, { headers: { Authorization: `Client-ID ${UNSPLASH}` } }).catch(() => {});
  return { ok: true };
}

async function testKey(p) {
  const key = String(p.key || '').trim();
  const text = await gemini([key], { system: 'Answer with one word.', contents: [{ role: 'user', parts: [{ text: 'Say OK.' }] }], temperature: 0 });
  return { ok: !!text };
}

// ---------- 진입점 ----------
exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'POST only' });
  if (!SB_URL || !SB_KEY) return json(500, { error: '서버 설정(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)이 비어 있어요.' });
  let p;
  try { p = JSON.parse(event.body || '{}'); } catch { return json(400, { error: '잘못된 요청이에요.' }); }
  try {
    if (p.action === 'test_key') return json(200, await testKey(p));
    if (p.action === 'photo_track') return json(200, await photoTrack(p));

    const ctx = await rpc('svc_ai_context', { p_code: p.class_code, p_no: Number(p.student_no), p_pin: p.pin });
    switch (p.action) {
      case 'words': return json(200, await taskWords(ctx));
      case 'lookup': return json(200, await taskLookup(ctx, p));
      case 'chat': return json(200, await taskChat(ctx, p));
      case 'hint': return json(200, await taskHint(ctx, p));
      case 'feedback': return json(200, await taskFeedback(ctx, p));
      case 'photo_search': return json(200, await photoSearch(ctx, p));
      default: return json(400, { error: '알 수 없는 요청이에요.' });
    }
  } catch (e) {
    return json(500, { error: e.message || '서버 오류가 났어요.' });
  }
};
