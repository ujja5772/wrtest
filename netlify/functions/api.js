// 영어 쓰기 교실 — 서버 함수 (Netlify Functions)
// 넷리파이 환경변수 필요:
//   SUPABASE_URL                예) https://xxxx.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY   Supabase > Project Settings > API Keys 의 service_role(또는 secret) 키
//   UNSPLASH_ACCESS_KEY         (선택) 사진 검색을 쓸 때만

// 위에서부터 차례로 시도하고, 없어졌거나 지원하지 않는 모델이면 자동으로 다음 모델로 넘어갑니다.
// (2026년 9월 기준: Gemini 2.x 모델은 종료되어 3.x 모델만 씁니다. 구글이 모델을 바꾸면 이 목록만 고치면 돼요.)
// 빠른 일(대화, 단어 찾기, 뜻 보기)
const MODELS = ['gemini-3.5-flash-lite', 'gemini-flash-lite-latest', 'gemini-3.1-flash-lite', 'gemini-3.7-flash', 'gemini-flash-latest', 'gemini-3.8-flash'];
// 대화: 한국어 도움말을 바르게 쓰도록 Flash부터 (Flash-Lite는 한국어 맞춤법 실수가 잦아요)
const CHAT_MODELS = ['gemini-3.7-flash', 'gemini-flash-latest', 'gemini-3.8-flash', 'gemini-3.5-flash-lite', 'gemini-flash-lite-latest'];
// 정확해야 하는 일(첨삭, 예시 문장)
const CAREFUL_MODELS = ['gemini-3.7-flash', 'gemini-3.8-flash', 'gemini-flash-latest', 'gemini-3.5-flash-lite', 'gemini-flash-lite-latest'];

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
// 서버가 켜져 있는 동안 기억해 두는 것들 (수업 중 반복 요청을 빠르게)
const workingModel = {};         // 목록별로 마지막에 성공한 모델 → 다음엔 바로 그 모델부터
const goneModels = new Set();    // 없어진 모델은 다시 시도하지 않음
const noThinking = new Set();    // 생각 설정을 받지 않는 모델
const keyCooldown = new Map();   // 사용량 초과(429)가 난 키는 잠시 쉬게 함

