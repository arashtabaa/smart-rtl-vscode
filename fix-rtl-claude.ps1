# Smart Auto-Direction Fix for Claude Code Extension
# Supports: VSCode, Cursor, Windsurf, Windsurf Next
# Works on: Windows
#
# Instead of forcing RTL on everything, this detects the first strong
# character of each message text block and sets dir="rtl" / dir="ltr"
# per block. Code, diffs, terminal output and the composer stay LTR.

param(
    [switch]$WithFont,
    [switch]$Revert,
    [switch]$Help
)

if ($Help) {
    Write-Host "Usage: .\fix-rtl-claude.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -WithFont    Include Vazirmatn font for Persian/Arabic text"
    Write-Host "  -Revert      Restore original files from backups"
    Write-Host "  -Help        Show this help message"
    exit 0
}

# --- Markers so re-running is idempotent ---------------------------------
$CSS_START = "/* === SMART-RTL START === */"
$CSS_END   = "/* === SMART-RTL END === */"
$JS_START  = "/* === SMART-RTL-JS START === */"
$JS_END    = "/* === SMART-RTL-JS END === */"

# --- Optional Vazirmatn font (text only, code keeps monospace) -----------
$FONT_CSS = @'
body,.rendered-markdown,.smart-rtl,.smart-ltr{font-family:"Vazirmatn","Segoe UI",system-ui,sans-serif !important}
pre,code,kbd,samp,.cm-editor,.monaco-editor{font-family:"SF Mono",Monaco,Consolas,"Courier New",monospace !important}
'@

# --- Smart-direction CSS (no forced direction on containers) -------------
# Message text blocks AND the composer's editable field are smart-directed.
# Code surfaces stay LTR; composer chrome stays LTR but its typed text follows
# the smart classes. The broad "form:has(...) *" descendant rule is gone so it
# no longer overrides RTL on the typed Persian text.
$SMART_CSS_CORE = @'
.smart-rtl{direction:rtl !important;text-align:right !important;unicode-bidi:plaintext !important}
.smart-ltr{direction:ltr !important;text-align:left !important;unicode-bidi:plaintext !important}
.smart-rtl:is(h1,h2,h3,h4,h5,h6,p,li,blockquote,div){width:100% !important;align-self:stretch !important;justify-self:stretch !important}
.composer-smart-rtl{direction:rtl !important;text-align:start !important;unicode-bidi:plaintext !important}
.composer-smart-ltr{direction:ltr !important;text-align:start !important;unicode-bidi:plaintext !important}
.composer-smart-rtl>p,.composer-smart-rtl>div{direction:rtl !important;text-align:start !important;unicode-bidi:plaintext !important}
.composer-smart-ltr>p,.composer-smart-ltr>div{direction:ltr !important;text-align:start !important;unicode-bidi:plaintext !important}
pre,pre *,code,kbd,samp,.diff,.cm-editor,.monaco-editor{direction:ltr !important;text-align:left !important;unicode-bidi:normal !important}
form:has(textarea),form:has([contenteditable]),form:has([role="textbox"]){direction:ltr !important}
'@

