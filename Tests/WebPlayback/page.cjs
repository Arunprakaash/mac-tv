// The phone remote's page as the Mac serves it: remote.html with remote.css and remote.js inline.
const fs = require('node:fs');
const path = require('node:path');
const dir = path.join(__dirname, '../../Sources/MacTV/Features/Remote/Page');
const read = name => fs.readFileSync(path.join(dir, name), 'utf8');
const script = read('remote.js');
const html = read('remote.html')
  .replace('<link rel="stylesheet" href="remote.css">', '<style>\n' + read('remote.css') + '</style>')
  .replace('<script src="remote.js"></script>', '<script>\n' + script + '</script>');
module.exports = { html, script };
