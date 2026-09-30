package org.freenet.appkit.demo

/** A `Notification` for the node's shell page that hands alerts to the host. */
object AlertShim {
    fun script(permission: String) = """
        (function () {
          var granted = '$permission';
          var live = {};
          var next = 0;
          var waiting = [];
          function post(msg) {
            try { window.appkitAlerts.postMessage(JSON.stringify(msg)); } catch (e) {}
          }
          function HostNotification(title, options) {
            options = options || {};
            this.title = String(title);
            this.body = typeof options.body === 'string' ? options.body : '';
            this.tag = typeof options.tag === 'string' ? options.tag : '';
            this.data = options.data;
            this.onclick = null;
            this._id = String(++next);
            live[this._id] = this;
            post({ kind: 'show', id: this._id, title: this.title, body: this.body, tag: this.tag });
          }
          HostNotification.prototype.close = function () { delete live[this._id]; };
          HostNotification.prototype.addEventListener = function (type, cb) {
            if (type === 'click') { this.onclick = cb; }
          };
          Object.defineProperty(HostNotification, 'permission', { get: function () { return granted; } });
          HostNotification.requestPermission = function (callback) {
            return new Promise(function (resolve) {
              waiting.push(function (answer) {
                granted = answer;
                if (typeof callback === 'function') { callback(answer); }
                resolve(answer);
              });
              post({ kind: 'permission' });
            });
          };
          window.__appkitAlertPermission = function (answer) {
            granted = answer;
            var pending = waiting;
            waiting = [];
            pending.forEach(function (f) { f(answer); });
          };
          window.__appkitAlertClick = function (id) {
            var n = live[id];
            if (n && typeof n.onclick === 'function') { n.onclick({ target: n }); }
          };
          window.Notification = HostNotification;
        })();
    """.trimIndent()

    /**
     * Every frame reports when its document is ready. The app frame also
     * reports when it first shows text or media, which ends the loading view.
     */
    const val FRAME_REPORT = """
        (function () {
          function post(msg) {
            try { window.appkitFrames.postMessage(JSON.stringify(msg)); } catch (e) {}
          }
          var top = window === window.top;
          post({ kind: 'frame', top: top, href: String(location.href) });
          if (top) { return; }
          function painted() {
            var body = document.body;
            if (!body) { return false; }
            if (body.innerText && body.innerText.trim().length > 0) { return true; }
            var media = body.querySelectorAll('img, svg, canvas, video, input, button');
            for (var i = 0; i < media.length; i++) {
              var r = media[i].getBoundingClientRect();
              if (r.width > 0 && r.height > 0) { return true; }
            }
            return false;
          }
          var done = false, queued = false, observer;
          function check() {
            queued = false;
            if (done || !painted()) { return; }
            done = true;
            if (observer) { observer.disconnect(); }
            post({ kind: 'painted', top: false });
          }
          observer = new MutationObserver(function () {
            if (!queued) { queued = true; requestAnimationFrame(check); }
          });
          observer.observe(document, { childList: true, subtree: true, characterData: true });
          check();
        })();
    """
}
