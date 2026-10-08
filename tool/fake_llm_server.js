// Fake OpenAI-compatible server for testing learned-answer capture.
// Serves SSE chat completions on 127.0.0.1:1234 with a canned answer,
// enough for the app's OpenAI-compatible client (keyless localhost).
const http = require('http');
const ANSWER =
  'IP is the Internet Protocol - the Internet Protocol version 4 gives ' +
  'every device a 32-bit address, and routers move packets between ' +
  'networks using those addresses. This answer came from the test ' +
  'fake-model.';
http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    if (req.url.includes('/chat/completions')) {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
      });
      const words = ANSWER.split(' ');
      let i = 0;
      const tick = setInterval(() => {
        if (i >= words.length) {
          res.write('data: [DONE]\n\n');
          res.end();
          clearInterval(tick);
          return;
        }
        const chunk = words.slice(i, i + 3).join(' ') + ' ';
        i += 3;
        res.write(
          'data: ' +
            JSON.stringify({ choices: [{ delta: { content: chunk } }] }) +
            '\n\n',
        );
      }, 15);
    } else if (req.url.includes('/models')) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ data: [{ id: 'fake-model' }] }));
    } else {
      res.writeHead(404);
      res.end();
    }
  });
}).listen(1234, '127.0.0.1', () => console.log('fake llm on 1234'));
