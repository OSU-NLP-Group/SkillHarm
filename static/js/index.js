// ============================================================
//  SkillHarm project page — interactivity
// ============================================================

document.addEventListener("DOMContentLoaded", () => {
  initBibtexCopy();
  initCite();
  initLeaderboard();
  initExamples();
});

// ============================================================
//  Cite popover (sticky nav)
// ============================================================
function initCite() {
  const toggle = document.getElementById("cite-toggle");
  const pop = document.getElementById("cite-pop");
  if (!toggle || !pop) return;

  const close = () => { pop.hidden = true; toggle.setAttribute("aria-expanded", "false"); };
  const open = () => { pop.hidden = false; toggle.setAttribute("aria-expanded", "true"); };

  toggle.addEventListener("click", (e) => {
    e.stopPropagation();
    pop.hidden ? open() : close();
  });
  pop.addEventListener("click", (e) => e.stopPropagation());
  document.addEventListener("click", () => { if (!pop.hidden) close(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !pop.hidden) close(); });
}

// ---- small helpers ----
function el(tag, cls, html) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html != null) e.innerHTML = html;
  return e;
}
function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// ============================================================
//  BibTeX copy-to-clipboard
// ============================================================
function initBibtexCopy() {
  document.querySelectorAll(".bibtex-copy").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const codeEl = document.getElementById(btn.dataset.copyTarget);
      if (!codeEl) return;
      try {
        await navigator.clipboard.writeText(codeEl.innerText.trim());
        const labelSpan = btn.querySelector("span:last-child");
        const iconEl = btn.querySelector(".icon i");
        const originalLabel = labelSpan.textContent;
        const originalIcon = iconEl.className;
        labelSpan.textContent = "Copied";
        iconEl.className = "fas fa-check";
        setTimeout(() => {
          labelSpan.textContent = originalLabel;
          iconEl.className = originalIcon;
        }, 1500);
      } catch (e) {
        console.warn("Clipboard copy failed:", e);
      }
    });
  });
}

// ============================================================
//  Key Results leaderboard
// ============================================================
const LB_DATA = [
  { h: "Claude Code", m: "Sonnet 4.6", o: "Anthropic", fpp_asr: 52.4, fpp_casr: 62.6, fpp_arr: 25.3, smp_asr: 51.6, smp_casr: 70.2, smp_arr: 2.1 },
  { h: "Claude Code", m: "Opus 4.7", o: "Anthropic", fpp_asr: 27.4, fpp_casr: 41.3, fpp_arr: 37.8, smp_asr: 9.4, smp_casr: 41.5, smp_arr: 14.1 },
  { h: "Codex", m: "GPT-5.4", o: "OpenAI", fpp_asr: 86.3, fpp_casr: 90.7, fpp_arr: 2.8, smp_asr: 69.3, smp_casr: 77.4, smp_arr: 1.0 },
  { h: "Codex", m: "GPT-5.5", o: "OpenAI", fpp_asr: 81.4, fpp_casr: 85.6, fpp_arr: 4.6, smp_asr: 65.6, smp_casr: 72.7, smp_arr: 3.1 },
  { h: "Gemini CLI", m: "Gemini 3 Flash", o: "Google", fpp_asr: 63.8, fpp_casr: 81.7, fpp_arr: 0.6, smp_asr: 45.8, smp_casr: 61.4, smp_arr: 0.5 },
  { h: "OpenCode", m: "Qwen-3.6 27B", o: "Alibaba", fpp_asr: 53.9, fpp_casr: 68.4, fpp_arr: 5.8, smp_asr: 51.6, smp_casr: 65.0, smp_arr: 0.0 },
];
const LB_COLS = [
  { k: "fpp_asr", g: "fpp", label: "ASR", first: true },
  { k: "fpp_casr", g: "fpp", label: "cASR" },
  { k: "fpp_arr", g: "fpp", label: "ARR" },
  { k: "smp_asr", g: "smp", label: "ASR", first: true },
  { k: "smp_casr", g: "smp", label: "cASR" },
  { k: "smp_arr", g: "smp", label: "ARR" },
];
let lbSortK = "fpp_asr";

function initLeaderboard() {
  const root = document.getElementById("leaderboard");
  if (!root) return;
  renderLeaderboard(root);
}

function renderLeaderboard(root) {
  const rows = LB_DATA.slice().sort((a, b) => b[lbSortK] - a[lbSortK]);

  const subHead = LB_COLS.map((c) => {
    const cls = ["metric", "grp-" + c.g, c.first ? "grp-divider" : "", c.k === lbSortK ? "active" : ""].join(" ");
    return `<th class="${cls}" data-k="${c.k}">${c.label} <span class="sort-arrow">⇅</span></th>`;
  }).join("");

  const body = rows.map((r) => {
    const cells = LB_COLS.map((c) => {
      const cls = ["metric", "grp-" + c.g, c.first ? "grp-divider" : "", c.k === lbSortK ? "active" : ""].join(" ");
      return `<td class="${cls}">${r[c.k].toFixed(1)}<span class="pct">%</span></td>`;
    }).join("");
    return `<tr><td class="lb-harness"><span class="harness-badge">${esc(r.h)}</span></td>` +
      `<td class="lb-model"><span class="model-name">${esc(r.m)}</span></td>` +
      cells + `</tr>`;
  }).join("");

  root.innerHTML = `
    <div class="leaderboard-scroll">
      <table class="leaderboard-table">
        <thead>
          <tr class="group-row">
            <th class="lb-harness" rowspan="2">Harness</th>
            <th class="lb-model" rowspan="2">Model</th>
            <th class="metric grp-fpp grp-divider" colspan="3">Fixed-Payload Poisoning</th>
            <th class="metric grp-smp grp-divider" colspan="3">Self-Mutating Poisoning</th>
          </tr>
          <tr class="sub-row">${subHead}</tr>
        </thead>
        <tbody>${body}</tbody>
      </table>
    </div>`;

  root.querySelectorAll("th.metric[data-k]").forEach((th) => {
    th.addEventListener("click", () => {
      lbSortK = th.dataset.k;
      renderLeaderboard(root);
    });
  });
}