// keys: 배열(무료 키만) 또는 { free: [...], paid: [...] }
// 무료 키를 먼저 번갈아 쓰고, 무료 키가 모두 막히거나 쉬는 중일 때만 유료 키를 써요.
async function gemini(keys, { system, contents, asJson, models = MODELS }) {
  const free = Array.isArray(keys) ? keys : (keys?.free || []);
  const paid = Array.isArray(keys) ? [] : (keys?.paid || []);
  if (!free.length && !paid.length) throw new Error('학급에 등록된 AI 키가 없어요. 선생님께 알려 주세요.');
  const listKey = models.join('|');
  const now = Date.now();
  const restedFree = free.filter(k => (keyCooldown.get(k) || 0) < now);
  const freePool = restedFree.length ? restedFree : (paid.length ? [] : free);
  const start = Math.floor(Math.random() * Math.max(1, freePool.length));
  const order = [...freePool.map((_, i) => freePool[(start + i) % freePool.length]), ...paid];
  const tryModels = [...new Set([workingModel[listKey], ...models].filter(Boolean))].filter(m => !goneModels.has(m));
  const deadline = Date.now() + 9300; // 넷리파이 무료 함수는 10초 안에 끝나야 해요
  let modelErr = '', otherErr = '';
  const isModelGone = (status, msg) => status === 404 || /not found|not supported for|no longer available|deprecated/i.test(msg);

  for (const model of tryModels) {
    for (let k = 0; k < order.length; k++) {
      const key = order[k];
      const left = deadline - Date.now();
      if (left < 1200) throw new Error(otherErr ? `AI 응답을 받지 못했어요. (${otherErr})` : 'AI 응답이 늦어요. 잠시 뒤 다시 눌러 주세요.');
      const thinking = noThinking.has(model) ? null : { thinkingLevel: 'low' };
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), left);
      try {
        const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
          method: 'POST',
          signal: ctrl.signal,
          headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
          body: JSON.stringify({
            systemInstruction: { parts: [{ text: system }] },
            contents,
            generationConfig: {
              ...(asJson ? { responseMimeType: 'application/json' } : {}),
              ...(thinking ? { thinkingConfig: thinking } : {}), // 빠르게 답하도록 생각은 최소로
            },
          }),
        });
        const data = await r.json().catch(() => ({}));
        if (r.ok) {
          const text = (data.candidates?.[0]?.content?.parts || []).filter(p => !p.thought).map(p => p.text || '').join('').trim();
          if (text) { workingModel[listKey] = model; return text; }
          otherErr = 'AI가 빈 답을 보냈어요.';
          continue;
        }
        const msg = data.error?.message || String(r.status);
        if (thinking && r.status === 400 && /thinking/i.test(msg)) { noThinking.add(model); k--; continue; }
        if (isModelGone(r.status, msg)) { goneModels.add(model); modelErr = `${model}: ${msg}`; break; }
        if (r.status === 429 || /quota|exhausted|rate/i.test(msg)) keyCooldown.set(key, Date.now() + 60000);
        otherErr = msg; // 키 문제·사용량 초과 → 다음 키로
      } catch (e) {
        otherErr = e.name === 'AbortError' ? 'AI 응답이 너무 오래 걸려요.' : e.message;
      } finally {
        clearTimeout(timer);
      }
    }
  }
  if (/API key|API_KEY|permission|unauthori|invalid authentication|credentials/i.test(otherErr)) {
    throw new Error('AI 키가 맞지 않아요. 키를 끝까지 복사했는지 확인해 주세요. (' + otherErr.slice(0, 160) + ')');
  }
  if (/quota|rate|exhausted|429/i.test(otherErr)) {
    throw new Error('지금 AI 사용량이 몰렸어요. 10초쯤 뒤 다시 눌러 주세요. (다른 구글 계정의 키를 더 등록하면 나눠 쓸 수 있어요.)');
  }
  throw new Error(otherErr || modelErr || 'AI 응답을 받지 못했어요.');
}

function parseJson(text) {
  const clean = String(text).replace(/```json|```/g, '').trim();
  const s = clean.indexOf('{');
  const e = clean.lastIndexOf('}');
  return JSON.parse(s >= 0 ? clean.slice(s, e + 1) : clean);
}

// 학생이 키보드로 칠 수 없는 둥근 따옴표·긴 대시 등을 일반 글자로 바꿈
const plain = s => String(s || '')
  .replace(/[\u2018\u2019\u201A\u2032\u02BC\u0060\u00B4]/g, "'")
  .replace(/[\u201C\u201D\u201E\u2033]/g, '"')
  .replace(/[\u2013\u2014\u2212]/g, '-')
  .replace(/\u2026/g, '...')
  .replace(/[\u00A0\u2007\u202F\u200B]/g, ' ');
const lines = s => String(s || '').split(/\n|,/).map(x => x.trim()).filter(Boolean);
const nlines = s => String(s || '').split('\n').map(x => x.trim()).filter(Boolean);

function classBlock(ctx) {
  return [
    `학생: 초등학교 ${ctx.grade || ''}학년, 영어 학습자(초급).`,
    `단원: ${ctx.unit_name || '(없음)'}`,
    `쓰기 주제: ${ctx.topic || '(없음)'}`,
    `단어: ${lines(ctx.words).join(', ') || '(없음)'}`,
    `핵심 표현(글에 꼭 들어가야 함): ${nlines(ctx.key_expressions).join(' / ') || '(없음)'}`,
  ].join('\n');
}

function chatTranscript(history) {
  return (history || []).slice(-24)
    .map(m => `${m.role === 'user' ? '학생' : 'AI'}: ${String(m.text || '').slice(0, 400)}`).join('\n');
}

