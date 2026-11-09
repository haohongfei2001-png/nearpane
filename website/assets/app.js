(() => {
  "use strict";
  const $ = s => document.querySelector(s);
  const $$ = s => [...document.querySelectorAll(s)];
  const editor = $("#hero-editor");
  const voice = $("#voice-copy");
  let activeSpace = 0, listening = false, typeTimer = null, toastTimer = null;
  const workspaceText = [
    {file:"Workspace.swift", html:'<span class="c-comment">// Desktop / Workspace.swift</span>\n\n<span class="c-purple">import</span> AppKit\n\n<span class="c-purple">struct</span> WorkspaceSnapshot {\n    <span class="c-purple">let</span> id: WorkspaceID\n    <span class="c-purple">let</span> windows: [Window]\n    <span class="c-purple">let</span> display: Display\n}\n\n<span class="c-comment">// Keep the original geometry.</span>\n<span class="c-purple">func</span> preview(in bounds: CGRect) {\n    <span class="c-purple">for</span> window <span class="c-purple">in</span> windows {\n        <span class="c-purple">let</span> frame = window.frame\n        render(window, at: frame)\n    }\n}\n\n<span class="c-comment">// One place. The same windows.</span>',desc:"研究空间"},
    {file:"Notes.md",html:'<span class="c-comment"># 正在整理</span>\n\n今天想先核对两件事：\n\n一、把已有结果放到同一张图里。\n二、记录还没有回答的问题。\n\n<span class="c-comment">## 接下来</span>\n\n- 保留原始记录\n- 对照不同条件\n- 把截图放进草稿\n\n<span class="c-comment">// 想法可以随时接着写。</span>',desc:"写作空间"},
    {file:"Design.notes",html:'<span class="c-comment">// Interface / Design</span>\n\n目标：让界面安静而清晰。\n\n留出真正有用的空间。\n让动作发生在手边。\n不用反复打开新的工具。\n\n<span class="c-comment">// Iterate with intention.</span>\n\nGrid: 8 pt\nMaterial: frosted glass\nMotion: short &amp; precise',desc:"设计空间"},
    {file:"Workspace.swift",html:'<span class="c-comment">// Workspaces, not loose windows.</span>\n\n<span class="c-purple">func</span> select(_ workspace: ID) {\n    <span class="c-purple">let</span> windows = workspace.windows\n    restoreGroup(windows)\n}\n\n<span class="c-comment">// The complete working context.</span>\n\n<span class="c-purple">func</span> attach(_ snapshot: Image) {\n    captureQueue.append(snapshot)\n}\n\n<span class="c-comment">// No automatic sending.</span>',desc:"开发空间"}
  ];
  function notify(message) {
    const el = $("#toast");
    el.textContent = message;
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
  }
  function selectSpace(i) {
    activeSpace = (i + workspaceText.length) % workspaceText.length;
    $$(".space-row").forEach((b, n) => {
      const current = n === activeSpace;
      b.classList.toggle("is-selected", current);
      b.setAttribute("aria-pressed", String(current));
    });
    $("#hero-file-name").textContent = workspaceText[activeSpace].file;
    editor.innerHTML = workspaceText[activeSpace].html;
    $("#demo-feedback").textContent = "已进入" + workspaceText[activeSpace].desc;
    const surface = $(".mac-workspace");
    surface.animate([{opacity:0.70,transform:"translateY(3px)"},{opacity:1,transform:"translateY(0)"}],{duration:220,easing:"ease-out"});
  }
  $$(".space-row").forEach(b => b.addEventListener("click", () => selectSpace(Number(b.dataset.space))));
  $("#try-space").addEventListener("click", () => selectSpace(activeSpace+1));
  $("#toggle-voice").addEventListener("click", () => {
    listening = !listening;
    const button = $("#toggle-voice");
    button.classList.toggle("listening", listening);
    button.setAttribute("aria-label", listening ? "暂停语音演示" : "继续语音演示");
    clearInterval(typeTimer);
    if (!listening) {notify("已回到待命，文字保留");return;}
    const next = " 这段判断也保留下来，稍后继续。";
    let n=0;
    typeTimer=setInterval(()=>{
      if(!listening || n>=next.length){clearInterval(typeTimer);listening=false;button.classList.remove("listening");button.setAttribute("aria-label","继续语音演示");return;}
      voice.textContent+=next[n++];
    },65);
  });
  $("#copy-voice").addEventListener("click", async () => {
    try {await navigator.clipboard.writeText(voice.textContent);notify("文字已复制");}
    catch {notify("选择文字即可复制");}
  });
  const copyKinds = {chart:"图表截图",paper:"文档截图",code:"代码截图"};
  $$(".thumb[data-attachment]").forEach(b => b.addEventListener("click", () => {
    const k=b.dataset.attachment;
    const target=$(".discussion-answer");
    if (!target) return;
    const entry=document.createElement("span");
    entry.textContent="  ·  已附加"+copyKinds[k];
    entry.style.cssText="color:#857bd8;font-size:10px";
    target.append(entry);
    b.style.opacity=".3";b.style.pointerEvents="none";
    notify(copyKinds[k]+"已加入演示草稿");
  }));
  $("#tray-action").addEventListener("click",()=>document.querySelector("#capture").scrollIntoView({behavior:window.matchMedia("(prefers-reduced-motion: reduce)").matches?"instant":"smooth"}));
  const desks=[
    {left:"研究资料 · 文稿",right:"讨论 · 回复",title:"从观察到判断",subtitle:"2026 / Research Notes",question:"哪些变化最值得进一步核对？",answer:"先检查右侧的差异，再对照完整结果。把截图放进来，后面继续讨论。"},
    {left:"阅读 · 资料",right:"写作 · 初稿",title:"关于空间的几个想法",subtitle:"2026 / Reading Notes",question:"把今天读到的内容记下来",answer:"一个窗口负责资料，另一个窗口用来写作。下次回来，这组工作还在。"},
    {left:"设计 · 画板",right:"开发 · 代码",title:"界面结构与节奏",subtitle:"2026 / Interface Study",question:"让布局服务于内容",answer:"视觉稿和实现并排出现；需要更多窗口时，再调整彼此的位置与比例。"}
  ];
  $$(".desk-pick").forEach((b,i)=>b.addEventListener("click",()=>{
    $$(".desk-pick").forEach((el,n)=>el.classList.toggle("selected",n===i));
    const d=desks[i],win=$$(".desk-window");
    win[0].querySelector(".window-top").lastChild.textContent=d.left;
    win[1].querySelector(".window-top").lastChild.textContent=d.right;
    $(".paper-title").textContent=d.title;
    $(".paper-meta").textContent=d.subtitle;
    $(".discussion-question").textContent=d.question;
    $(".discussion-answer").textContent=d.answer;
    $("#desk-windows").animate([{opacity:.85},{opacity:1}],{duration:260,easing:"ease-out"});
  }));
})();