# --- Smart-direction JS (injected into the webview bundle) ----------------
$SMART_JS = @'
;(function(){
  var RTL_RE=/[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/;
  var LTR_RE=/[A-Za-z]/;
  // ---- Rendered conversation text: headings/titles, user prompts, assistant
  //      messages, list items, thinking/status lines. ----
  // RENDERED text uses explicit text-align:right/left (NOT start): headings often
  // sit in flex/shrink wrappers where `start` does not visually move them. We also
  // resolve the real block-level OWNER of each Persian run (not an inner span), and
  // a text-node fallback so nothing is missed. (Composer keeps text-align:start.)
  // detectSmartDirection()/isVisible()/isRtlChar() are defined below (hoisted).
  function containsRtl(text){return RTL_RE.test(String(text||""));}
  function shouldSkipDirectionFix(el){
    if(!el||!(el instanceof HTMLElement))return true;
    if(!isVisible(el))return true;
    return !!el.closest('pre, code, kbd, samp, textarea, input, [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], .cm-editor, .monaco-editor, .diff, [class*="mirror"], [class*="Mirror"]');
  }
  function isSafeDirectionTarget(el){
    if(!el||!(el instanceof HTMLElement))return false;
    if(shouldSkipDirectionFix(el))return false;
    var text=(el.textContent||"").trim();
    if(!text||text.length>2500)return false;
    if(el.querySelector('pre, textarea, input, [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], .cm-editor, .monaco-editor'))return false;
    return true;
  }
  function findNearestMessageRoot(el){
    return el.closest('[data-testid*="message"], [class*="message"], [class*="Message"], [data-testid*="assistant"], [class*="assistant"], [data-testid*="user"], [class*="user"], [class*="progressContent"], [class*="loadingState"]')||el.closest("main, article, section")||document.body;
  }
  var BLOCK_TAGS={p:1,li:1,blockquote:1,h1:1,h2:1,h3:1,h4:1,h5:1,h6:1,summary:1,figcaption:1};
  // Walk up from a Persian run to the nearest safe block-level owner so direction
  // lands on the element that owns the line layout (not an inner span).
  function findBlockOwner(el){
    if(!el||!(el instanceof HTMLElement))return null;
    var messageRoot=findNearestMessageRoot(el);
    var current=el;
    for(var depth=0;current&&depth<8;depth++){
      if(!(current instanceof HTMLElement))break;
      if(current===document.body)break;
      if(messageRoot&&current.parentElement&&!messageRoot.contains(current))break;
      if(!isSafeDirectionTarget(current)){current=current.parentElement;continue;}
      var tag=current.tagName.toLowerCase();
      if(BLOCK_TAGS[tag])return current;
      if(current.getAttribute("role")==="heading"||current.matches('[class*="title"], [class*="heading"], [class*="header"], [class*="label"], [data-testid*="title"], [data-testid*="heading"], [data-testid*="label"]'))return current;
      var style=window.getComputedStyle(current);
      var text=(current.textContent||"").trim();
      var hasNested=current.querySelector("p, li, blockquote, h1, h2, h3, h4, h5, h6, pre");
      var childCount=Array.prototype.slice.call(current.children||[]).filter(isVisible).length;
      // Custom title/line divs: a small, leaf-ish block/flex/grid element.
      if((style.display==="block"||style.display==="flex"||style.display==="grid"||style.display==="list-item")&&text.length<=500&&!hasNested&&childCount<=6)return current;
      current=current.parentElement;
    }
    return el;
  }
  function applyRenderedDirectionToTarget(target){
    if(!isSafeDirectionTarget(target))return;
    var text=(target.textContent||"").trim();
    if(!text)return;
    var dir=detectSmartDirection(text);
    var align=dir==="rtl"?"right":"left";
    target.setAttribute("dir",dir);
    target.style.setProperty("direction",dir,"important");
    target.style.setProperty("text-align",align,"important");
    target.style.setProperty("unicode-bidi","plaintext","important");
    // Headings/titles inside flex/shrink layouts only move once they stretch.
    if(dir==="rtl"){
      target.style.setProperty("width","100%","important");
      target.style.setProperty("align-self","stretch","important");
      target.style.setProperty("justify-self","stretch","important");
    }
    target.classList.toggle("smart-rtl",dir==="rtl");
    target.classList.toggle("smart-ltr",dir==="ltr");
  }
  var RENDERED_SEL=[
    ".markdown p",".markdown li",".markdown blockquote",".markdown h1",".markdown h2",".markdown h3",".markdown h4",".markdown h5",".markdown h6",
    ".rendered-markdown p",".rendered-markdown li",".rendered-markdown blockquote",".rendered-markdown h1",".rendered-markdown h2",".rendered-markdown h3",".rendered-markdown h4",".rendered-markdown h5",".rendered-markdown h6",
    "h1","h2","h3","h4","h5","h6","[role=\"heading\"]","summary",
    "[class*=\"title\"]","[class*=\"heading\"]","[class*=\"header\"]","[class*=\"label\"]","[data-testid*=\"title\"]","[data-testid*=\"heading\"]","[data-testid*=\"label\"]",
    "[data-testid*=\"message\"] p","[data-testid*=\"message\"] li","[data-testid*=\"message\"] div","[data-testid*=\"message\"] span",
    "[class*=\"message\"] p","[class*=\"message\"] li","[class*=\"message\"] div","[class*=\"message\"] span",
    "[class*=\"userMessage_\"]",
    "[class*=\"thinking\"]","[class*=\"status\"]","[data-testid*=\"thinking\"]","[data-testid*=\"status\"]"
  ].join(",");
  function applySmartDirectionToRenderedText(root){
    root=root||document;
    try{
      var nodes=(root.nodeType===1||root.nodeType===9)?root.querySelectorAll(RENDERED_SEL):[];
      for(var i=0;i<nodes.length;i++){var t=findBlockOwner(nodes[i]);if(t)applyRenderedDirectionToTarget(t);}
    }catch(e){}
    // Fallback: every visible Persian text node -> nearest safe block owner.
    try{
      if(!(root.nodeType===1||root.nodeType===9))return;
      var walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode:function(node){
        var v=node.nodeValue||"";
        if(!v.trim())return NodeFilter.FILTER_REJECT;
        if(!containsRtl(v))return NodeFilter.FILTER_REJECT;
        var parent=node.parentElement;
        if(!parent||shouldSkipDirectionFix(parent))return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }});
      var targets=[];
      while(walker.nextNode()){var owner=findBlockOwner(walker.currentNode.parentElement);if(owner&&targets.indexOf(owner)===-1)targets.push(owner);}
      for(var j=0;j<targets.length;j++)applyRenderedDirectionToTarget(targets[j]);
    }catch(e){}
  }
  // Coalesced multi-pass: re-run a few times so late insertions are caught, but a
  // burst of mutations schedules only one batch (avoids setTimeout pile-up).
  var _passPending=false;
  function scheduleSmartDirectionPass(){
    if(_passPending)return;
    _passPending=true;
    try{if(window.requestAnimationFrame)window.requestAnimationFrame(function(){applySmartDirectionToRenderedText(document);});}catch(e){}
    setTimeout(function(){applySmartDirectionToRenderedText(document);},50);
    setTimeout(function(){applySmartDirectionToRenderedText(document);},250);
    setTimeout(function(){applySmartDirectionToRenderedText(document);_passPending=false;},750);
  }
  // ---- Composer: style BOTH the editable (caret) and its mirror (text) ----
  // Real DOM (Claude Code webview): div.messageInputContainer >
  //   div.messageInput  (contenteditable="plaintext-only", role="textbox", color:transparent)  -> caret
  //   div.mentionMirror (aria-hidden, position:absolute, inset:0)                                -> visible text
  function isRtlChar(ch){return RTL_RE.test(ch);}
  function isLatinChar(ch){return LTR_RE.test(ch);}
  function normalizeToken(raw){
    return String(raw||"").replace(/^[`"'()\[\]{}<>:;,\u060C.!\u061F\u00AB\u00BB]+|[`"'()\[\]{}<>:;,\u060C.!\u061F\u00AB\u00BB]+$/g,"").trim();
  }
  function isTechnicalToken(token){
    var t=(token||"").trim();
    if(!t)return true;
    return (/^https?:\/\//i.test(t)||/^[.\/\\~]/.test(t)||/[.\/\\]/.test(t)||/\.[A-Za-z0-9]{1,12}$/.test(t)||/^[?$@#]/.test(t)||/[?=&]/.test(t)||/[_\/\\.-]/.test(t)||/\d/.test(t)||/^[A-Z0-9_.\/\\-]+$/.test(t)||/^(git|npm|pnpm|yarn|node|php|js|ts|css|html|json|md|feat|fix|chore|refactor|feature|bugfix|hotfix|branch|commit|tag|powershell|bash|cmd|remote|fork|push|pr|classic|fine-grained)$/i.test(t)||/^[`"'()\[\]{}<>:;,\u060C.!\u061F\u00AB\u00BB\s]+$/.test(t));
  }
  // Pure-Persian short-circuits to rtl, pure-Latin to ltr; mixed falls back to the
  // first strong NON-technical token, then to rtl when any Persian is present.
  function detectSmartDirection(text){
    var value=(text||"").trim();
    if(!value)return "ltr";
    var rtlCount=0,latinCount=0;
    for(var i=0;i<value.length;i++){var ch=value[i];if(isRtlChar(ch))rtlCount++;else if(isLatinChar(ch))latinCount++;}
    if(rtlCount===0)return "ltr";
    if(latinCount===0)return "rtl";
    var tokens=value.split(/\s+/);
    for(var j=0;j<tokens.length;j++){
      var token=normalizeToken(tokens[j]);
      if(!token)continue;
      var hasRtl=false,hasLatin=false;
      for(var k=0;k<token.length;k++){var c=token[k];if(isRtlChar(c))hasRtl=true;if(isLatinChar(c))hasLatin=true;}
      if(hasRtl)return "rtl";
      if(isTechnicalToken(token))continue;
      if(hasLatin)return "ltr";
    }
    return "rtl";
  }
  function isVisible(el){
    if(!el||!(el instanceof HTMLElement))return false;
    var style=window.getComputedStyle(el);
    var rect=el.getBoundingClientRect();
    return !el.hidden&&style.display!=="none"&&style.visibility!=="hidden"&&rect.width>0&&rect.height>0;
  }
  // The composer editable is contenteditable="plaintext-only" (not "true").
  var EDITABLE_SEL='textarea, input[type="text"], [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"]';
  function isComposerEditable(el){
    if(!el||!(el instanceof HTMLElement))return false;
    if(!el.matches(EDITABLE_SEL))return false;
    if(!isVisible(el))return false;
    if(el.closest("pre, code, .cm-editor, .monaco-editor"))return false;
    if(el.matches('button, [role="button"]'))return false;
    return true;
  }
  function getEditableText(el){
    if(el instanceof HTMLTextAreaElement||el instanceof HTMLInputElement)return el.value||"";
    return el.textContent||"";
  }
  function findComposerEditable(){
    var active=document.activeElement;
    if(isComposerEditable(active))return active;
    var list=Array.prototype.slice.call(document.querySelectorAll(EDITABLE_SEL)).filter(isComposerEditable);
    if(!list.length)return null;
    for(var i=0;i<list.length;i++){if(getEditableText(list[i]).trim().length>0)return list[i];}
    list.sort(function(a,b){return b.getBoundingClientRect().bottom-a.getBoundingClientRect().bottom;});
    return list[0];
  }
  // The VISIBLE typed text is rendered on a separate overlay layer (aria-hidden,
  // position:absolute, class contains "mirror") sitting over the transparent
  // contenteditable. The editable owns the caret; the mirror owns the text. Both
  // must share one direction or the caret and text disagree (the reported bug).
  function findComposerMirror(surface){
    var p=surface&&surface.parentElement;
    if(!p)return null;
    var kids=p.children;
    for(var i=0;i<kids.length;i++){
      var el=kids[i];
      if(el===surface||!(el instanceof HTMLElement))continue;
      var cls=(el.className&&el.className.toString)?el.className.toString():"";
      if(/mirror/i.test(cls))return el;
      if(el.getAttribute("aria-hidden")==="true"){
        var st=window.getComputedStyle(el);
        if(st.position==="absolute")return el;
      }
    }
    return null;
  }
  // Use text-align:start (follows direction) so caret/text/selection stay in sync.
  function styleComposerDirection(el,dir){
    if(!el)return;
    el.setAttribute("dir",dir);
    el.style.setProperty("direction",dir,"important");
    el.style.setProperty("text-align","start","important");
    el.style.setProperty("unicode-bidi","plaintext","important");
    el.classList.toggle("composer-smart-rtl",dir==="rtl");
    el.classList.toggle("composer-smart-ltr",dir==="ltr");
  }
  function updateComposerDirection(extraText){
    var surface=findComposerEditable();
    if(!surface)return;
    var dir=detectSmartDirection(getEditableText(surface)+(extraText||""));
    styleComposerDirection(surface,dir);
    styleComposerDirection(findComposerMirror(surface),dir);
  }
  // Temporary inspector: window.debugComposerCandidates() in DevTools console.
  function debugComposerCandidates(){
    var sel=['textarea','input[type="text"]','[contenteditable="true"]','[contenteditable="plaintext-only"]','[role="textbox"]','[data-lexical-editor="true"]','.ProseMirror','[class*="essageInput"]','[class*="irror"]','[class*="editor"]','[class*="textarea"]','[class*="input"]'].join(",");
    var rows=Array.prototype.slice.call(document.querySelectorAll(sel)).map(function(el,index){
      var style=window.getComputedStyle(el),rect=el.getBoundingClientRect();
      return {index:index,tag:el.tagName,className:(el.className&&el.className.toString)?el.className.toString():"",role:el.getAttribute("role")||"",contenteditable:el.getAttribute("contenteditable")||"",ariaHidden:el.getAttribute("aria-hidden")||"",dirAttr:el.getAttribute("dir")||"",cssDirection:style.direction,cssTextAlign:style.textAlign,color:style.color,display:style.display,visibility:style.visibility,width:Math.round(rect.width),height:Math.round(rect.height),top:Math.round(rect.top),bottom:Math.round(rect.bottom),active:el===document.activeElement,text:(el.value||el.textContent||"").slice(0,80)};
    });
    if(console.table)console.table(rows);else console.log(rows);
    return rows;
  }
  try{window.debugComposerCandidates=debugComposerCandidates;}catch(e){}
  function composerHandler(useData){
    return function(e){updateComposerDirection(useData?(e.data||""):"");};
  }
  function start(){
    applySmartDirectionToRenderedText(document);
    updateComposerDirection("");
    document.addEventListener("beforeinput",composerHandler(true),true);
    document.addEventListener("input",composerHandler(false),true);
    document.addEventListener("keyup",composerHandler(false),true);
    document.addEventListener("compositionupdate",composerHandler(true),true);
    document.addEventListener("compositionend",composerHandler(false),true);
    document.addEventListener("focusin",composerHandler(false),true);
    // After submit/send, the prompt bubble is rendered in a new element.
    document.addEventListener("submit",scheduleSmartDirectionPass,true);
    document.addEventListener("keydown",function(e){if(e.key==="Enter")scheduleSmartDirectionPass();},true);
    document.addEventListener("click",scheduleSmartDirectionPass,true);
    try{
      new MutationObserver(function(mutations){
        var sawChildList=false;
        for(var m=0;m<mutations.length;m++){
          var mu=mutations[m];
          if(mu.type==="childList"){
            sawChildList=true;
            for(var n=0;n<mu.addedNodes.length;n++){
              var node=mu.addedNodes[n];
              if(node.nodeType===1)applySmartDirectionToRenderedText(node);
            }
          }else if(mu.type==="characterData"){
            // Text inserted into an existing node: coalesced full re-pass.
            scheduleSmartDirectionPass();
          }
        }
        if(sawChildList)updateComposerDirection("");
      }).observe(document.body,{childList:true,subtree:true,characterData:true});
    }catch(e){}
  }
  if(document.body)start();
  else document.addEventListener("DOMContentLoaded",start);
})();
'@

$patched = 0

function Strip-Block {
    param([string]$Content, [string]$StartMarker, [string]$EndMarker)
    $pattern = [regex]::Escape($StartMarker) + '.*?' + [regex]::Escape($EndMarker)
    return [regex]::Replace($Content, $pattern, '', [System.Text.RegularExpressions.RegexOptions]::Singleline).TrimEnd("`r","`n")
}

function Patch-IDE {
    param([string]$IdeName, [string]$ExtensionsPath)

    if (-not (Test-Path $ExtensionsPath)) { return }

    $extDirs = Get-ChildItem -Path $ExtensionsPath -Directory -Filter "anthropic.claude-code-*" -ErrorAction SilentlyContinue

    foreach ($extDir in $extDirs) {
        $webviewPath = Join-Path $extDir.FullName "webview"
        $cssFile     = Join-Path $webviewPath "index.css"
        $cssBackup   = Join-Path $webviewPath "index.css.backup"
        $jsFile      = Join-Path $webviewPath "index.js"
        $jsBackup    = Join-Path $webviewPath "index.js.backup"

        if (-not (Test-Path $cssFile) -or -not (Test-Path $jsFile)) { continue }

        # Ensure clean backups exist
        if (-not (Test-Path $cssBackup)) { Copy-Item $cssFile $cssBackup }
        if (-not (Test-Path $jsBackup))  { Copy-Item $jsFile  $jsBackup }

        if ($Revert) {
            Copy-Item $cssBackup $cssFile -Force
            Copy-Item $jsBackup  $jsFile  -Force
            Write-Host "[OK] " -ForegroundColor Green -NoNewline
            Write-Host "Reverted ${IdeName}: $webviewPath"
            $script:patched++
            continue
        }

        # --- CSS: rebuild from clean backup, then append smart block ---
        $cssBase = Get-Content $cssBackup -Raw -Encoding UTF8
        $cssBase = Strip-Block $cssBase $CSS_START $CSS_END
        $cssBlock = $CSS_START + "`n"
        if ($WithFont) { $cssBlock += $FONT_CSS + "`n" }
        $cssBlock += $SMART_CSS_CORE + "`n" + $CSS_END
        Set-Content -Path $cssFile -Value ($cssBase + "`n" + $cssBlock) -NoNewline -Encoding UTF8

        # --- JS: rebuild from clean backup, then append smart block ---
        $jsBase = Get-Content $jsBackup -Raw -Encoding UTF8
        $jsBase = Strip-Block $jsBase $JS_START $JS_END
        $jsBlock = $JS_START + "`n" + $SMART_JS + "`n" + $JS_END
        Set-Content -Path $jsFile -Value ($jsBase + "`n" + $jsBlock) -NoNewline -Encoding UTF8

        Write-Host "[OK] " -ForegroundColor Green -NoNewline
        Write-Host "Patched ${IdeName}: $webviewPath"
        $script:patched++
    }
}

Write-Host ""
Write-Host "=== Smart Auto-Direction Fix for Claude Code Extension ==="
Write-Host ""
if ($WithFont) { Write-Host "Using Vazirmatn font for text" -ForegroundColor Yellow }
if ($Revert)   { Write-Host "Revert mode: restoring originals" -ForegroundColor Yellow }

$userProfile = $env:USERPROFILE
Patch-IDE -IdeName "VSCode"          -ExtensionsPath "$userProfile\.vscode\extensions"
Patch-IDE -IdeName "VSCode Insiders" -ExtensionsPath "$userProfile\.vscode-insiders\extensions"
Patch-IDE -IdeName "Cursor"          -ExtensionsPath "$userProfile\.cursor\extensions"
Patch-IDE -IdeName "Windsurf"        -ExtensionsPath "$userProfile\.windsurf\extensions"
Patch-IDE -IdeName "Windsurf Next"   -ExtensionsPath "$userProfile\.windsurf-next\extensions"

Write-Host ""
if ($patched -eq 0) {
    Write-Host "No Claude Code extensions found." -ForegroundColor Red
    Write-Host "Make sure Claude Code extension is installed in your IDE."
    exit 1
} else {
    Write-Host "Done on $patched IDE(s)." -ForegroundColor Green
    Write-Host ""
    Write-Host "Restart your IDE to apply changes."
}