// ---------- 과제별 처리 ----------
async function taskWords(ctx) {
  const keys = nlines(ctx.key_expressions);
  const system = `너는 초등학생 영어 선생님이다. JSON으로만 답한다.
${classBlock(ctx)}
1. words: 주제와 관련된 쉬운 새 영어 단어 8개. 위에 적힌 단어와 겹치면 안 된다. 각 단어의 한국어 뜻, 초등학생 수준의 아주 짧은 예시 문장(문법 오류 없음).
2. key_ko: 아래 핵심 표현 각각의 자연스럽고 짧은 한국어 해석. 괄호 ( ) 부분은 해석에서도 ( )로 남긴다. 순서와 개수를 그대로 지킨다.
핵심 표현 목록:
${keys.map((k, i) => `${i + 1}. ${k}`).join('\n') || '(없음)'}
형식: {"words":[{"word":"","meaning":"","example":""}],"key_ko":[""]}`;
  const out = parseJson(await gemini(ctx.keys, { system, contents: [{ role: 'user', parts: [{ text: '만들어 주세요.' }] }], asJson: true }));
  return {
    words: (out.words || []).slice(0, 10).map(w => ({ word: plain(w.word), meaning: w.meaning || '', example: plain(w.example) })),
    key_ko: (out.key_ko || []).slice(0, keys.length),
  };
}

async function taskLookup(ctx, p) {
  const q = String(p.query || '').slice(0, 60);
  const system = `너는 초등학생용 영어 단어 도우미다. JSON으로만 답한다.
${classBlock(ctx)}
학생이 찾는 말(한국어 또는 영어)에 맞는 쉬운 영어 표현을 1~3개 준다. 각각 한국어 뜻과 주제에 어울리는 짧은 예시 문장을 준다.
한국 고유의 놀이·음식·물건(예: 인형뽑기 → claw machine, 떡볶이 → tteokbokki)은 실제로 영어권에서 쓰는 표현을 주고, 마땅한 말이 없으면 로마자 표기와 짧은 설명을 준다.
부적절한 말이면 빈 배열을 준다.
형식: {"items":[{"word":"","meaning":"","example":""}]}`;
  const out = parseJson(await gemini(ctx.keys, { system, contents: [{ role: 'user', parts: [{ text: q }] }], asJson: true }));
  return { items: (out.items || []).slice(0, 3).map(w => ({ word: plain(w.word), meaning: w.meaning || '', example: plain(w.example) })) };
}

