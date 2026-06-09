(function() {
    if (window.__ccAllowInjected) return;
    window.__ccAllowInjected = true;

    var container = document.createElement('div');
    container.style.cssText = 'all:initial;position:fixed;bottom:16px;right:16px;z-index:2147483647;font-family:system-ui,sans-serif;';

    var shadow = container.attachShadow({ mode: 'closed' });
    shadow.innerHTML = '' +
        '<style>' +
        'label{display:flex;align-items:center;gap:6px;cursor:pointer;user-select:none;font-size:13px;color:#fff;background:rgba(0,0,0,0.65);padding:6px 12px;border-radius:8px;backdrop-filter:blur(8px);box-shadow:0 2px 8px rgba(0,0,0,0.2)}' +
        'input{width:16px;height:16px;cursor:pointer;accent-color:#4f46e5}' +
        '</style>' +
        '<label><input type="checkbox" id="__cc-auto-allow"><span>Auto Allow</span></label>';

    document.body.appendChild(container);

    var checkbox = shadow.querySelector('#__cc-auto-allow');

    var timer = null;
    var obs = new MutationObserver(function() {
        clearTimeout(timer);
        timer = setTimeout(function() {
            if (!checkbox.checked) return;
            var btns = document.querySelectorAll('button');
            for (var i = 0; i < btns.length; i++) {
                var t = btns[i].textContent.trim();
                if (t === 'Allow' || t.indexOf('Allow for') === 0) {
                    btns[i].click();
                    break;
                }
            }
        }, 150);
    });
    obs.observe(document.body, { childList: true, subtree: true });
})();
