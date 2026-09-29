// Bridge test page. Runs the same checks on iOS and Android:
//  1. `hello` over the JSON bridge returns the node's client API URL.
//  2. Bridge round trips: 20 `ping` commands, timed.
//  3. Typed bridge errors: an unknown command fails with `unknown_command`.
//  4. The page's own WebSocket to the node: the connected-peers query in the
//     native encoding, whose request bytes the protocol fixtures pin.
//  5. A file outside the manifest is not served.
(function () {
  'use strict';

  // bincode of ClientRequest::NodeQueries(NodeQuery::ConnectedPeers), the
  // `request.connected_peers` protocol fixture.
  var CONNECTED_PEERS_REQUEST = [4, 0, 0, 0, 0, 0, 0, 0];

  var checksEl = document.getElementById('checks');
  var eventsEl = document.getElementById('events');
  var helloEl = document.getElementById('hello');
  var report = { checks: [], events: [] };

  function item(list, cls, text) {
    var li = document.createElement('li');
    if (cls) { li.className = cls; }
    li.textContent = text;
    list.appendChild(li);
  }

  function check(name, passed, detail, ms) {
    report.checks.push({ name: name, passed: passed, detail: detail, ms: ms });
    item(checksEl, passed ? 'ok' : 'bad', name + ': ' + detail + (ms != null ? ' (' + ms.toFixed(1) + ' ms)' : ''));
  }

  function now() { return performance.now(); }

  function sendReport() {
    report.userAgent = navigator.userAgent;
    report.passed = report.checks.length > 0 && report.checks.every(function (c) { return c.passed; });
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.appkitHarness) {
        window.webkit.messageHandlers.appkitHarness.postMessage(report);
      } else if (window.appkitHarness) {
        window.appkitHarness.postMessage(JSON.stringify(report));
      }
    } catch (e) {}
  }

  function openSocket(url) {
    return new Promise(function (resolve, reject) {
      var started = now();
      var ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
      var timer = setTimeout(function () { reject(new Error('no reply within 10 s')); ws.close(); }, 10000);
      ws.onopen = function () {
        ws.send(new Uint8Array(CONNECTED_PEERS_REQUEST));
      };
      ws.onmessage = function (event) {
        clearTimeout(timer);
        var bytes = new Uint8Array(event.data);
        ws.close();
        resolve({ bytes: bytes, ms: now() - started });
      };
      ws.onerror = function () { clearTimeout(timer); reject(new Error('WebSocket error')); };
    });
  }

  async function runChecks() {
    checksEl.textContent = '';
    report.checks = [];
    if (!window.freenetHost) {
      check('bridge', false, 'window.freenetHost is missing');
      sendReport();
      return;
    }
    var started = now();
    var hello;
    try {
      hello = await freenetHost.request('hello');
      helloEl.textContent = JSON.stringify(hello, null, 2);
      check('hello', hello.protocol === 1 && !!hello.node, 'protocol ' + hello.protocol + ', node ' + (hello.node && hello.node.state), now() - started);
    } catch (e) {
      check('hello', false, e.message);
      sendReport();
      return;
    }

    var times = [];
    for (var i = 0; i < 20; i++) {
      var t = now();
      var pong = await freenetHost.request('ping', { i: i });
      times.push(now() - t);
      if (pong.echo.i !== i) { check('ping', false, 'reply ' + pong.echo.i + ' for ping ' + i); break; }
    }
    times.sort(function (a, b) { return a - b; });
    var mean = times.reduce(function (a, b) { return a + b; }, 0) / times.length;
    report.pingMs = { mean: mean, p50: times[10], p95: times[18], max: times[19] };
    check('ping', true, '20 round trips, median ' + times[10].toFixed(2) + ' ms, p95 ' + times[18].toFixed(2) + ' ms', mean);

    try {
      await freenetHost.request('no.such.command');
      check('typed error', false, 'an unknown command succeeded');
    } catch (e) {
      check('typed error', e.code === 'unknown_command', 'code ' + e.code);
    }

    if (hello.node && hello.node.wsUrl) {
      try {
        var reply = await openSocket(hello.node.wsUrl);
        // A bincode Result: 4 bytes of variant index, 0 for Ok.
        var ok = reply.bytes.length >= 4 && reply.bytes[0] === 0 && reply.bytes[1] === 0;
        report.peersReplyBytes = reply.bytes.length;
        check('node websocket', ok, reply.bytes.length + ' byte reply to the connected-peers query', reply.ms);
      } catch (e) {
        check('node websocket', false, e.message);
      }
    } else {
      check('node websocket', false, 'the node reported no client API URL');
    }

    try {
      var res = await fetch('secret.txt');
      check('manifest only', res.status === 404, 'unlisted file answered ' + res.status);
    } catch (e) {
      check('manifest only', true, 'unlisted file refused: ' + e.message);
    }
    sendReport();
  }

  if (window.freenetHost) {
    freenetHost.on('*', function (data, name) {
      report.events.push({ name: name, data: data, at: Date.now() });
      item(eventsEl, null, name + ' ' + JSON.stringify(data));
    });
  }
  document.getElementById('run').addEventListener('click', runChecks);
  if (location.search.indexOf('autorun=1') >= 0) {
    runChecks();
  } else if (window.freenetHost) {
    freenetHost.request('hello').then(function (hello) {
      helloEl.textContent = JSON.stringify(hello, null, 2);
    });
  }
})();
