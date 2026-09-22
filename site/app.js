// Jevcast site: the launcher preview, its query tabs, the window-layout
// diagram, and copy buttons. No network requests and no storage.
(() => {
  const root = document.documentElement;
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  // Launcher preview. The keycaps and the real shortcut press the keys and
  // replay the panel opening. The preview always stays visible.
  const keysButton = document.querySelector(".keys");
  const frame = document.getElementById("launcher");
  const img = frame.querySelector("img");
  const keys = {};
  for (const key of document.querySelectorAll(".key"))
    keys[key.dataset.key] = key;

  const endIntro = () => root.classList.remove("intro");
  frame.addEventListener("animationend", endIntro, { once: true });
  if (reduceMotion.matches) endIntro();

  const replay = () => {
    endIntro();
    if (reduceMotion.matches) return;
    frame.animate(
      [{ transform: "scale(0.97)" }, { transform: "none" }],
      { duration: 220, easing: "cubic-bezier(0.16, 1, 0.3, 1)" },
    );
  };

  keysButton.addEventListener("click", replay);

  const isTyping = (target) =>
    target instanceof Element &&
    target.closest("input, textarea, select, [contenteditable='true']");
  const setDown = (name, down) => keys[name]?.classList.toggle("is-down", down);

  document.addEventListener("keydown", (event) => {
    if (isTyping(event.target)) return;
    if (event.key === "Alt") setDown("option", true);
    // Option–Space. The code, not the key, because Option changes the typed character.
    if (
      event.code === "Space" &&
      event.altKey &&
      !event.ctrlKey &&
      !event.shiftKey &&
      !event.metaKey
    ) {
      event.preventDefault();
      setDown("space", true);
      if (!event.repeat) replay();
    }
  });
  document.addEventListener("keyup", (event) => {
    if (event.key === "Alt") setDown("option", false);
    if (event.code === "Space") setDown("space", false);
  });
  window.addEventListener("blur", () =>
    Object.keys(keys).forEach((name) => setDown(name, false)),
  );

  // Query tabs. Each tab shows one saved state of the real launcher.
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  document.querySelector(".demo-nav").hidden = false;

  const select = (tab) => {
    if (tab.getAttribute("aria-selected") === "true") return;
    for (const other of tabs) {
      const selected = other === tab;
      other.setAttribute("aria-selected", String(selected));
      other.tabIndex = selected ? 0 : -1;
    }
    frame.setAttribute("aria-labelledby", tab.id);
    const from = frame.getBoundingClientRect().height;
    const next = new Image();
    next.src = tab.dataset.src;
    const swap = () => {
      img.src = tab.dataset.src;
      img.alt = tab.dataset.alt;
      img.height = Number(tab.dataset.h);
      if (reduceMotion.matches) return;
      // Top edge fixed, height eased, as the app resizes its panel.
      const to = frame.getBoundingClientRect().height;
      frame.animate([{ height: `${from}px` }, { height: `${to}px` }], {
        duration: 120,
        easing: "ease-out",
      });
    };
    next.decode().then(swap, swap);
  };

  const orientation = () =>
    window.matchMedia("(max-width: 960px)").matches ? "horizontal" : "vertical";
  for (const tab of tabs) {
    tab.addEventListener("click", () => select(tab));
    tab.addEventListener("keydown", (event) => {
      const index = tabs.indexOf(tab);
      const horizontal = orientation() === "horizontal";
      const moves = {
        [horizontal ? "ArrowRight" : "ArrowDown"]: index + 1,
        [horizontal ? "ArrowLeft" : "ArrowUp"]: index - 1,
        Home: 0,
        End: tabs.length - 1,
      };
      if (!(event.key in moves)) return;
      event.preventDefault();
      const target = tabs[(moves[event.key] + tabs.length) % tabs.length];
      target.focus();
      select(target);
    });
  }
  const tablist = document.querySelector('[role="tablist"]');
  const syncOrientation = () =>
    tablist.setAttribute("aria-orientation", orientation());
  syncOrientation();
  window.addEventListener("resize", syncOrientation);

  // Load the other states once the page is idle, so switching is instant.
  window.addEventListener("load", () => {
    for (const tab of tabs) new Image().src = tab.dataset.src;
  });

  // Window layouts. Each key shows where it puts the window.
  const displays = document.querySelector(".displays");
  const layoutName = document.querySelector(".layout-name");
  const pads = [...document.querySelectorAll(".kc[data-layout]")];
  const show = (button) => {
    displays.dataset.layout = button.dataset.layout;
    displays.dataset.screen =
      button.dataset.layout === "other-display" ? "side" : "main";
    layoutName.textContent = button.dataset.name;
    for (const pad of pads)
      pad.setAttribute("aria-pressed", String(pad === button));
  };
  for (const pad of pads) {
    pad.addEventListener("click", () => show(pad));
    pad.addEventListener("mouseenter", () => show(pad));
  }

  // Copy buttons. The label and icon change for a moment after a copy.
  const status = document.getElementById("copy-status");
  for (const button of document.querySelectorAll(".copy")) {
    const label = button.querySelector(".copy-label");
    const idle = label.textContent;
    let timer;
    button.addEventListener("click", async () => {
      const source = document.getElementById(button.dataset.copy);
      // Hidden prose copies as one line; the visible command keeps its lines.
      const text = source.hidden
        ? source.textContent.replace(/\s+/g, " ").trim()
        : source.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
        label.textContent = "Copied";
        button.classList.add("is-copied");
        status.textContent = "Copied to the clipboard.";
      } catch {
        label.textContent = "Copy failed";
        status.textContent = "Could not copy. Select the text and press Command C.";
      }
      clearTimeout(timer);
      timer = setTimeout(() => {
        label.textContent = idle;
        button.classList.remove("is-copied");
      }, 1800);
    });
  }
})();
