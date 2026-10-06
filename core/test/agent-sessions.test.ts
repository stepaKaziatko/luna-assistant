import assert from "node:assert/strict";
import { appendFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { ClaudeCodeSessions } from "../src/agents/claude-code/sessions.ts";
import { appendTranscript, DETAILED, STEP_LIMIT, summarizeTranscript } from "../src/agents/claude-code/transcript.ts";
import { hostOf, parseProcessTable } from "../src/agents/host.ts";
import { AgentMonitor } from "../src/agents/monitor.ts";
import type { AgentSource } from "../src/agents/source.ts";
import type { AgentSession } from "../src/rpc/protocol.gen.ts";

const HOME = fileURLToPath(new URL("./fixtures/claude-sessions", import.meta.url));
const SHOP = "11111111-1111-4111-8111-111111111111";

// Как `ps -axo pid=,ppid=,tty=,comm=`: агент расширения — потомок редактора, агент CLI — потомок терминала.
const PS = `
    1     0 ??       /sbin/launchd
   50     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Code
   51    50 ??       /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)
  101    51 ??       /Users/me/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude
   60     1 ??       /Applications/iTerm.app/Contents/MacOS/iTerm2
   61    60 ttys003  -zsh
  102    61 ttys003  claude
  106     1 ttys009  claude
`;

function source(): ClaudeCodeSessions {
  return new ClaudeCodeSessions({
    home: HOME,
    excludeCwd: ["/luna/tasks"],
    isAlive: (pid) => pid !== 103,
    processTable: async () => parseProcessTable(PS),
  });
}

async function sessionsById(): Promise<Map<string, AgentSession>> {
  return new Map((await source().sessions()).map((session) => [session.id, session]));
}

test("реестр: только живые сессии людей, без служебных процессов и задач Luna", async () => {
  const sessions = await sessionsById();
  assert.deepEqual(
    [...sessions.values()].map((session) => session.pid).sort(),
    [101, 102, 106],
  );
});

test("сессия в редакторе: заголовок агента, текущее действие, ссылка на вкладку сессии", async () => {
  const shop = (await sessionsById()).get(SHOP);
  assert.ok(shop);
  assert.equal(shop.project, "shop");
  assert.equal(shop.state, "working");
  assert.equal(shop.title, "Скидка в корзине");
  assert.equal(shop.activity, "правит cart.ts");
  // Папка окна редактора — из ~/.claude/ide: самая глубокая, внутри которой рабочая директория.
  assert.deepEqual(shop.host, {
    kind: "ide", name: "Visual Studio Code", appPath: "/Applications/Visual Studio Code.app", workspace: "/work/shop",
  });
  assert.equal(shop.openUrl, `vscode://anthropic.claude-code/open?session=${SHOP}`);
  // Журнал свежее реестра: время последнего изменения берётся из него.
  assert.ok(shop.updatedAt > 5000);
});

test("сессия в терминале ждёт человека: причина ожидания, терминал, без ссылки и без журнала", async () => {
  const api = (await sessionsById()).get("22222222-2222-4222-8222-222222222222");
  assert.ok(api);
  assert.equal(api.state, "waiting");
  assert.equal(api.waitingFor, "permission");
  assert.equal(api.title, undefined);
  assert.equal(api.activity, undefined);
  assert.deepEqual(api.host, { kind: "terminal", name: "iTerm", appPath: "/Applications/iTerm.app", tty: "/dev/ttys003" });
  assert.equal(api.openUrl, undefined);
  assert.equal(api.updatedAt, 6000);
});

test("журнал находится и в каталоге другого проекта; без заголовка агента — последний запрос", async () => {
  const web = (await sessionsById()).get("66666666-6666-4666-8666-666666666666");
  assert.ok(web);
  assert.equal(web.project, "web");
  assert.equal(web.state, "idle");
  assert.equal(web.title, "обнови зависимости");
  assert.deepEqual(web.host, { kind: "terminal", tty: "/dev/ttys009" });
});

test("шаги сессии: запросы без служебных вставок, инструменты и текст основной сессии", async () => {
  const sessions = source();
  await sessions.sessions();
  assert.deepEqual(
    (await sessions.steps(SHOP))?.map((step) => [step.kind, step.text]),
    [
      ["prompt", "почини расчёт скидки в корзине"],
      ["text", "Смотрю, как считается скидка."],
      ["tool", "читает cart.ts"],
      ["tool", "правит cart.ts"],
    ],
  );
  assert.equal(await sessions.steps("unknown"), undefined);
});

test("превью работы: последние шаги едут в самой сессии, у инструмента — род и цель", async () => {
  const shop = (await sessionsById()).get(SHOP);
  assert.deepEqual(
    shop?.trail?.map((step) => [step.kind, step.tool, step.target]),
    [
      ["prompt", undefined, undefined],
      ["text", undefined, undefined],
      ["tool", "read", "cart.ts"],
      ["tool", "edit", "cart.ts"],
    ],
  );
  // Сессия без журнала — без превью.
  assert.equal((await sessionsById()).get("22222222-2222-4222-8222-222222222222")?.trail, undefined);
});

test("подробная лента: текст агента длиннее и с абзацами, краткая — в одну строку", async () => {
  const text = `Первый абзац.\n\n\n\nВторой абзац. ${"я".repeat(400)}`;
  const lines = [
    JSON.stringify({ type: "assistant", timestamp: "2026-10-05T10:00:00.000Z", message: { content: [{ type: "text", text }] } }),
  ];
  assert.equal(summarizeTranscript(lines).steps[0]?.text.length, 240);
  assert.doesNotMatch(summarizeTranscript(lines).steps[0]?.text ?? "", /\n/);
  const detailed = summarizeTranscript(lines, DETAILED).steps[0]?.text ?? "";
  assert.match(detailed, /^Первый абзац\.\n\nВторой абзац\. я+$/);

  const sessions = source();
  await sessions.sessions();
  assert.deepEqual(
    (await sessions.steps(SHOP, true))?.map((step) => step.kind),
    ["prompt", "text", "tool", "tool"],
  );
});

test("журнал: шагов не больше лимита, длинный текст обрезается, заголовок — последний", () => {
  const lines = [
    JSON.stringify({ type: "ai-title", aiTitle: "Старый" }),
    ...Array.from({ length: STEP_LIMIT + 5 }, (_, index) =>
      JSON.stringify({
        type: "assistant",
        timestamp: "2026-10-05T10:00:00.000Z",
        message: { content: [{ type: "text", text: `шаг ${index} ${"я".repeat(400)}` }] },
      }),
    ),
    JSON.stringify({ type: "ai-title", aiTitle: "Новый" }),
  ];
  const summary = summarizeTranscript(lines);
  assert.equal(summary.title, "Новый");
  assert.equal(summary.steps.length, STEP_LIMIT);
  assert.match(summary.steps[0]?.text ?? "", /^шаг 5 /);
  assert.equal(summary.steps[0]?.text.length, 240);
  assert.equal(summary.steps[0]?.at, Date.parse("2026-10-05T10:00:00.000Z"));
});

test("журнал дочитывается: только дописанные полные строки, переписанный файл — заново", async (t) => {
  const home = mkdtempSync(join(tmpdir(), "luna-claude-"));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const id = "77777777-7777-4777-8777-777777777777";
  mkdirSync(join(home, "sessions"));
  mkdirSync(join(home, "projects", "-work-blog"), { recursive: true });
  writeFileSync(join(home, "sessions", "200.json"), JSON.stringify({ pid: 200, sessionId: id, cwd: "/work/blog", status: "busy", startedAt: 1 }));
  const journal = join(home, "projects", "-work-blog", `${id}.jsonl`);
  const tool = (file: string): string =>
    JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", name: "Read", input: { file_path: `/work/blog/${file}` } }] } });
  writeFileSync(journal, `${JSON.stringify({ type: "ai-title", aiTitle: "Блог" })}\n${tool("a.md")}\n`);

  const sessions = new ClaudeCodeSessions({ home, isAlive: () => true, processTable: async () => parseProcessTable("") });
  const texts = async (): Promise<string[] | undefined> => (await sessions.sessions())[0]?.trail?.map((step) => step.text);
  assert.deepEqual(await texts(), ["читает a.md"]);

  // Агент дописал строку и начал следующую: недописанная ждёт своего конца.
  const half = tool("c.md");
  appendFileSync(journal, `${tool("b.md")}\n${half.slice(0, 40)}`);
  const first = (await sessions.sessions())[0];
  assert.deepEqual(first?.trail?.map((step) => step.text), ["читает a.md", "читает b.md"]);
  assert.equal(first?.title, "Блог", "заголовок из уже прочитанной части не теряется");
  appendFileSync(journal, `${half.slice(40)}\n`);
  assert.deepEqual(await texts(), ["читает a.md", "читает b.md", "читает c.md"]);

  // Файл переписали короче — сводка собирается заново, а не дополняется.
  writeFileSync(journal, `${tool("z.md")}\n`);
  assert.deepEqual(await texts(), ["читает z.md"]);
});

test("хозяин процесса: внешний бандл цепочки родителей, редактор или терминал", () => {
  const table = parseProcessTable(PS);
  assert.deepEqual(hostOf(101, table), { kind: "ide", name: "Visual Studio Code", appPath: "/Applications/Visual Studio Code.app" });
  assert.equal(hostOf(102, table).kind, "terminal");
  assert.deepEqual(hostOf(999, table), { kind: "unknown" });
});

test("монитор: уведомляет только подписчика и только об изменениях", async () => {
  let current: AgentSession[] = [];
  const fake: AgentSource = { agent: "claude-code", sessions: async () => current, steps: async () => undefined };
  const emitted: AgentSession[][] = [];
  const monitor = new AgentMonitor({ sources: [fake], emit: (sessions) => emitted.push(sessions) });
  const session = (project: string, startedAt: number): AgentSession => ({
    id: `${project}-${startedAt}`, agent: "claude-code", pid: startedAt, cwd: `/work/${project}`, project,
    state: "idle", host: { kind: "unknown" }, startedAt, updatedAt: startedAt,
  });

  current = [session("web", 1)];
  await monitor.refresh();
  assert.equal(emitted.length, 0, "до первого agents.list уведомлений нет");

  assert.deepEqual((await monitor.list()).map((item) => item.id), ["web-1"]);
  await monitor.refresh();
  assert.equal(emitted.length, 0, "список не менялся");

  current = [session("web", 2), session("web", 1), session("api", 3)];
  await monitor.refresh();
  assert.deepEqual(emitted.at(-1)?.map((item) => item.id), ["api-3", "web-1", "web-2"]);
  assert.deepEqual(await monitor.steps("web-1"), []);
});

test("модель сессии: последний настоящий ответ основной цепочки, без побочных и <synthetic>", async () => {
  const sessions = await sessionsById();
  // В журнале: sonnet-4-6 → (побочная цепочка: haiku) → opus-5-5 → <synthetic>.
  assert.equal(sessions.get(SHOP)?.model, "claude-opus-5-5");
  // Журнал без message.model и сессия без журнала: поля нет совсем, а не undefined.
  const moved = sessions.get("66666666-6666-4666-8666-666666666666");
  assert.ok(moved);
  assert.equal("model" in moved, false);
  const terminal = [...sessions.values()].find((session) => session.pid === 102);
  assert.ok(terminal);
  assert.equal("model" in terminal, false);
});

test("журнал: модель задают только ответы основной цепочки с годным значением", () => {
  const reply = (model: unknown, extra: Record<string, unknown> = {}, withMessage = true): string =>
    JSON.stringify({ type: "assistant", ...extra, ...(withMessage ? { message: { model, content: [] } } : {}) });
  for (const [name, line] of [
    ["<synthetic>", reply("<synthetic>")],
    ["пустая строка", reply("")],
    ["пробел", reply("claude opus")],
    ["управляющий знак", reply("claude\u0007opus")],
    ["число", reply(5)],
    ["без message", reply(undefined, {}, false)],
    ["побочная цепочка", reply("claude-opus-5-5", { isSidechain: true })],
    ["isMeta", reply("claude-opus-5-5", { isMeta: true })],
    ["isCompactSummary", reply("claude-opus-5-5", { isCompactSummary: true })],
    ["модель у записи пользователя", JSON.stringify({ type: "user", message: { model: "claude-opus-5-5", content: "привет" } })],
  ] as const) {
    assert.equal("model" in summarizeTranscript([line]), false, name);
  }
  // Ответ из одного thinking шагов не даёт, а модель задаёт.
  const thinking = JSON.stringify({ type: "assistant", message: { model: "claude-opus-5-5", content: [{ type: "thinking", thinking: "…" }] } });
  const summary = summarizeTranscript([thinking]);
  assert.equal(summary.model, "claude-opus-5-5");
  assert.deepEqual(summary.steps, []);
  // Негодное значение прежнюю модель не затирает, годное — заменяет.
  assert.equal(appendTranscript(summary, [reply("<synthetic>"), reply("")]).model, "claude-opus-5-5");
  assert.equal(appendTranscript(summary, [reply("claude-sonnet-4-6")]).model, "claude-sonnet-4-6");
});

test("модель дочитывается вместе с журналом и переживает его переписывание", async (t) => {
  const home = mkdtempSync(join(tmpdir(), "luna-claude-"));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const id = "88888888-8888-4888-8888-888888888888";
  mkdirSync(join(home, "sessions"));
  mkdirSync(join(home, "projects", "-work-docs"), { recursive: true });
  writeFileSync(join(home, "sessions", "300.json"), JSON.stringify({ pid: 300, sessionId: id, cwd: "/work/docs", status: "busy", startedAt: 1 }));
  const journal = join(home, "projects", "-work-docs", `${id}.jsonl`);
  const reply = (model: string, file: string): string =>
    JSON.stringify({ type: "assistant", message: { model, content: [{ type: "tool_use", name: "Read", input: { file_path: `/work/docs/${file}` } }] } });
  writeFileSync(journal, `${reply("claude-sonnet-4-6", "a.md")}\n`);

  const sessions = new ClaudeCodeSessions({ home, isAlive: () => true, processTable: async () => parseProcessTable("") });
  const current = async (): Promise<AgentSession | undefined> => (await sessions.sessions())[0];
  assert.equal((await current())?.model, "claude-sonnet-4-6");

  // Тот же размер, другое содержимое старой строки: если бы журнал перечитывался, это было бы видно в ленте.
  writeFileSync(journal, `${reply("claude-sonnet-4-6", "x.md")}\n`);
  appendFileSync(journal, `${reply("claude-opus-5-5", "b.md")}\n`);
  const grown = await current();
  assert.equal(grown?.model, "claude-opus-5-5");
  assert.deepEqual(grown?.trail?.map((step) => step.text), ["читает a.md", "читает b.md"], "прежние строки не перечитывались");

  // Служебный ответ без модели: остаётся прежняя.
  appendFileSync(journal, `${JSON.stringify({ type: "assistant", message: { model: "<synthetic>", content: [] } })}\n`);
  assert.equal((await current())?.model, "claude-opus-5-5");

  // Недописанная строка модель не меняет, пока не закончится.
  const half = reply("claude-haiku-4-5-20251001", "c.md");
  appendFileSync(journal, half.slice(0, 50));
  assert.equal((await current())?.model, "claude-opus-5-5");
  appendFileSync(journal, `${half.slice(50)}\n`);
  assert.equal((await current())?.model, "claude-haiku-4-5-20251001");

  // Файл переписали короче и без ответов агента: модель остаётся из кэша, как заголовок.
  writeFileSync(journal, `${JSON.stringify({ type: "last-prompt", lastPrompt: "дальше" })}\n`);
  assert.equal((await current())?.model, "claude-haiku-4-5-20251001");
});

function snapshotFiles(root: string): Map<string, string> {
  const files = new Map<string, string>();
  for (const name of readdirSync(root, { recursive: true, encoding: "utf8" })) {
    const path = join(root, name);
    const info = statSync(path);
    files.set(name, info.isFile() ? `${info.mtimeMs}:${readFileSync(path, "utf8")}` : "dir");
  }
  return files;
}

test("наблюдение за сессиями не меняет файлы агента и не добавляет новых", async (t) => {
  const home = mkdtempSync(join(tmpdir(), "luna-claude-"));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const id = "99999999-9999-4999-8999-999999999999";
  mkdirSync(join(home, "sessions"));
  mkdirSync(join(home, "projects", "-work-site"), { recursive: true });
  writeFileSync(join(home, "sessions", "400.json"), JSON.stringify({ pid: 400, sessionId: id, cwd: "/work/site", status: "busy", startedAt: 1 }));
  writeFileSync(
    join(home, "projects", "-work-site", `${id}.jsonl`),
    `${JSON.stringify({ type: "assistant", message: { model: "claude-opus-5-5", content: [{ type: "text", text: "Привет" }] } })}\n`,
  );

  for (const root of [HOME, home]) {
    const before = snapshotFiles(root);
    const observer = root === HOME
      ? source()
      : new ClaudeCodeSessions({ home, isAlive: () => true, processTable: async () => parseProcessTable("") });
    const list = await observer.sessions();
    assert.ok(list.length > 0);
    await observer.steps(list[0]?.id ?? "", true);
    await observer.sessions();
    assert.deepEqual(snapshotFiles(root), before, root);
  }
});

test("монитор: смена одной только модели — это изменение", async () => {
  let model = "claude-sonnet-4-6";
  const fake: AgentSource = {
    agent: "claude-code",
    sessions: async () => [{
      id: "a", agent: "claude-code", pid: 1, cwd: "/work/web", project: "web", state: "idle", host: { kind: "unknown" },
      model, startedAt: 1, updatedAt: 1,
    }],
    steps: async () => undefined,
  };
  const emitted: AgentSession[][] = [];
  const monitor = new AgentMonitor({ sources: [fake], emit: (sessions) => emitted.push(sessions) });
  await monitor.list();
  await monitor.refresh();
  assert.equal(emitted.length, 0);
  model = "claude-opus-5-5";
  await monitor.refresh();
  assert.equal(emitted.length, 1);
  assert.equal(emitted[0]?.[0]?.model, "claude-opus-5-5");
});

test("фикстуры не содержат настоящих путей", () => {
  assert.doesNotMatch(readFileSync(`${HOME}/sessions/101.json`, "utf8"), /\/Users\//);
});
