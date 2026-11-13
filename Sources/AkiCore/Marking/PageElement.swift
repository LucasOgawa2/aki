import Foundation

extension LinuxMarking {
    /// The element of a browser page under a point mark, as the Mac's `ProbedElement`
    /// gives `element_context` (that type is the app's, macOS only; this one is portable).
    public struct PageElement: Equatable, Sendable {
        /// `tag#id.cls “its words”`: the Mac's label, `element_context.path`.
        public var path: String
        public var tag: String
        public var text: String?
        public var id: String?
        public var classes: [String]
        /// A React dev build's `fileName:line`.
        public var source: String?
        public var html: String?
        public var selector: String?

        public init(path: String, tag: String, text: String? = nil, id: String? = nil, classes: [String] = [], source: String? = nil,
                    html: String? = nil, selector: String? = nil) {
            self.path = path
            self.tag = tag
            self.text = text
            self.id = id
            self.classes = classes
            self.source = source
            self.html = html
            self.selector = selector
        }
    }
}

extension LinuxMarking.CDP {
    public enum Hit: Equatable, Sendable {
        case element(LinuxMarking.PageElement)
        /// Empty space of a big block.
        case background
        /// Past the page (the JS's own check).
        case outside
        /// Nothing found, or an answer that isn't one.
        case none

        public var element: LinuxMarking.PageElement? {
            if case let .element(element) = self { return element }
            return nil
        }
    }

