// BibTeX copy-to-clipboard
document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll(".bibtex-copy").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const targetId = btn.dataset.copyTarget;
      const codeEl = document.getElementById(targetId);
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
});
