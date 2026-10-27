'use strict';

/*
 * Cliente de la interfaz web. No conoce la clave de API: solo habla con
 * /api/* en el mismo origen (el servidor local la añade).
 */
(() => {
  const $ = (id) => document.getElementById(id);

  const messagesEl = $('messages');
  const emptyEl = $('empty');
  const form = $('form');
  const input = $('input');
  const sendBtn = $('send');
  const stopBtn = $('stop');
  const clearBtn = $('clear');
  const modelSel = $('model');
  const statusEl = $('status');
  const hintEl = $('hint');
  const verEl = $('ver');

  let history = [];
  let controller = null;
  let hasKey = true;

  function setStatus(text, kind = '') {
    statusEl.textContent = text || '';
    statusEl.className = `status ${kind}`.trim();
  }

  async function api(path, options) {
    const response = await fetch(path, options);
    if (!response.ok) {
      let message = `HTTP ${response.status}`;
      try {
        const data = await response.json();
        if (data && data.error) message = data.error;
      } catch {
        /* respuesta no JSON */
      }
      const error = new Error(message);
      error.status = response.status;
      throw error;
    }
    return response;
  }

  function nearBottom() {
    return messagesEl.scrollHeight - messagesEl.scrollTop - messagesEl.clientHeight < 140;
  }

  function scroll(force = false) {
    if (force || nearBottom()) {
      messagesEl.scrollTop = messagesEl.scrollHeight;
    }
  }

  function addBubble(role, text = '') {
    emptyEl.hidden = true;
    const row = document.createElement('div');
    row.className = `msg ${role}`;

    const who = document.createElement('div');
    who.className = 'who';
    who.textContent = role === 'user' ? 'Tú' : 'DeepSeek';

    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    bubble.textContent = text;

    row.append(who, bubble);
    messagesEl.append(row);
    scroll(true);
    return bubble;
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, (char) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[char]));
  }

  // Render Markdown mínimo y seguro: se escapa todo y solo se insertan
  // etiquetas conocidas. Los enlaces se limitan a http/https.
  function renderMarkdown(source) {
    const blocks = [];
    let html = escapeHtml(source);

    html = html.replace(/```[A-Za-z0-9_-]*\n([\s\S]*?)```/g, (_match, code) => {
      blocks.push(code.replace(/\n$/, ''));
      return `\u0000BLOCK${blocks.length - 1}\u0000`;
    });

    html = html.replace(/`([^`\n]+)`/g, '<code>$1</code>');
    html = html.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    html = html.replace(
      /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
      '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>'
    );

    html = html.replace(/\u0000BLOCK(\d+)\u0000/g, (_match, index) => {
      return `<pre><code>${blocks[Number(index)]}</code></pre>`;
    });

    return html;
  }

  function parseEvent(raw) {
    let name = 'message';
    const data = [];
    for (const line of raw.split(/\r?\n/)) {
      if (line.startsWith('event:')) name = line.slice(6).trim();
      else if (line.startsWith('data:')) data.push(line.slice(5).trim());
    }
    if (!data.length) return null;
    try {
      return { name, data: JSON.parse(data.join('\n')) };
    } catch {
      return null;
    }
  }

  function setStreaming(streaming) {
    sendBtn.disabled = streaming || !hasKey;
    stopBtn.hidden = !streaming;
    input.disabled = streaming;
    if (!streaming) input.focus();
  }

  async function send(text) {
    if (!hasKey) {
      setStatus('Falta la clave de API en el servidor.', 'err');
      return;
    }

    history.push({ role: 'user', content: text });
    addBubble('user', text);
    const bubble = addBubble('assistant', '');
    bubble.classList.add('typing');

    controller = new AbortController();
    setStreaming(true);
    setStatus('Generando…');

    let accumulated = '';
    try {
      const response = await api('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          messages: history,
          model: modelSel.value,
          stream: true,
        }),
        signal: controller.signal,
      });

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      let finished = false;

      while (!finished) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        let index;
        while ((index = buffer.indexOf('\n\n')) !== -1) {
          const raw = buffer.slice(0, index);
          buffer = buffer.slice(index + 2);
          const event = parseEvent(raw);
          if (!event) continue;

          if (event.name === 'delta') {
            accumulated += event.data.text || '';
            bubble.innerHTML = renderMarkdown(accumulated);
            scroll();
          } else if (event.name === 'error') {
            throw new Error(event.data.message || 'Error de la API.');
          } else if (event.name === 'done') {
            finished = true;
          }
        }
      }

      if (!accumulated) {
        bubble.textContent = '(respuesta vacía)';
      }
      history.push({ role: 'assistant', content: accumulated });
      setStatus('');
    } catch (error) {
      if (error.name === 'AbortError') {
        bubble.innerHTML = `${renderMarkdown(accumulated)}${accumulated ? '\n' : ''}<em>[detenido]</em>`;
        if (accumulated) history.push({ role: 'assistant', content: accumulated });
        setStatus('Detenido', '');
      } else {
        bubble.classList.add('error');
        bubble.innerHTML = accumulated ? renderMarkdown(accumulated) : `Error: ${escapeHtml(error.message)}`;
        setStatus(error.message, 'err');
      }
    } finally {
      bubble.classList.remove('typing');
      controller = null;
      setStreaming(false);
      scroll(true);
    }
  }

  function autosize() {
    input.style.height = 'auto';
    input.style.height = `${Math.min(input.scrollHeight, 190)}px`;
  }

  function loadModels(fallback) {
    const preset = ['deepseek-chat', 'deepseek-reasoner'];
    return api('/api/models')
      .then((response) => response.json())
      .then((data) => {
        let models = Array.isArray(data.models) && data.models.length ? data.models : preset;
        if (!models.includes(fallback)) models = [fallback, ...models];
        modelSel.replaceChildren(
          ...models.map((id) => {
            const option = document.createElement('option');
            option.value = id;
            option.textContent = id;
            return option;
          })
        );
        modelSel.value = fallback;
      })
      .catch(() => {
        modelSel.replaceChildren(
          ...preset.map((id) => {
            const option = document.createElement('option');
            option.value = id;
            option.textContent = id;
            return option;
          })
        );
        modelSel.value = fallback;
      });
  }

  async function init() {
    try {
      const health = await api('/api/health').then((response) => response.json());
      verEl.textContent = `v${health.version}`;
      hasKey = Boolean(health.hasKey);

      if (!hasKey) {
        hintEl.textContent =
          'No hay clave de API en el servidor. Exporta DEEPSEEK_API_KEY y reinicia `deepseek-harness web`.';
        setStatus('Sin clave', 'err');
        sendBtn.disabled = true;
      } else {
        hintEl.textContent = `Servidor local · ${health.model} · ${health.baseUrl}`;
        await loadModels(health.model);
        setStatus('Listo', 'ok');
        setTimeout(() => setStatus(''), 1500);
      }
    } catch (error) {
      hintEl.textContent = 'No se pudo contactar con el servidor local.';
      setStatus(error.message, 'err');
    }
  }

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text || controller) return;
    input.value = '';
    autosize();
    send(text);
  });

  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      form.requestSubmit();
    }
  });

  input.addEventListener('input', autosize);

  stopBtn.addEventListener('click', () => {
    if (controller) controller.abort();
  });

  clearBtn.addEventListener('click', () => {
    if (controller) controller.abort();
    history = [];
    messagesEl.querySelectorAll('.msg').forEach((node) => node.remove());
    emptyEl.hidden = false;
    setStatus('');
    input.focus();
  });

  init();
})();