async function taskDefine(ctx, p) {
  const word = String(p.word || '').replace(/[^A-Za-z'-]/g, '').slice(0, 30);
  if (!word) return { meaning: '' };
  const sentence = String(p.context || '').slice(0, 300);
  const system = `너는 초등학생에게 영어 낱말 뜻을 알려 주는 사전이다. JSON으로만 답한다.
문장 속에서 쓰인 뜻으로, 아주 짧은 한국어 뜻(2~8글자 정도)을 준다. 사람 이름이면 "사람 이름"이라고 한다.
형식: {"meaning":""}`;
  const out = parseJson(await gemini(ctx.keys, {
    system, asJson: true,
    contents: [{ role: 'user', parts: [{ text: `낱말: ${word}\n문장: ${sentence}` }] }],
  }));
  return { word, meaning: String(out.meaning || '') };
}

async function taskChat(ctx, p) {
  const history = (p.history || []).slice(-14);
  const turn = history.filter(m => m.role === 'user').length;
  const maxTurns = 6;
  const system = `너는 초등학생과 영어로 대화하며 글쓰기를 준비시키는 친절한 AI 선생님이다.
${classBlock(ctx)}

[대화 가이드 — 가장 먼저 따를 것]
${ctx.guide || '쓰기 주제에 대해 학생이 좋아하는 것, 이유, 자세한 내용, 느낌을 차례로 물어본다.'}

규칙:
1. 대화 가이드에 나온 주제를 빠짐없이 하나씩 차례로 묻는다. 한 주제마다 "고르기 → 이유 → 자세히 → 느낌" 순서로 학생의 답을 따라간다. 한 주제를 너무 오래 끌지 말고, 남은 대화 수 안에 가이드의 주제를 모두 다룰 수 있게 조절한다.
2. 가이드와 쓰기 주제 밖의 이야기(예: 음식 맛의 세부, 관계없는 잡담)는 묻지 않는다. 학생이 벗어나면 짧게 반응하고 다시 주제로 돌아온다.
3. 학생의 선택과 취향은 무엇이든 그대로 인정한다. 절대 "그건 과목이 아니에요", "그건 음식이 아니에요"처럼 거절하거나 따지지 않는다.
   - 초등학교 과목은 넓게 본다: music, art, PE, math, science, English, Korean, social studies, 도덕(moral education), 실과(practical arts), 창체, 코딩 등 모두 과목이다.
   - 조금 엉뚱한 답(예: 좋아하는 과목이 점심시간)도 웃으며 받아 주고, 그 답으로 대화를 이어 간다.
4. 학생이 "음", "음…", "어", "흠", "글쎄", "몰라", "모르겠어요", "ㅋㅋ", "?" 처럼 머뭇거리거나 짧게 답하면, 그 말의 뜻을 묻지 말고 생각 중이라는 뜻으로 받아들인다. 이때는 고를 수 있는 예시 2~3개를 영어로 주고(예: "Do you like music, art, or PE?") 따라 말할 문장 틀(예: "My favorite subject is ___.")을 알려 준다.
5. 학생이 낱말 하나만 답해도 맞는 답으로 인정하고, 그 낱말을 넣은 완전한 문장으로 되받아 준다(예: "music" → "Great! My favorite subject is music.").
6. 한 번에 질문은 하나만. 영어 문장은 짧고 쉽게(1~2문장). 질문 아래 줄에 괄호로 짧은 한국어 도움말을 붙인다. 한국어는 초등학생이 읽는 글이므로 맞춤법을 정확히 지키고, 낱말을 줄이거나 빼먹지 않는다(예: '좋아하는 음식이 뭐예요?'를 '좋아하는 음이 뭐예요?'로 쓰면 안 됨).
7. 학생이 한국어로 답하거나 영어가 서툴면, 그 뜻을 영어로 어떻게 말하는지 예시("You can say: ...")를 알려 준 뒤 다음 질문을 한다. 한국 고유의 놀이·음식·물건 이름은 실제로 쓰는 영어 표현(예: 인형뽑기 → claw machine)으로 알려 주고, 학생이 말한 것을 다른 것으로 바꾸지 않는다. 한국어 낱말의 뜻이 분명하지 않으면 뜻을 캐묻지 말고 가장 그럴듯한 뜻으로 이어 간다.
8. 학생의 영어가 틀려도 혼내지 말고, 바른 문장으로 자연스럽게 되받아 준다.
9. 이모지는 1개 이하. 전체 답은 4줄 이내. 따옴표는 일반 따옴표(')만 쓴다.
10. 지금은 학생의 ${turn}번째 대답 차례까지 왔다(최대 ${maxTurns}번).${turn >= maxTurns ? ' 이번이 마지막이다. 질문하지 말고 칭찬과 함께 "이제 쓰기 단계로 가요!" 라고 마무리한다.' : ''}`;
  let contents;
  if (!history.length || p.start) {
    contents = [{ role: 'user', parts: [{ text: '(대화를 시작해 주세요. 반갑게 인사하고 가이드의 첫 질문을 하세요.)' }] }];
  } else {
    // "음", "몰라" 같은 머뭇거림은 AI가 뜻을 되묻지 않도록 표시해서 보냄
    const hesitant = /^\s*(음+|으음+|어+|어어+|흠+|글쎄+요?|몰라요?|모르겠어요?|잘\s*모르겠어요?|ㅋ+|ㅎ+|\?+|\.+|…+|um+|uh+|hmm+)[\s.~…?!]*$/i;
    contents = history.map(m => {
      const t = String(m.text || '').slice(0, 500);
      const text = m.role === 'user' && hesitant.test(t) ? `${t}\n(학생이 머뭇거리는 중이에요. 뜻을 묻지 말고 고를 수 있는 예시와 문장 틀을 주세요.)` : t;
      return { role: m.role === 'user' ? 'user' : 'model', parts: [{ text }] };
    });
    if (contents[0].role === 'model') contents.unshift({ role: 'user', parts: [{ text: '(대화 시작)' }] });
  }
  const reply = plain(await gemini(ctx.keys, { system, contents, models: CHAT_MODELS }));
  rpc('svc_log', { p_code: p.class_code, p_kind: 'chat' }).catch(() => {});
  return { reply };
}

async function taskHint(ctx, p) {
  const system = `너는 초등학생의 영어 글쓰기를 돕는 선생님이다. JSON으로만 답한다.
${classBlock(ctx)}

아래 대화에서 학생이 실제로 말한 사실만 이용해, 빈칸(____)이 있는 영어 예시 문장들을 만든다.
규칙:
- 학생이 말하지 않은 사실을 지어내지 않는다. 학생이 말한 것을 다른 것으로 바꾸지 않는다.
- 한 문장에 서로 다른 주제(예: 음식과 동물)를 섞지 않는다.
- 핵심 표현이 있으면 반드시 그 표현을 쓴 문장을 포함한다. 핵심 표현 안의 괄호 ( ) 부분은 빈칸(____)으로 바꾼다.
- 같은 표현이나 같은 답을 쓴 문장은 하나만 남긴다.
- 빈칸에는 학생이 대화에서 말한 낱말이 들어가게 하고, 그 낱말을 answer에 적는다(한국어로 말했으면 실제로 쓰는 영어 표현, 예: 인형뽑기 → claw machine).
- 관사, 복수형, 동사 형태 등 문법 오류가 없어야 한다. 문장은 짧고 자연스럽게.
- 문장 수 제한은 없지만, 순서대로 이어 읽으면 연결된 한 단락이 되게 한다(첫 문장은 주제를 소개, 마지막은 느낌이나 마무리).
- 각 문장마다 한국어 뜻(ko)을 짧게 붙인다. 따옴표는 일반 따옴표(')만 쓴다.
형식: {"sentences":[{"template":"I like ____ .","answer":["math"],"ko":"나는 수학을 좋아해요."}]}`;
  const out = parseJson(await gemini(ctx.keys, {
    system, asJson: true, models: MODELS, // 빠른 모델: 넷리파이 10초 제한 안에 답이 오도록
    contents: [{ role: 'user', parts: [{ text: `대화 내용:\n${chatTranscript(p.history) || '(대화 없음 — 주제와 핵심 표현만으로 만들기)'}` }] }],
  }));
  const sentences = (out.sentences || [])
    .filter(s => s && typeof s.template === 'string')
    .map(s => ({ template: plain(s.template).replace(/_{2,}/g, '____'), answer: Array.isArray(s.answer) ? s.answer.map(plain) : [], ko: s.ko || '' }))
    .slice(0, 12);
  return { sentences };
}

// 첨삭 표시가 학생 글을 바꾸지 않았는지 확인
const squash = s => plain(s).replace(/\s+/g, ' ').trim().toLowerCase();
// AI가 표시한 [[good:…]] / [[fix:틀린=>고친]] 을 뽑아내요 (=>, ->, →, ⇒ 모두 인식)
function parseMarks(annotated) {
  const marks = [];
  const re = /\[\[\s*(good|fix)\s*:\s*([\s\S]*?)\]\]/gi;
  let m;
  while ((m = re.exec(String(annotated || '')))) {
    const type = m[1].toLowerCase();
    if (type === 'good') { marks.push({ type, text: m[2].trim() }); continue; }
    const parts = m[2].split(/\s*(?:=>|->|→|⇒)\s*/);
    marks.push({ type, text: (parts[0] || '').trim(), right: (parts.slice(1).join(' ') || '').trim() });
  }
  return marks;
}
// 학생 원문은 그대로 두고, 원문에서 찾은 부분에만 표시를 다시 입혀요 (원문이 바뀌는 일 없음)
function buildAnnotated(text, marks, fixes) {
  const lower = text.toLowerCase();
  const spans = [];
  const overlaps = (s, e) => spans.some(x => s < x.end && e > x.start);
  const place = (needle, from) => {
    const n = needle.toLowerCase();
    if (!n) return -1;
    for (const start of [from, 0]) {
      let i = lower.indexOf(n, start);
      while (i !== -1) {
        if (!overlaps(i, i + n.length)) return i;
        i = lower.indexOf(n, i + 1);
      }
    }
    return -1;
  };
  let cursor = 0;
  for (const mk of marks) {
    const t = plain(mk.text);
    if (!t || (mk.type === 'fix' && (!mk.right || squash(t) === squash(mk.right)))) continue;
    const i = place(t, cursor);
    if (i === -1) continue;
    spans.push({ start: i, end: i + t.length, type: mk.type, right: plain(mk.right || '') });
    cursor = i + t.length;
  }
  for (const f of fixes) { // 목록에만 있고 표시가 빠진 고칠 점도 빨간색으로
    if (spans.some(x => x.type === 'fix' && squash(text.slice(x.start, x.end)) === squash(f.wrong))) continue;
    const i = place(f.wrong, 0);
    if (i !== -1) spans.push({ start: i, end: i + f.wrong.length, type: 'fix', right: f.right });
  }
  spans.sort((a, b) => a.start - b.start);
  let out = '', pos = 0;
  for (const x of spans) {
    const orig = text.slice(x.start, x.end);
    out += text.slice(pos, x.start) + (x.type === 'good' ? `[[good:${orig}]]` : `[[fix:${orig}=>${x.right}]]`);
    pos = x.end;
  }
  return out + text.slice(pos);
}

async function taskFeedback(ctx, p) {
  const text = plain(String(p.text || '').trim().slice(0, 2000));
  if (text.split(/\s+/).filter(Boolean).length < 3) throw new Error('글이 너무 짧아요. 조금 더 써 봐요.');
  const mode = p.mode === 'slow' ? 'slow' : 'self';
  const system = `너는 초등학생 영어 글을 첨삭하는 다정하고 꼼꼼한 선생님이다. JSON으로만 답한다.
${classBlock(ctx)}
평가 기준: ${ctx.criteria || '주제에 맞는 내용, 핵심 표현 사용, 문법과 철자, 문장 연결'}
이 글을 쓴 방법: ${mode === 'slow' ? 'AI가 만든 빈칸 문장을 채워서 쓴 글(천천히 쓰기)' : '학생이 스스로 직접 쓴 글(바로 쓰기)'}

[가장 중요한 규칙 — 학생의 내용을 지킬 것]
- 학생이 쓴 낱말의 뜻을 절대 다른 것으로 바꾸지 않는다. 특히 이름, 장소, 한국 고유의 놀이·음식·물건(예: 인형뽑기, 떡볶이), 로마자로 쓴 한국어는 그대로 둔다.
- 학생이 한국어 낱말을 섞어 썼으면, 확실한 영어 표현이 있을 때만(예: 인형뽑기 → claw machine) 알려 준다. 확실하지 않으면 고치지 않는다.
- 철자가 조금 틀린 낱말은 학생이 뜻한 낱말로 고친다. 무엇을 뜻했는지 분명하지 않으면 고치지 않는다.
- 이미 맞는 표현은 더 멋진 말로 바꾸지 않는다. 문법·철자·꼭 필요한 연결만 고친다.
- 따옴표는 일반 따옴표(')만 쓴다.

해야 할 일:
1. annotated: 학생 글 원문을 한 글자도 바꾸지 말고 그대로 옮기되, 잘한 부분은 [[good:잘한 부분]], 고칠 부분은 [[fix:틀린 부분=>고친 부분]] 으로 감싼다. 표시 밖의 글자는 원문과 똑같아야 한다.
2. praise: 학생 글의 실제 문장이나 낱말을 짚어서 구체적으로 칭찬하는 문장 2~4개(한국어). 예: "'I like PE because it is exciting.'에서 이유를 분명하게 말했어요!" 두루뭉술한 칭찬("잘했어요")은 쓰지 않는다.
3. fixes: 고칠 점 [{"wrong":"","right":"","why":"한국어 짧은 이유"}] 최대 5개, 중요한 것부터. wrong은 학생 글에 실제로 있는 글자 그대로.
4. rewritten: 학생의 내용과 낱말을 살려 문법만 바로잡고, 문장들이 자연스럽게 이어지는 한 단락. 학생 수준을 넘는 어려운 말은 쓰지 않는다. 핵심 표현이 빠졌다면 넣는다.
5. cheer: 학생에게 주는 한국어 응원 한 문장.
6. grade: 교사만 보는 평가 "상", "중", "하". 평가 기준과 핵심 표현 사용을 반영한다. 스스로 직접 쓴 글은 노력을 인정해 조금 더 후하게 보고, 빈칸을 채워 쓴 글은 같은 수준이라도 한 단계 낮게 본다.
7. report: 교사가 통지표에 쓸 한국어 한 문장(학생 이름 없이, "~함." 체).
학생에게 보이는 문장(praise, fixes의 why, cheer)에서는 '교사가 제시한', '선생님이 정한' 같은 말 없이 그냥 '핵심 표현'이라고 쓴다. 상·중·하 같은 등급은 학생에게 보이는 문장에 절대 쓰지 않는다.
형식: {"annotated":"","praise":[],"fixes":[],"rewritten":"","cheer":"","grade":"","report":""}`;
  const out = parseJson(await gemini(ctx.keys, {
    system, asJson: true, models: CAREFUL_MODELS,
    contents: [{ role: 'user', parts: [{ text: `학생 글:\n${text}` }] }],
  }));

  // 검증: 표시를 걷어냈을 때 원문과 다르면 표시를 쓰지 않음
  const inText = squash(text);
  const fixes = (out.fixes || [])
    .map(f => ({ wrong: plain(f.wrong).trim(), right: plain(f.right).trim(), why: String(f.why || '') }))
    .filter(f => f.wrong && f.right && squash(f.wrong) !== squash(f.right) && inText.includes(squash(f.wrong)))
    .slice(0, 5);
  const annotated = buildAnnotated(text, parseMarks(plain(out.annotated || '')), fixes);
  let grade = ['상', '중', '하'].includes(out.grade) ? out.grade : '중';
  if (mode === 'slow' && grade === '상') grade = '중'; // 빈칸 채우기 글은 최고 '중'
  const report = String(out.report || '') + (mode === 'slow' ? ' (빈칸 채우기로 작성)' : '');
  const feedback = {
    annotated,
    praise: (out.praise || []).slice(0, 4).map(String),
    fixes,
    rewritten: plain(out.rewritten || text),
    cheer: String(out.cheer || ''),
  };
  await rpc('svc_save_feedback', { p_code: p.class_code, p_no: p.student_no, p_pin: p.pin, d: { mode, text, feedback, grade, report } });
  return { feedback }; // 학생에게는 등급을 보내지 않음
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
  const text = await gemini([key], { system: 'Answer with one word.', contents: [{ role: 'user', parts: [{ text: 'Say OK.' }] }] });
  // (키가 AQ. 새 형식이든 AIza 옛 형식이든 같은 방법으로 확인해요)
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
    ctx.keys = { free: ctx.keys || [], paid: ctx.paid_keys || [] };
    switch (p.action) {
      case 'words': return json(200, await taskWords(ctx));
      case 'lookup': return json(200, await taskLookup(ctx, p));
      case 'define': return json(200, await taskDefine(ctx, p));
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
