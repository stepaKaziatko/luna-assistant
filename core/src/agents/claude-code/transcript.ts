import { oneLine, toolStep } from "../../executors/claude-code/tools.ts";
import type { AgentStep } from "../../rpc/protocol.gen.ts";
import { isValidModel } from "../../tasks/model.ts";

// Журнал сессии Claude Code: ~/.claude/projects/<проект>/<id сессии>.jsonl, запись на строку.
// Формат сверен с Claude Code 2.1.288; пример — core/test/fixtures/claude-sessions.

/** Сколько последних шагов сессии отдаётся оболочке. */
export const STEP_LIMIT = 40;
const TEXT_LIMIT = 240;

export interface TranscriptLimits {
  steps: number;
  /** Длина текста одного шага. */
  text: number;
  /** Сохранять ли переносы строк в тексте шагов. */
  multiline: boolean;
}

/** Лента карточки сессии: коротко, строка на шаг. */
export const BRIEF: TranscriptLimits = { steps: STEP_LIMIT, text: TEXT_LIMIT, multiline: false };
/** Лента окна сессии: текст агента читается целиком, с абзацами. */
export const DETAILED: TranscriptLimits = { steps: 200, text: 6000, multiline: true };

export interface TranscriptSummary {
  /** Заголовок, который агент сам дал сессии. */
  title?: string;
  /** Последний запрос человека. */
  lastPrompt?: string;
  /** Модель последнего ответа основной цепочки, как её записал агент. */
  model?: string;
  /** Старые первыми, не больше STEP_LIMIT. */
  steps: AgentStep[];
}

interface Block {
  type?: string;
  text?: string;
  name?: string;
  input?: Record<string, unknown>;
}

interface Line {
  type?: string;
  timestamp?: string;
  isSidechain?: boolean;
  isMeta?: boolean;
  isCompactSummary?: boolean;
  aiTitle?: string;
  lastPrompt?: string;
  message?: { content?: string | Block[]; model?: unknown };
}

/** Строки журнала могут быть не с начала файла: читается хвост, первая строка в нём бывает оборвана. */
export function summarizeTranscript(lines: Iterable<string>, limits: TranscriptLimits = BRIEF): TranscriptSummary {
  return appendTranscript({ steps: [] }, lines, limits);
}

/**
 * Дополняет сводку строками, дописанными в журнал: работающий агент пишет в него несколько раз
 * в секунду, и перечитывать ради этого весь хвост незачем.
 */
export function appendTranscript(
  summary: TranscriptSummary, lines: Iterable<string>, limits: TranscriptLimits = BRIEF,
): TranscriptSummary {
  for (const raw of lines) {
    if (raw.trim() === "") continue;
    let line: Line;
    try {
      line = JSON.parse(raw) as Line;
    } catch {
      continue;
    }
    if (line === null || typeof line !== "object") continue;

    if (line.type === "ai-title" && typeof line.aiTitle === "string" && line.aiTitle.trim() !== "") {
      summary.title = oneLine(line.aiTitle, TEXT_LIMIT);
    } else if (line.type === "last-prompt" && typeof line.lastPrompt === "string") {
      const prompt = cleanPrompt(line.lastPrompt);
      if (prompt) summary.lastPrompt = prompt;
    } else if (line.type === "user" || line.type === "assistant") {
      // Субагенты пишут в тот же журнал; ленту ведёт основная сессия.
      if (line.isSidechain || line.isMeta || line.isCompactSummary) continue;
      // Модель несёт любой ответ, даже из одного thinking; пустое и <synthetic> прежнюю не затирают.
      if (line.type === "assistant" && isValidModel(line.message?.model)) summary.model = line.message.model;
      const at = Date.parse(line.timestamp ?? "") || 0;
      for (const step of line.type === "user" ? promptSteps(line, at, limits) : assistantSteps(line, at, limits)) {
        summary.steps.push(step);
        if (step.kind === "prompt") summary.lastPrompt = oneLine(step.text, TEXT_LIMIT);
      }
    }
  }
  if (summary.steps.length > limits.steps) summary.steps = summary.steps.slice(-limits.steps);
  return summary;
}

function promptSteps(line: Line, at: number, limits: TranscriptLimits): AgentStep[] {
  const content = line.message?.content;
  const texts =
    typeof content === "string"
      ? [content]
      : (content ?? []).filter((block) => block.type === "text").map((block) => block.text ?? "");
  const prompt = cleanPrompt(texts.join("\n"), limits);
  return prompt ? [{ kind: "prompt", text: prompt, at }] : [];
}

function assistantSteps(line: Line, at: number, limits: TranscriptLimits): AgentStep[] {
  const content = line.message?.content;
  if (!Array.isArray(content)) return [];
  const steps: AgentStep[] = [];
  for (const block of content) {
    if (block.type === "tool_use" && block.name) {
      steps.push({ kind: "tool", ...toolStep(block.name, block.input ?? {}), at });
    } else if (block.type === "text" && block.text?.trim()) {
      steps.push({ kind: "text", text: clip(block.text, limits), at });
    }
  }
  return steps;
}

/**
 * Запрос человека без служебных вставок: редактор и CLI дописывают к нему блоки
 * вида <ide_selection>…</ide_selection>, а прерывание хода записывают как запрос.
 */
function cleanPrompt(text: string, limits: TranscriptLimits = BRIEF): string | undefined {
  const cleaned = clip(text.replace(/<([a-z][a-z0-9_-]*)(?:\s[^>]*)?>[\s\S]*?<\/\1>/g, " "), limits);
  if (cleaned === "" || cleaned.startsWith("[Request interrupted")) return undefined;
  return cleaned;
}

/** Текст шага: в одну строку или с абзацами, не длиннее лимита. */
function clip(text: string, limits: TranscriptLimits): string {
  const clean = limits.multiline ? text.replace(/\n{3,}/g, "\n\n").trim() : text.replace(/\s+/g, " ").trim();
  return clean.length > limits.text ? `${clean.slice(0, limits.text - 1)}…` : clean;
}