    /// The JS's answer (a JSON string), its types checked and its strings cut as the JS
    /// cuts them (text 80, HTML 300; the path, source and selector at 300 too).
    public static func hit(fromResult text: String) -> Hit {
        guard let json = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) else { return .none }
        if json["background"] == .bool(true) { return .background }
        if json["outside"] == .bool(true) { return .outside }
        // The first of the chain big enough to see (the Mac's `describe`: wider and taller than 2).
        guard let first = json["chain"]?.array?.lazy.compactMap({ $0.object }).first(where: { e in
            e["tag"]?.string != nil && (e["w"]?.double ?? 0) > 2 && (e["h"]?.double ?? 0) > 2
        }), let tag = first["tag"]?.string else { return .none }
        func cut(_ value: JSONValue?, _ limit: Int) -> String? {
            value?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(limit)) }
        }
        let id = cut(first["id"], 300)
        let classes = (first["cls"]?.array ?? []).compactMap(\.string).prefix(3).map { String($0.prefix(40)) }
        let words = cut(first["text"], 80)
        var label = tag + (id.map { "#\($0)" } ?? "") + classes.prefix(2).map { ".\($0)" }.joined()
        if let words, words.count > 1 { label += " “\(words.count > 28 ? String(words.prefix(28)) + "…" : words)”" }
        return .element(.init(path: String(label.prefix(300)), tag: String(tag.prefix(300)), text: words, id: id, classes: Array(classes),
                              source: cut(json["src"], 300), html: cut(json["html"], 300), selector: cut(json["sel"], 300)))
    }

    /// The Mac's extraction (`BrowserProbe.prelude` and `element(at:)`), in one function
    /// called with the point in the page's CSS pixels and the zoom. Differences: no
    /// `window.__aki*` (the arrow keys aren't on Linux), and the point for the `::after`
    /// caret is the function's own variable. It only reads the DOM.
    public static func elementScript(x: Double, y: Double, zoom: Double) -> String {
        "(function(px,py,Z){" + extraction + "})(\(literal(x)),\(literal(y)),\(literal(zoom)))"
    }

    static func literal(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// `BrowserProbe.prelude`'s helpers and `element(at:)`'s body, as a raw string (the
    /// page gets each backslash as written). `vx`/`vy` are 0: the point comes already
    /// in the page's pixels, and the frames in `chain` aren't used here.
    static let extraction = #"""
    try{
    var vx=0,vy=0,__akiPoint=null;
    function stack(x,y){var out=[],seen=[];
      (function walk(root){var list=root.elementsFromPoint?root.elementsFromPoint(x,y):[];
        for(var i=0;i<list.length;i++){var e=list[i];if(seen.indexOf(e)>=0)continue;seen.push(e);
          if(e.shadowRoot&&e.shadowRoot!==root)walk(e.shadowRoot);out.push(e)}})(document);
      return out}
    function area(e){var r=e.getBoundingClientRect();return r.width*r.height}
    var VW=innerWidth,VH=innerHeight;
    var MEDIA={IMG:1,SVG:1,VIDEO:1,CANVAS:1,IFRAME:1,PICTURE:1,INPUT:1,TEXTAREA:1,SELECT:1,BUTTON:1,A:1};
    function interactive(e){return !!MEDIA[e.tagName.toUpperCase()]||/^(button|link|checkbox|radio|tab|menuitem|switch|option|combobox|textbox)$/.test(e.getAttribute('role')||'')||e.isContentEditable}
    function overlay(e){var r=e.getBoundingClientRect();if(r.width<VW*0.9||r.height<VH*0.9)return false;
      var cs=getComputedStyle(e),pos=cs.position,bg=cs.backgroundColor;
      var clear=bg==='transparent'||/rgba\(.*,\s*0\)$/.test(bg)||parseFloat(cs.opacity)<0.1;
      return ((pos==='fixed'||pos==='absolute')&&clear)||parseInt(cs.zIndex||'0',10)>1000||(cs.pointerEvents==='none'&&pos==='fixed')}
    function seen(e){var o=1;for(var n=e;n&&n.nodeType===1&&n!==document.body;n=n.parentElement){o*=parseFloat(getComputedStyle(n).opacity);if(o<0.35)return false}return true}
    function valid(e){if(!e||e.nodeType!==1)return false;var t=e.tagName;if(t==='HTML'||t==='BODY')return false;
      if(e.checkVisibility&&!e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}))return false;
      if(!seen(e))return false;
      var r=e.getBoundingClientRect();if(r.width<1||r.height<1)return false;return !overlay(e)}
    function boxPaint(e){var cs=getComputedStyle(e);
      var bg=cs.backgroundColor,hasBg=!(bg==='transparent'||/rgba\(.*,\s*0\)$/.test(bg))||cs.backgroundImage!=='none';
      return hasBg||parseFloat(cs.borderTopWidth)+parseFloat(cs.borderLeftWidth)>0||cs.boxShadow!=='none'||cs.outlineStyle!=='none'}
    function paintedAt(e,x,y){if(interactive(e)||boxPaint(e))return true;
      for(var i=0;i<e.childNodes.length;i++){var n=e.childNodes[i];
        if(n.nodeType===3&&n.textContent.trim()){var rg=document.createRange();rg.selectNodeContents(n);
          var rs=rg.getClientRects();for(var j=0;j<rs.length;j++){var q=rs[j];if(x>=q.left-2&&x<=q.right+2&&y>=q.top-2&&y<=q.bottom+2)return true}}}
      return false}
    function lift(e){var tag=e.tagName;
      if(e instanceof SVGElement&&tag.toLowerCase()!=='svg'){var s=e.ownerSVGElement;while(s&&s.ownerSVGElement)s=s.ownerSVGElement;if(s)e=s}
      return e}
    function deep(x,y){
      __akiPoint=[x,y];
      var list=stack(x,y),c=null;
      for(var i=0;i<list.length;i++){var e=list[i];if(valid(e)&&paintedAt(e,x,y)){c=e;break}}
      if(document.caretRangeFromPoint){var cr=document.caretRangeFromPoint(x,y);
        if(cr&&cr.startContainer&&cr.startContainer.nodeType===3){var p=cr.startContainer.parentElement;
          if(p&&valid(p)&&(!c||(c.contains(p)&&p!==c))){var rg=document.createRange();rg.selectNodeContents(cr.startContainer);
            var rs=rg.getClientRects();for(var j=0;j<rs.length;j++){var q=rs[j];if(x>=q.left&&x<=q.right&&y>=q.top&&y<=q.bottom){c=p;break}}}}}
      function media(e){return /^(IMG|VIDEO|CANVAS|PICTURE|SVG|IFRAME)$/i.test(e.tagName)||getComputedStyle(e).backgroundImage.indexOf('url(')>=0}
      if(!c||(area(c)>VW*VH*0.15&&!media(c))){var best=null,bd=0;
        for(var rr=4;rr<=12;rr+=4)for(var a=0;a<12;a++){var t=a*Math.PI/6,px=x+Math.cos(t)*rr,py=y+Math.sin(t)*rr,l=stack(px,py);
          for(var k=0;k<l.length;k++){var n=l[k];if(valid(n)&&paintedAt(n,px,py)){if(!best||area(n)<area(best)||(area(n)===area(best)&&rr<bd)){best=n;bd=rr}break}}}
        if(best&&(!c||area(best)<area(c)*0.5))c=best}
      if(c&&c.querySelectorAll){var root=c;for(var up=0;up<4&&root.parentElement&&root.parentElement!==document.body;up++)root=root.parentElement;
        var all=root.querySelectorAll('*'),inner=null;
        function passThrough(e){for(var q=e;q&&q!==root;q=q.parentElement){if(getComputedStyle(q).pointerEvents==='none')return true}return false}
        for(var i=0;i<all.length&&i<3000;i++){var e=all[i],r=e.getBoundingClientRect();
          if(x<r.left||x>r.right||y<r.top||y>r.bottom||r.width<3||r.height<3)continue;
          if(!(c.contains(e)||passThrough(e)))continue;
          if(e.checkVisibility&&!e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}))continue;
          if(!seen(e))continue;
          if(!(paintedAt(e,x,y)||media(e)))continue;
          if(!inner||area(e)<area(inner))inner=e}
        if(inner&&area(inner)<area(c))c=inner}
      if(!c){for(var b=0;b<list.length;b++){if(valid(list[b])){c=list[b];break}}}
      if(!c)return {__akiBackground:true};
      return lift(c)}
    function parent(e){return e.parentElement||(e.getRootNode&&e.getRootNode().host)||null}
    function esc(v){return (window.CSS&&CSS.escape)?CSS.escape(v):v}
    function uniq(sel,root){try{return (root||document).querySelectorAll(sel).length===1}catch(_){return false}}
    var PREF=['data-testid','data-test-id','data-test','data-cy','data-qa','aria-label','href','src','name','title','alt','role'];
    function stableId(id){return !!id&&id.length<64&&!/^:r|«|^[0-9]+$|^[0-9a-f]{8}-|^(radix|headlessui|mui|react-aria|ember)[-0-9]/.test(id)&&!guid(id)}
    function guid(v){var t=0;for(var i=1;i<v.length;i++){var a=v[i-1],b=v[i];if(/[a-z]/.test(a)!==/[a-z]/.test(b)||/[0-9]/.test(a)!==/[0-9]/.test(b))t++}return t>=v.length/4}
    function wordLike(w){if(!/^[a-z][a-z-]{2,}$/i.test(w))return false;var parts=w.split('-');
      for(var i=0;i<parts.length;i++){if(parts[i].length<=2||/[^aeiou]{4,}/i.test(parts[i]))return false}return true}
    function okClass(c){return c.length<40&&wordLike(c)&&!/^(undefined|null|true|false|nan)$/i.test(c)}
    function selector(el){
      var root=el.getRootNode&&el.getRootNode()!==document?el.getRootNode():document;
      var tag=el.tagName.toLowerCase();
      if(stableId(el.id)&&uniq('#'+esc(el.id),root))return '#'+esc(el.id);
      for(var i=0;i<PREF.length;i++){var v=el.getAttribute(PREF[i]);if(v&&v.length<120&&!/^(blob|data):/.test(v)){
        var s1='['+PREF[i]+'="'+esc(v)+'"]';if(uniq(s1,root))return s1;var s2=tag+s1;if(uniq(s2,root))return s2}}
      var path=[],c=el,d=0;
      while(c&&c.nodeType===1&&c.tagName!=='BODY'&&d<6){
        var t=c.tagName.toLowerCase(),part=t;
        if(stableId(c.id)){part='#'+esc(c.id)}
        else{var cls=Array.prototype.filter.call(c.classList,okClass).slice(0,2);if(cls.length)part=t+'.'+cls.map(esc).join('.');
          var p=c.parentElement;if(p){var same=Array.prototype.filter.call(p.children,function(x){return x.tagName===c.tagName});
            if(same.length>1&&!uniq(path.length?part+' > '+path.join(' > '):part,root))part+=':nth-of-type('+(same.indexOf(c)+1)+')'}}
        path.unshift(part);var sel=path.join(' > ');if(uniq(sel,root))return sel;
        if(part.charAt(0)==='#')break;c=c.parentElement;d++}
      return path.join(' > ')}
    function info(e){var b=e.getBoundingClientRect(),l=Math.max(b.left,0),t=Math.max(b.top,0),
      rt=Math.min(b.right,innerWidth),bt=Math.min(b.bottom,innerHeight),
      r=(rt-l>1&&bt-t>1)?{left:l,top:t,width:rt-l,height:bt-t}:b;return {tag:e.tagName.toLowerCase(),id:e.id||null,
      cls:Array.prototype.filter.call(e.classList,okClass).slice(0,3),x:r.left*Z+vx,y:r.top*Z+vy,w:r.width*Z,h:r.height*Z,
      text:((e.innerText||(secret(e)?'':e.value)||e.alt||e.getAttribute('aria-label')||'')+'').trim().replace(/\s+/g,' ').slice(0,80)}}
    function secret(e){var t=(e.type||'').toLowerCase(),a=(e.autocomplete||'').toLowerCase();
      return t==='password'||t==='hidden'||/password|cc-|one-time-code/.test(a)}
    function result(el){
      var chain=[],e=el; while(e&&e!==document.documentElement&&chain.length<12){chain.push(info(e));e=parent(e)}
      var src=null,k=Object.keys(el).find(function(k){return k.indexOf('__reactFiber')===0});
      if(k){var f=el[k];while(f&&!src){if(f._debugSource)src=f._debugSource.fileName+':'+f._debugSource.lineNumber;f=f.return}}
      var copy=el.cloneNode(true);
      [copy].concat(Array.prototype.slice.call(copy.querySelectorAll?copy.querySelectorAll('input,textarea'):[])).forEach(function(n){
        if(n.removeAttribute&&(n.tagName==='INPUT'||n.tagName==='TEXTAREA')){n.removeAttribute('value');if(n.tagName==='TEXTAREA')n.textContent=''}});
      var html=(copy.outerHTML||'').replace(/\s+/g,' ').slice(0,300);
      var sel=selector(el);
      var p=__akiPoint,pseudo=null;
      if(p){var af=getComputedStyle(el,'::after');
        if(af.content&&af.content!=='none'&&af.display!=='none'){var rg=document.createRange();rg.selectNodeContents(el);
          var rs=rg.getClientRects(),right=0;for(var i=0;i<rs.length;i++)right=Math.max(right,rs[i].right);
          if(rs.length&&p[0]>right+1)pseudo='::after'}}
      if(pseudo){sel+=pseudo;chain[0].text='⌄ '+(chain[0].text?chain[0].text+' ':'')+pseudo}
      return JSON.stringify({chain:chain,src:src,sel:sel,html:html});
    }
    if(px<0||py<0||px>innerWidth||py>innerHeight)return JSON.stringify({outside:true});
    var el=deep(px,py);
    if(!el)return JSON.stringify({});
    if(el.__akiBackground)return JSON.stringify({background:true});
    return result(el);
    }catch(err){return JSON.stringify({error:String(err)})}
    """#
}
