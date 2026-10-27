'use strict';

/*
 * Bucle de tool calling con herramientas de solo lectura del workspace.
 *
 * El modelo puede pedir workspace_list / workspace_read; el servidor las
 * ejecuta en local, con sandbox, y devuelve el resultado. El bucle está
 * limitado para evitar que un modelo entre en un ciclo infinito.
 */

const { apiRequest, CliError } = require('./core');
const { TOOL_DEFINITIONS, executeTool, summarizeResult } = require('./workspace');

const MAX_STEPS = 6;

async function runAgent({
  cfg,
  key,
  model,
  messages,
  workspace,
  onEvent = () => {},
  signal,
  maxSteps = MAX_STEPS,
  temperature,
  maxTokens,
  timeoutMs,
}) {
  if (!workspace) throw new CliError('El bucle de herramientas requiere un workspace.');

  const conversation = messages.map((message) => ({
    role: message.role,
    content: message.content,
  }));
  let toolId = 0;

  for (let step = 0; step < maxSteps; step += 1) {
    const body = {
      model,
      messages: conversation,
      stream: false,
      temperature: temperature === undefined ? cfg.temperature : temperature,
      max_tokens: maxTokens === undefined ? cfg.maxTokens : maxTokens,
      tools: TOOL_DEFINITIONS,
      tool_choice: 'auto',
    };

    const { response, timer } = await apiRequest(cfg, key, '/chat/completions', {
      method: 'POST',
      body,
      signal,
      timeoutMs,
    });

    let data;
    try {
      data = await response.json();
    } finally {
      clearTimeout(timer);
    }

    const choice = data && data.choices && data.choices[0];
    const message = choice && choice.message;
    if (!message) throw new CliError('Respuesta inesperada de la API (sin choices[0].message).');

    const calls = Array.isArray(message.tool_calls) ? message.tool_calls : [];
    if (calls.length === 0) {
      return {
        content: typeof message.content === 'string' ? message.content : '',
        messages: conversation,
        usage: data.usage || null,
        steps: step + 1,
      };
    }

    conversation.push({
      role: 'assistant',
      content: message.content || '',
      tool_calls: calls,
    });

    for (const call of calls) {
      toolId += 1;
      const name = call && call.function ? call.function.name : '';
      let args = {};
      if (call && call.function && call.function.arguments) {
        try {
          args = JSON.parse(call.function.arguments);
        } catch {
          args = {};
        }
      }

      onEvent({ type: 'tool', id: toolId, name, args });

      let result;
      try {
        result = executeTool(workspace, name, args);
        onEvent({
          type: 'tool_result',
          id: toolId,
          name,
          ok: true,
          summary: summarizeResult(name, result),
        });
      } catch (err) {
        result = { error: err.message };
        onEvent({
          type: 'tool_result',
          id: toolId,
          name,
          ok: false,
          summary: err.message,
        });
      }

      conversation.push({
        role: 'tool',
        tool_call_id: (call && call.id) || `call_${toolId}`,
        content: JSON.stringify(result),
      });
    }
  }

  throw new CliError(
    `El modelo superó ${maxSteps} pasos usando herramientas sin dar una respuesta final.`
  );
}

module.exports = { runAgent, MAX_STEPS };
