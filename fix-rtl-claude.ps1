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
.composer-smart-rtl{direction:rtl !important;text-align:start !important;unicode-bidi:plaintext !important}
.composer-smart-ltr{direction:ltr !important;text-align:start !important;unicode-bidi:plaintext !important}
.composer-smart-rtl>p,.composer-smart-rtl>div{direction:rtl !important;text-align:start !important;unicode-bidi:plaintext !important}
.composer-smart-ltr>p,.composer-smart-ltr>div{direction:ltr !important;text-align:start !important;unicode-bidi:plaintext !important}
pre,code,kbd,samp,.diff,.cm-editor,.monaco-editor{direction:ltr !important;text-align:left !important;unicode-bidi:normal !important}
form:has(textarea),form:has([contenteditable]),form:has([role="textbox"]){direction:ltr !important}
'@

# --- Smart-direction JS (injected into the webview bundle) ----------------
$SMART_JS = @'
;(function(){
  var RTL_RE=/[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/;
  var LTR_RE=/[A-Za-z]/;
  // ---- Rendered conversation text: submitted user prompts, the pending bubble,
  //      assistant messages, and thinking/status/progress lines. ----
  // Real Claude Code selectors (verified in the webview bundle):
  //   submitted user prompt -> div.userMessage_xxxxxx  (no data-testid, capital M)
  //   assistant message      -> [data-testid="assistant-message"] > .rendered-markdown
  //   status/thinking        -> .progressContent_xxx / .loadingState_xxx / .metaMessage_xxx
  // detectSmartDirection()/isVisible() are defined below (function-hoisted; every
  // call happens from start(), which runs after all of this is assigned).
  var RENDERED_SEL=[
    ".rendered-markdown p",".rendered-markdown li",".rendered-markdown h1",".rendered-markdown h2",".rendered-markdown h3",".rendered-markdown h4",".rendered-markdown blockquote",
    "[data-testid*=\"message\"] p","[data-testid*=\"message\"] li","[data-testid*=\"message\"] blockquote",
    "[class*=\"userMessage_\"]",
    "[class*=\"progressContent\"]","[class*=\"loadingState\"]","[class*=\"metaMessage\"]","[class*=\"spinnerRow\"]","[class*=\"emptyStateText\"]",
    "[class*=\"thinking\"]","[class*=\"status\"]"
  ].join(",");
  var RENDER_SKIP='textarea, input, [contenteditable], [role="textbox"], .cm-editor, .monaco-editor, .diff, pre, code, [class*="mirror"], [class*="Mirror"]';
  function applyRenderedTextDirection(el){
    if(!el||!(el instanceof HTMLElement))return;
    if(el.closest(RENDER_SKIP))return;
    if(!isVisible(el))return;
    var text=(el.textContent||"").trim();
    if(!text||text.length>2000)return; // skip huge multi-message containers
    var dir=detectSmartDirection(text);
    el.setAttribute("dir",dir);
    el.style.setProperty("direction",dir,"important");
    el.style.setProperty("text-align","start","important");
    el.style.setProperty("unicode-bidi","plaintext","important");
    el.classList.toggle("smart-rtl",dir==="rtl");
    el.classList.toggle("smart-ltr",dir==="ltr");
  }
  function applyRenderedMessages(root){
    root=root||document;
    try{
      if(root.nodeType===1&&root.matches&&root.matches(RENDERED_SEL))applyRenderedTextDirection(root);
      var els=root.querySelectorAll(RENDERED_SEL);
      for(var i=0;i<els.length;i++)applyRenderedTextDirection(els[i]);
    }catch(e){}
  }
  // Text can be inserted into an existing node after submit, so re-run a few times.
  function scheduleRenderedPass(){
    try{if(window.requestAnimationFrame)window.requestAnimationFrame(function(){applyRenderedMessages(document);});}catch(e){}
    setTimeout(function(){applyRenderedMessages(document);},50);
    setTimeout(function(){applyRenderedMessages(document);},250);
  }
  // ---- Composer: style BOTH the editable (caret) and its mirror (text) ----
  // Real DOM (Claude Code webview): div.messageInputContainer >
  //   div.messageInput  (contenteditable="plaintext-only", role="textbox", color:transparent)  -> caret
  //   div.mentionMirror (aria-hidden, position:absolute, inset:0)                                -> visible text
  function isRtlChar(ch){return RTL_RE.test(ch);}
  function isLatinChar(ch){return LTR_RE.test(ch);}
  function isTechnicalToken(token){
    var t=(token||"").trim();
    if(!t)return true;
    return (/^https?:\/\//i.test(t)||/^[.\/\\~]/.test(t)||/[.\/\\]/.test(t)||/\.[A-Za-z0-9]{1,8}$/.test(t)||/^[?$@#]/.test(t)||/[?=&]/.test(t)||/[_-]/.test(t)||/\d/.test(t)||/^[A-Z0-9_.\/\\-]+$/.test(t)||/^[`"'()\[\]{}<>:;,\u060C.!\u061F\s]+$/.test(t));
  }
  function detectSmartDirection(text){
    var value=(text||"").trim();
    if(!value)return "ltr";
    var tokens=value.split(/\s+/);
    for(var i=0;i<tokens.length;i++){
      var token=tokens[i].replace(/^[`"'()\[\]{}<>:;,\u060C.!\u061F]+|[`"'()\[\]{}<>:;,\u060C.!\u061F]+$/g,"");
      if(!token)continue;
      var hasRtl=false,hasLatin=false;
      for(var k=0;k<token.length;k++){var ch=token[k];if(isRtlChar(ch))hasRtl=true;if(isLatinChar(ch))hasLatin=true;}
      if(hasRtl)return "rtl";
      if(isTechnicalToken(token))continue;
      if(hasLatin)return "ltr";
    }
    var rtlCount=0,latinCount=0;
    for(var j=0;j<value.length;j++){var c=value[j];if(isRtlChar(c))rtlCount++;else if(isLatinChar(c))latinCount++;}
    if(rtlCount>0&&rtlCount>=latinCount*0.25)return "rtl";
    return "ltr";
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
    applyRenderedMessages(document);
    updateComposerDirection("");
    document.addEventListener("beforeinput",composerHandler(true),true);
    document.addEventListener("input",composerHandler(false),true);
    document.addEventListener("keyup",composerHandler(false),true);
    document.addEventListener("compositionupdate",composerHandler(true),true);
    document.addEventListener("compositionend",composerHandler(false),true);
    document.addEventListener("focusin",composerHandler(false),true);
    // After submit/send, the prompt bubble is rendered in a new element.
    document.addEventListener("submit",scheduleRenderedPass,true);
    document.addEventListener("keydown",function(e){if(e.key==="Enter")scheduleRenderedPass();},true);
    document.addEventListener("click",scheduleRenderedPass,true);
    try{
      new MutationObserver(function(mutations){
        var sawChildList=false;
        for(var m=0;m<mutations.length;m++){
          var mu=mutations[m];
          if(mu.type==="childList"){
            sawChildList=true;
            for(var n=0;n<mu.addedNodes.length;n++){
              var node=mu.addedNodes[n];
              if(node.nodeType===1)applyRenderedMessages(node);
            }
          }else if(mu.type==="characterData"){
            // Text inserted into an existing node: re-scan its message container.
            var t=mu.target,p=(t.nodeType===1)?t:t.parentElement;
            if(p){var box=p.closest&&p.closest('[class*="userMessage_"], [class*="message"], [data-testid*="message"], .rendered-markdown');applyRenderedMessages(box||p);}
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
