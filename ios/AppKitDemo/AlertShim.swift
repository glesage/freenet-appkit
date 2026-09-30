import Foundation

/// A `Notification` for the node's shell page that hands alerts to the host.
enum AlertShim {
    static func script(permission: String) -> String {
        """
        (function () {
          var granted = '\(permission)';
          var live = {};
          var next = 0;
          var waiting = [];
          function post(msg) {
            try { window.webkit.messageHandlers.appkitAlerts.postMessage(msg); } catch (e) {}
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
        """
    }
}