// ============================================================
//  Interactive attack examples
// ============================================================
function initExamples() {
  const data = window.SKILLHARM_EXAMPLES;
  if (!data) return;

  ["fpp", "smp"].forEach((scenario) => {
    const select = document.querySelector(`.example-select[data-scenario="${scenario}"]`);
    const render = document.querySelector(`.example-render[data-scenario="${scenario}"]`);
    if (!select || !render) return;

    const entries = data[scenario] || [];
    entries.forEach((entry, i) => {
      const opt = el("option");
      opt.value = String(i);
      opt.textContent = entry.riskLabel;
      select.appendChild(opt);
    });

    const draw = () => {
      const entry = entries[parseInt(select.value, 10) || 0];
      render.innerHTML = scenario === "fpp" ? renderFpp(entry) : renderSmp(entry);
    };
    select.addEventListener("change", draw);
    draw();
  });
}

function renderDiff(diff) {
  const lines = diff.map((d) => {
    const note = d.note ? `<span class="diff-note"># ${esc(d.note)}</span>` : "";
    const cls = d.k === "add" ? (d.pay ? "diff-line add pay" : "diff-line add") : "diff-line ctx";
    return `<span class="${cls}">${esc(d.c)}${note}</span>`;
  }).join("");
  return `<pre class="diff-block">${lines}</pre>`;
}

function renderFpp(e) {
  const tags = `<span class="ex-tag risk">${esc(e.riskLabel)}</span>` +
    (e.realization ? `<span class="ex-tag real">${esc(e.realization)}</span>` : "");
  return `
    <div class="ex-tags">${tags}</div>
    <div class="ex-usertask"><span class="who">User task</span> ${esc(e.userTask)}</div>
    <div class="ex-filename">${esc(e.skill)}/${esc(e.file)}</div>
    ${renderDiff(e.diff)}
    <div class="ex-callout cover"><span class="ex-ico">🎭</span><div><strong>Cover story.</strong> ${esc(e.coverStory)}</div></div>
    <div class="ex-callout harm"><span class="ex-ico">⚠️</span><div><strong>Real effect.</strong> ${esc(e.realEffect)}</div></div>`;
}

function renderSmp(e) {
  const a = e.sessionA, b = e.sessionB;
  const mech = `<span class="ex-tag mech">${esc(e.mechanism)}</span>`;
  const tags = `<span class="ex-tag risk">${esc(e.riskLabel)}</span>${mech}`;

  const mutation = e.mutation ? `
    <div class="smp-step">
      <div class="smp-dot mut">↻</div>
      <div class="smp-content">
        <div class="smp-when">Between sessions · the skill mutates persistent content</div>
        <h4 class="smp-title">Writes <code>${esc(e.mutation.file)}</code> <span class="smp-status dorm">persists ⋯</span></h4>
        <div class="ex-filename">${esc(e.mutation.file)}</div>
        ${renderDiff(e.mutation.diff)}
      </div>
    </div>` : `
    <div class="smp-step">
      <div class="smp-dot mut">↻</div>
      <div class="smp-content">
        <div class="smp-when">Between sessions</div>
        <div class="smp-meta">The poisoned skill content persists into the next session via the shared-skill snapshot.</div>
      </div>
    </div>`;

  return `
    <div class="ex-tags">${tags}</div>
    <div class="smp-timeline">
      <div class="smp-step">
        <div class="smp-dot">A</div>
        <div class="smp-content">
          <div class="smp-when">Session 1 · looks harmless</div>
          <h4 class="smp-title">${esc(a.task)} <span class="smp-status ok">task succeeds ✓</span></h4>
          <div class="smp-meta">${esc(a.note || "")}</div>
          <div class="ex-filename">${esc(e.skill)}/${esc(a.file)}</div>
          ${renderDiff(a.diff)}
        </div>
      </div>
      ${mutation}
      <div class="smp-step">
        <div class="smp-dot harm">B</div>
        <div class="smp-content">
          <div class="smp-when">Session 2 · harm materializes</div>
          <h4 class="smp-title">${esc(b.task)} <span class="smp-status bad">${esc(b.outcome)} ✗</span></h4>
          <div class="ex-callout harm"><span class="ex-ico">⚠️</span><div><strong>Real effect.</strong> ${esc(e.realEffect)}</div></div>
        </div>
      </div>
    </div>
    <div class="ex-callout cover"><span class="ex-ico">🎭</span><div><strong>Cover story.</strong> ${esc(e.coverStory)}</div></div>`;
}
